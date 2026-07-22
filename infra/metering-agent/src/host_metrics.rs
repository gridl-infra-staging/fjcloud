use anyhow::{anyhow, Context};
use chrono::{DateTime, Utc};
use std::fs;
use std::path::Path;
use std::time::Duration;

#[derive(Debug, Clone, PartialEq)]
pub(crate) struct HostMetricsSample {
    pub collected_at: DateTime<Utc>,
    pub cpu_pct: f64,
    pub mem_used_bytes: i64,
    pub mem_total_bytes: i64,
    pub disk_used_bytes: Option<i64>,
    pub disk_total_bytes: Option<i64>,
    pub net_rx_bytes: i64,
    pub net_tx_bytes: i64,
}

#[derive(Debug, Clone, PartialEq)]
struct MemoryMetrics {
    mem_used_bytes: i64,
    mem_total_bytes: i64,
}

#[derive(Debug, Clone, PartialEq)]
struct NetDevMetrics {
    rx_bytes: i64,
    tx_bytes: i64,
    non_loopback_interfaces: usize,
}

#[derive(Debug, Clone, PartialEq)]
struct CpuSnapshot {
    busy: u64,
    total: u64,
}

#[derive(Debug, Clone, PartialEq)]
struct DiskMetrics {
    used_bytes: i64,
    total_bytes: i64,
}

const AGGREGATE_CPU_TOTAL_FIELDS: usize = 8;

pub(crate) fn collect_host_metrics(
    proc_root: &Path,
    disk_path: &Path,
    cpu_sample_interval: Duration,
) -> anyhow::Result<HostMetricsSample> {
    let meminfo = read_proc_file(proc_root, "meminfo")?;
    let net_dev = read_proc_file(proc_root, "net/dev")?;
    let first_stat = read_proc_file(proc_root, "stat")?;

    if !cpu_sample_interval.is_zero() {
        std::thread::sleep(cpu_sample_interval);
    }

    let second_stat = read_proc_file(proc_root, "stat")?;
    let memory = parse_meminfo(&meminfo)?;
    let network = parse_net_dev(&net_dev)?;
    let first_cpu = parse_cpu_stat(&first_stat)?;
    let second_cpu = parse_cpu_stat(&second_stat)?;
    let cpu_pct = cpu_pct_between(&first_cpu, &second_cpu)?;
    let disk = collect_disk_metrics(disk_path);

    Ok(HostMetricsSample {
        collected_at: Utc::now(),
        cpu_pct,
        mem_used_bytes: memory.mem_used_bytes,
        mem_total_bytes: memory.mem_total_bytes,
        disk_used_bytes: disk.as_ref().map(|metrics| metrics.used_bytes),
        disk_total_bytes: disk.as_ref().map(|metrics| metrics.total_bytes),
        net_rx_bytes: network.rx_bytes,
        net_tx_bytes: network.tx_bytes,
    })
}

fn read_proc_file(proc_root: &Path, relative_path: &str) -> anyhow::Result<String> {
    let path = proc_root.join(relative_path);
    fs::read_to_string(&path).with_context(|| format!("read required proc file {}", path.display()))
}

fn parse_meminfo(contents: &str) -> anyhow::Result<MemoryMetrics> {
    let mem_total_kb = parse_meminfo_kb(contents, "MemTotal")?;
    let mem_available_kb = parse_meminfo_kb(contents, "MemAvailable")?;
    let mem_used_kb = mem_total_kb
        .checked_sub(mem_available_kb)
        .ok_or_else(|| anyhow!("MemAvailable exceeds MemTotal"))?;

    Ok(MemoryMetrics {
        mem_total_bytes: kb_to_bytes(mem_total_kb)?,
        mem_used_bytes: kb_to_bytes(mem_used_kb)?,
    })
}

fn parse_meminfo_kb(contents: &str, key: &str) -> anyhow::Result<i64> {
    let prefix = format!("{key}:");
    let line = contents
        .lines()
        .find(|line| line.trim_start().starts_with(&prefix))
        .ok_or_else(|| anyhow!("missing {key} in meminfo"))?;
    let value = line
        .split_whitespace()
        .nth(1)
        .ok_or_else(|| anyhow!("missing numeric value for {key}"))?;

    value
        .parse::<i64>()
        .with_context(|| format!("parse {key} kB value"))
}

fn kb_to_bytes(kb: i64) -> anyhow::Result<i64> {
    kb.checked_mul(1024)
        .ok_or_else(|| anyhow!("memory byte value overflowed i64"))
}

fn parse_net_dev(contents: &str) -> anyhow::Result<NetDevMetrics> {
    let mut metrics = NetDevMetrics {
        rx_bytes: 0,
        tx_bytes: 0,
        non_loopback_interfaces: 0,
    };

    for line in contents.lines().filter(|line| line.contains(':')) {
        let (interface, counters) = line
            .split_once(':')
            .ok_or_else(|| anyhow!("malformed net/dev line: {line}"))?;
        let interface = interface.trim();
        if interface == "lo" {
            continue;
        }

        let columns: Vec<&str> = counters.split_whitespace().collect();
        if columns.len() < 16 {
            return Err(anyhow!(
                "malformed net/dev counters for {interface}: expected 16 columns, got {}",
                columns.len()
            ));
        }

        metrics.rx_bytes = checked_add_i64(
            metrics.rx_bytes,
            parse_net_counter(columns[0], interface, "rx bytes")?,
            interface,
        )?;
        metrics.tx_bytes = checked_add_i64(
            metrics.tx_bytes,
            parse_net_counter(columns[8], interface, "tx bytes")?,
            interface,
        )?;
        metrics.non_loopback_interfaces += 1;
    }

    if metrics.non_loopback_interfaces == 0 {
        return Err(anyhow!("net/dev contains no non-loopback interfaces"));
    }

    Ok(metrics)
}

fn parse_net_counter(raw: &str, interface: &str, column: &str) -> anyhow::Result<i64> {
    raw.parse::<i64>()
        .with_context(|| format!("parse net/dev {column} counter for {interface}"))
}

fn checked_add_i64(left: i64, right: i64, interface: &str) -> anyhow::Result<i64> {
    left.checked_add(right)
        .ok_or_else(|| anyhow!("net/dev byte counter overflow while adding {interface}"))
}

fn parse_cpu_stat(contents: &str) -> anyhow::Result<CpuSnapshot> {
    let line = contents
        .lines()
        .find(|line| line.starts_with("cpu "))
        .ok_or_else(|| anyhow!("missing aggregate cpu line in stat"))?;
    let values = line
        .split_whitespace()
        .skip(1)
        .map(str::parse::<u64>)
        .collect::<Result<Vec<_>, _>>()
        .context("parse aggregate cpu counters")?;

    if values.len() < 4 {
        return Err(anyhow!(
            "aggregate cpu line has {} counters; expected at least 4",
            values.len()
        ));
    }

    // Linux already includes guest and guest_nice time in user and nice.
    // Excluding fields beyond steal avoids double-counting guest workload.
    let total = values
        .iter()
        .take(AGGREGATE_CPU_TOTAL_FIELDS)
        .try_fold(0_u64, |acc, value| {
            acc.checked_add(*value)
                .ok_or_else(|| anyhow!("aggregate cpu total overflowed u64"))
        })?;
    let idle = values[3]
        .checked_add(values.get(4).copied().unwrap_or(0))
        .ok_or_else(|| anyhow!("aggregate cpu idle total overflowed u64"))?;
    let busy = total
        .checked_sub(idle)
        .ok_or_else(|| anyhow!("aggregate cpu idle exceeds total"))?;

    Ok(CpuSnapshot { busy, total })
}

fn cpu_pct_between(before: &CpuSnapshot, after: &CpuSnapshot) -> anyhow::Result<f64> {
    let total_delta = after
        .total
        .checked_sub(before.total)
        .ok_or_else(|| anyhow!("CPU total counter decreased"))?;
    if total_delta == 0 {
        return Err(anyhow!("CPU total delta is zero"));
    }

    let busy_delta = after
        .busy
        .checked_sub(before.busy)
        .ok_or_else(|| anyhow!("CPU busy counter decreased"))?;

    Ok((busy_delta as f64 / total_delta as f64) * 100.0)
}

fn collect_disk_metrics(disk_path: &Path) -> Option<DiskMetrics> {
    match statvfs_disk_metrics(disk_path) {
        Ok(metrics) => Some(metrics),
        Err(err) => {
            tracing::warn!(path = %disk_path.display(), "host disk metrics unavailable: {:#}", err);
            None
        }
    }
}

#[cfg(unix)]
fn statvfs_disk_metrics(disk_path: &Path) -> anyhow::Result<DiskMetrics> {
    use std::ffi::CString;
    use std::mem::MaybeUninit;
    use std::os::unix::ffi::OsStrExt;

    let c_path = CString::new(disk_path.as_os_str().as_bytes())
        .with_context(|| format!("disk path contains interior NUL: {}", disk_path.display()))?;
    let mut stat = MaybeUninit::<libc::statvfs>::uninit();
    let result = unsafe { libc::statvfs(c_path.as_ptr(), stat.as_mut_ptr()) };
    if result != 0 {
        return Err(std::io::Error::last_os_error())
            .with_context(|| format!("statvfs {}", disk_path.display()));
    }
    let stat = unsafe { stat.assume_init() };
    disk_metrics_from_statvfs(stat.f_blocks, stat.f_bfree, stat.f_frsize)
}

#[cfg(not(unix))]
fn statvfs_disk_metrics(_disk_path: &Path) -> anyhow::Result<DiskMetrics> {
    Err(anyhow!("statvfs disk metrics are only supported on Unix"))
}

fn disk_metrics_from_statvfs(
    blocks: impl Into<u128>,
    free_blocks: impl Into<u128>,
    fragment_size: impl Into<u128>,
) -> anyhow::Result<DiskMetrics> {
    let blocks = blocks.into();
    let free_blocks = free_blocks.into();
    let fragment_size = fragment_size.into();
    let used_blocks = blocks
        .checked_sub(free_blocks)
        .ok_or_else(|| anyhow!("statvfs free blocks exceed total blocks"))?;

    Ok(DiskMetrics {
        total_bytes: checked_u128_to_i64(
            blocks
                .checked_mul(fragment_size)
                .ok_or_else(|| anyhow!("statvfs total bytes overflowed"))?,
            "statvfs total bytes",
        )?,
        used_bytes: checked_u128_to_i64(
            used_blocks
                .checked_mul(fragment_size)
                .ok_or_else(|| anyhow!("statvfs used bytes overflowed"))?,
            "statvfs used bytes",
        )?,
    })
}

fn checked_u128_to_i64(value: u128, label: &str) -> anyhow::Result<i64> {
    i64::try_from(value).with_context(|| format!("{label} exceed i64"))
}

#[cfg(test)]
mod tests {
    use super::*;

    const MEMINFO_FIXTURE: &str = r#"
MemTotal:       16305840 kB
MemFree:         1250000 kB
MemAvailable:    8152920 kB
Buffers:          250000 kB
Cached:          5250000 kB
"#;

    const NET_DEV_FIXTURE: &str = r#"
Inter-|   Receive                                                |  Transmit
 face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
    lo: 100 1 0 0 0 0 0 0 200 2 0 0 0 0 0 0
  eth0: 1234 10 0 0 0 0 0 0 5678 20 0 0 0 0 0 0
  ens5: 222 3 0 0 0 0 0 0 333 4 0 0 0 0 0 0
"#;

    #[test]
    fn parse_meminfo_computes_total_and_used_bytes() {
        let parsed = parse_meminfo(MEMINFO_FIXTURE).expect("meminfo should parse");

        assert_eq!(parsed.mem_total_bytes, 16_697_180_160);
        assert_eq!(parsed.mem_used_bytes, 8_348_590_080);
    }

    #[test]
    fn parse_meminfo_rejects_missing_total() {
        let err = parse_meminfo("MemAvailable: 8152920 kB\n").unwrap_err();

        assert!(err.to_string().contains("MemTotal"));
    }

    #[test]
    fn parse_meminfo_rejects_missing_available() {
        let err = parse_meminfo("MemTotal: 16305840 kB\n").unwrap_err();

        assert!(err.to_string().contains("MemAvailable"));
    }

    #[test]
    fn parse_net_dev_sums_non_loopback_counters() {
        let parsed = parse_net_dev(NET_DEV_FIXTURE).expect("net dev should parse");

        assert_eq!(parsed.rx_bytes, 1_456);
        assert_eq!(parsed.tx_bytes, 6_011);
        assert_eq!(parsed.non_loopback_interfaces, 2);
    }

    #[test]
    fn parse_net_dev_rejects_malformed_required_columns() {
        let fixture = r#"
Inter-|   Receive                                                |  Transmit
 face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
  eth0: 1234 10 0
"#;
        let err = parse_net_dev(fixture).unwrap_err();

        assert!(err.to_string().contains("eth0"));
    }

    #[test]
    fn parse_net_dev_rejects_no_non_loopback_interfaces() {
        let fixture = r#"
Inter-|   Receive                                                |  Transmit
 face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
    lo: 100 1 0 0 0 0 0 0 200 2 0 0 0 0 0 0
"#;
        let err = parse_net_dev(fixture).unwrap_err();

        assert!(err.to_string().contains("non-loopback"));
    }

    #[test]
    fn parse_cpu_stat_reads_aggregate_cpu_line() {
        let parsed = parse_cpu_stat("cpu  100 0 100 100 0 0 0 0 0 0\ncpu0 1 0 1 1\n")
            .expect("cpu stat should parse");

        assert_eq!(parsed.total, 300);
        assert_eq!(parsed.busy, 200);
    }

    #[test]
    fn parse_cpu_stat_rejects_missing_aggregate_cpu() {
        let err = parse_cpu_stat("cpu0 1 0 1 1\n").unwrap_err();

        assert!(err.to_string().contains("aggregate cpu"));
    }

    #[test]
    fn cpu_pct_between_reports_busy_delta_percent() {
        let before = parse_cpu_stat("cpu  100 0 100 100 0 0 0 0 0 0\n").unwrap();
        let after = parse_cpu_stat("cpu  125 0 125 150 0 0 0 0 0 0\n").unwrap();

        assert_eq!(cpu_pct_between(&before, &after).unwrap(), 50.0);
    }

    #[test]
    fn cpu_pct_between_excludes_guest_time_already_counted_in_user() {
        let before = parse_cpu_stat("cpu  100 0 0 100 0 0 0 0 0 0\n").unwrap();
        let after = parse_cpu_stat("cpu  150 0 0 150 0 0 0 0 50 0\n").unwrap();

        assert_eq!(before.total, 200);
        assert_eq!(after.total, 300);
        assert_eq!(cpu_pct_between(&before, &after).unwrap(), 50.0);
    }

    #[test]
    fn cpu_pct_between_rejects_zero_total_delta() {
        let before = parse_cpu_stat("cpu  100 0 100 100 0 0 0 0 0 0\n").unwrap();
        let after = parse_cpu_stat("cpu  100 0 100 100 0 0 0 0 0 0\n").unwrap();

        let err = cpu_pct_between(&before, &after).unwrap_err();

        assert!(err.to_string().contains("CPU total delta"));
    }

    #[test]
    fn disk_metrics_use_total_and_free_blocks() {
        let metrics = disk_metrics_from_statvfs(100_u64, 25_u64, 4096_u64).unwrap();

        assert_eq!(metrics.total_bytes, 409_600);
        assert_eq!(metrics.used_bytes, 307_200);
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn collect_host_metrics_reads_live_linux_proc_snapshot() {
        use std::path::Path;
        use std::time::{SystemTime, UNIX_EPOCH};

        let proc_root = unique_temp_proc_root();
        fs::create_dir_all(proc_root.join("net")).expect("temp net proc dir should be created");

        let meminfo = fs::read_to_string("/proc/meminfo").expect("live meminfo should be readable");
        let net_dev = fs::read_to_string("/proc/net/dev").expect("live net/dev should be readable");
        let parsed_net = parse_net_dev(&net_dev).expect("live net/dev should parse");

        fs::write(proc_root.join("meminfo"), meminfo).expect("temp meminfo should be written");
        fs::write(proc_root.join("net/dev"), net_dev).expect("temp net/dev should be written");
        fs::write(proc_root.join("stat"), "cpu  100 0 100 100 0 0 0 0 0 0\n")
            .expect("first temp stat should be written");

        let stat_path = proc_root.join("stat");
        let updater = std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(5));
            fs::write(stat_path, "cpu  125 0 125 150 0 0 0 0 0 0\n")
                .expect("second temp stat should be written");
        });

        let sample = collect_host_metrics(&proc_root, Path::new("/"), Duration::from_millis(20))
            .expect("live host metrics should collect");
        updater.join().expect("stat updater should complete");

        assert!(sample.mem_total_bytes > 0);
        assert!(parsed_net.non_loopback_interfaces >= 1);
        assert_eq!(sample.net_rx_bytes, parsed_net.rx_bytes);
        assert_eq!(sample.net_tx_bytes, parsed_net.tx_bytes);
        assert!(
            sample
                .disk_total_bytes
                .expect("disk total should be present")
                > 0
        );
        assert!(
            sample.disk_used_bytes.expect("disk used should be present")
                <= sample
                    .disk_total_bytes
                    .expect("disk total should be present")
        );

        fs::remove_dir_all(proc_root).expect("temp proc root should be removed");

        fn unique_temp_proc_root() -> std::path::PathBuf {
            let nanos = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .expect("system time should be after unix epoch")
                .as_nanos();
            std::env::temp_dir().join(format!(
                "fjcloud_host_metrics_{}_{}",
                std::process::id(),
                nanos
            ))
        }
    }
}
