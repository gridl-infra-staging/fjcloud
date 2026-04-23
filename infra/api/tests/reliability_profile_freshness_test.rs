//! Capacity Profile Freshness Enforcement tests.
//!
//! These tests bridge the bash profiling harness (`scripts/reliability/`) to the
//! Rust test suite. They assert that profile JSON artifacts under
//! `scripts/reliability/profiles/` exist, are fresh, and their measured values
//! are consistent with the constants in `common::capacity_profiles`.
//!
//! # Failure reason codes
//!
//! Each test failure includes a machine-parseable reason code:
//! - `PROFILE_MISSING` — artifact file does not exist
//! - `PROFILE_STALE`   — artifact timestamp is older than the staleness threshold
//! - `PROFILE_SCHEMA`  — artifact JSON does not conform to the expected envelope schema
//! - `PROFILE_DRIFT`   — measured value diverges from the hardcoded constant beyond tolerance
//!
//! # Tolerance and staleness knobs
//!
//! - **Drift tolerance**: 0.1x–10x of the constant value. This is intentionally
//!   wide because the current constants are acknowledged placeholders. Once real
//!   profiling data is captured and constants are updated, tighten to e.g. 0.5x–2x.
//! - **Staleness threshold**: 30 days (overridable via `RELIABILITY_STALENESS_DAYS` env var).
//!
//! # Generating artifacts
//!
//! Run `scripts/reliability/seed-test-profiles.sh` for CI/dev (uses constant values).
//! Run `RELIABILITY=1 scripts/reliability/capture-all.sh` for a real profiling run
//! against a live flapjack stack.

mod common;

use std::path::Path;
use std::path::PathBuf;
use std::process::Command;
use std::sync::OnceLock;

use chrono::{DateTime, Utc};
use serde_json::Value;

// ---------------------------------------------------------------------------
// Reason code constants
// ---------------------------------------------------------------------------

const PROFILE_MISSING: &str = "PROFILE_MISSING";
const PROFILE_STALE: &str = "PROFILE_STALE";
const PROFILE_SCHEMA: &str = "PROFILE_SCHEMA";
const PROFILE_DRIFT: &str = "PROFILE_DRIFT";
static PROFILE_BOOTSTRAP: OnceLock<Result<(), String>> = OnceLock::new();

// ---------------------------------------------------------------------------
// Path helpers
// ---------------------------------------------------------------------------

fn repo_root() -> PathBuf {
    // env!("CARGO_MANIFEST_DIR") resolves to infra/api/ at compile time.
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    // infra/api/ → infra/ → repo root
    manifest_dir
        .parent()
        .expect("infra/api/ has a parent (infra/)")
        .parent()
        .expect("infra/ has a parent (repo root)")
        .to_path_buf()
}

fn profiles_dir() -> PathBuf {
    repo_root()
        .join("scripts")
        .join("reliability")
        .join("profiles")
}

fn profile_path(tier: &str, metric: &str) -> PathBuf {
    profiles_dir().join(format!("{}_{}.json", tier, metric))
}

fn summary_path() -> PathBuf {
    profiles_dir().join("summary.json")
}

fn seed_script_path() -> PathBuf {
    repo_root()
        .join("scripts")
        .join("reliability")
        .join("seed-test-profiles.sh")
}

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const TIERS: &[&str] = &["1k", "10k", "100k"];
const METRICS: &[&str] = &["cpu", "mem", "disk", "latency"];

fn staleness_threshold_days() -> i64 {
    std::env::var("RELIABILITY_STALENESS_DAYS")
        .ok()
        .and_then(|v| v.parse::<i64>().ok())
        .unwrap_or(30)
}

fn profile_artifacts_exist_in(path: &Path) -> bool {
    for tier in TIERS {
        for metric in METRICS {
            if !path.join(format!("{}_{}.json", tier, metric)).exists() {
                return false;
            }
        }
    }
    path.join("summary.json").exists()
}

fn ensure_profile_artifacts_with_seed(
    profiles_dir: &Path,
    seed_script: &Path,
) -> Result<(), String> {
    if profile_artifacts_exist_in(profiles_dir) {
        return Ok(());
    }

    if !seed_script.exists() {
        return Err(format!("seed_script_missing:{}", seed_script.display()));
    }

    let output = Command::new("bash")
        .arg(seed_script)
        .current_dir(repo_root())
        .output()
        .map_err(|e| format!("seed_script_launch_failed:{}:{e}", seed_script.display()))?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(format!(
            "seed_script_failed:{}:status={}:{}",
            seed_script.display(),
            output
                .status
                .code()
                .map(|code| code.to_string())
                .unwrap_or_else(|| "terminated_by_signal".to_string()),
            stderr.trim()
        ));
    }

    if !profile_artifacts_exist_in(profiles_dir) {
        return Err(format!("seed_script_incomplete:{}", profiles_dir.display()));
    }

    Ok(())
}

fn ensure_profile_artifacts_available() {
    let result = PROFILE_BOOTSTRAP
        .get_or_init(|| ensure_profile_artifacts_with_seed(&profiles_dir(), &seed_script_path()));
    if let Err(reason) = result {
        panic!("{PROFILE_MISSING}:bootstrap_failed:{reason}");
    }
}

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

/// Load and parse a profile artifact JSON file. Returns `None` if the file does
/// not exist (existence is validated separately by `profile_artifacts_exist`).
/// Panics with a `PROFILE_SCHEMA` reason code on read or parse errors.
fn load_profile(tier: &str, metric: &str) -> Option<Value> {
    ensure_profile_artifacts_available();
    let path = profile_path(tier, metric);
    if !path.exists() {
        return None;
    }
    let contents = std::fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("{PROFILE_SCHEMA}:{tier}_{metric}:read_error — {e}"));
    Some(
        serde_json::from_str(&contents)
            .unwrap_or_else(|e| panic!("{PROFILE_SCHEMA}:{tier}_{metric}:parse_error — {e}")),
    )
}

/// Assert that a measured u64 value extracted from a profile artifact is within
/// 0.1x–10x of the corresponding constant. Panics with `PROFILE_DRIFT` on violation
/// or `PROFILE_SCHEMA` if the JSON pointer doesn't resolve to a u64.
fn assert_drift_within_tolerance(
    tier: &str,
    metric: &str,
    json: &Value,
    pointer: &str,
    constant_bytes: u64,
) {
    let measured = json
        .pointer(pointer)
        .and_then(|v| v.as_u64())
        .unwrap_or_else(|| {
            panic!(
                "{PROFILE_SCHEMA}:{tier}_{metric}:missing_{}",
                pointer.replace('/', "_")
            )
        });

    let lo = constant_bytes / 10;
    let hi = constant_bytes * 10;

    assert!(
        measured >= lo && measured <= hi,
        "{PROFILE_DRIFT}:{metric}:{tier} — measured {measured} is outside tolerance [{lo}, {hi}] \
         (constant={constant_bytes}, tolerance=0.1x-10x)",
    );
}

/// Assert that a timestamp is fresh enough for the configured threshold.
/// Panics with PROFILE_SCHEMA for parse errors or PROFILE_STALE for stale artifacts.
fn assert_profile_timestamp_not_stale(
    tier: &str,
    metric: &str,
    ts_str: &str,
    now: DateTime<Utc>,
    threshold_days: i64,
) {
    let ts = ts_str.parse::<DateTime<Utc>>().unwrap_or_else(|e| {
        panic!("{PROFILE_SCHEMA}:{tier}_{metric}:invalid_timestamp — '{ts_str}': {e}")
    });

    let age = now.signed_duration_since(ts);
    let age_days = age.num_days();

    assert!(
        age_days <= threshold_days,
        "{PROFILE_STALE}:{tier}_{metric} — artifact is {age_days} days old, threshold is {threshold_days} days (timestamp={ts_str})",
    );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// Assert that all 12 per-metric profile artifact files exist.
///
/// Reason code: `PROFILE_MISSING:{tier}_{metric}`
#[test]
fn profile_artifacts_exist() {
    ensure_profile_artifacts_available();
    for tier in TIERS {
        for metric in METRICS {
            let path = profile_path(tier, metric);
            assert!(
                path.exists(),
                "{code}:{tier}_{metric} — expected profile at {path}",
                code = PROFILE_MISSING,
                tier = tier,
                metric = metric,
                path = path.display(),
            );
        }
    }
}

/// Assert that `scripts/reliability/profiles/summary.json` exists.
///
/// Reason code: `PROFILE_MISSING:summary`
#[test]
fn summary_artifact_exists() {
    ensure_profile_artifacts_available();
    let path = summary_path();
    assert!(
        path.exists(),
        "{code}:summary — expected summary at {path}",
        code = PROFILE_MISSING,
        path = path.display(),
    );
}

/// Assert that all profile artifacts have a `timestamp` within the staleness threshold.
///
/// Configurable via `RELIABILITY_STALENESS_DAYS` env var (default: 30 days).
/// Reason code: `PROFILE_STALE:{tier}_{metric}` with age and threshold in the message.
#[test]
fn profile_artifacts_not_stale() {
    let threshold_days = staleness_threshold_days();
    let now = Utc::now();

    for tier in TIERS {
        for metric in METRICS {
            let json = match load_profile(tier, metric) {
                Some(v) => v,
                None => continue,
            };

            let ts_str = json
                .get("timestamp")
                .and_then(|v| v.as_str())
                .unwrap_or_else(|| panic!("{PROFILE_SCHEMA}:{tier}_{metric}:missing_timestamp"));
            assert_profile_timestamp_not_stale(tier, metric, ts_str, now, threshold_days);
        }
    }
}

/// Verify that stale profile detection logic works correctly.
///
/// This test intentionally feeds a stale timestamp and asserts that the panic
/// includes PROFILE_STALE context for machine-parseable diagnostics.
#[test]
fn stale_profile_fails_with_clear_error_context() {
    let threshold_days = 30;
    let now = Utc::now();
    let stale_ts = (now - chrono::Duration::days(threshold_days + 5)).to_rfc3339();

    let panic = std::panic::catch_unwind(|| {
        assert_profile_timestamp_not_stale("1k", "mem", &stale_ts, now, threshold_days);
    })
    .expect_err("stale timestamp should trigger PROFILE_STALE failure");

    let panic_msg = panic
        .downcast_ref::<String>()
        .map(|s| s.as_str())
        .or_else(|| panic.downcast_ref::<&str>().copied())
        .unwrap_or("<non-string panic>");

    assert!(
        panic_msg.contains("PROFILE_STALE:1k_mem"),
        "panic should include PROFILE_STALE reason and artifact context, got: {panic_msg}"
    );
    assert!(
        panic_msg.contains("threshold is 30 days"),
        "panic should include threshold context, got: {panic_msg}"
    );
}

/// Assert that all profile artifacts conform to the expected envelope schema.
///
/// Top-level: `tier` (string matching filename tier), `timestamp` (valid ISO 8601),
/// `metric` (string matching filename metric), `envelope` (object).
///
/// Per-metric envelope requirements:
/// - `cpu`     — `idle`, `seeding`, `query_load` sub-objects each with `cpu_user_pct`, `cpu_idle_pct`
/// - `mem`     — `idle`, `post_seed`, `query_load` sub-objects each with `rss_bytes`
/// - `disk`    — `post_seed` sub-object with `disk_bytes`
/// - `latency` — `p50_ms`, `p95_ms`, `p99_ms`, `count`
///
/// Reason code: `PROFILE_SCHEMA:{tier}_{metric}:{detail}`
#[test]
fn profile_schema_valid() {
    for tier in TIERS {
        for metric in METRICS {
            let json = match load_profile(tier, metric) {
                Some(v) => v,
                None => continue,
            };

            // Top-level `tier` field
            let got_tier = json
                .get("tier")
                .and_then(|v| v.as_str())
                .unwrap_or_else(|| panic!("{PROFILE_SCHEMA}:{tier}_{metric}:missing_tier"));
            assert_eq!(
                got_tier, *tier,
                "{PROFILE_SCHEMA}:{tier}_{metric}:tier_mismatch — expected '{tier}', got '{got_tier}'"
            );

            // Top-level `timestamp`
            let ts_str = json
                .get("timestamp")
                .and_then(|v| v.as_str())
                .unwrap_or_else(|| panic!("{PROFILE_SCHEMA}:{tier}_{metric}:missing_timestamp"));
            ts_str.parse::<DateTime<Utc>>().unwrap_or_else(|e| {
                panic!("{PROFILE_SCHEMA}:{tier}_{metric}:invalid_timestamp — '{ts_str}': {e}")
            });

            // Top-level `metric` field
            let got_metric = json
                .get("metric")
                .and_then(|v| v.as_str())
                .unwrap_or_else(|| panic!("{PROFILE_SCHEMA}:{tier}_{metric}:missing_metric"));
            assert_eq!(
                got_metric, *metric,
                "{PROFILE_SCHEMA}:{tier}_{metric}:metric_mismatch — expected '{metric}', got '{got_metric}'"
            );

            // Top-level `envelope` must be an object
            let envelope = json
                .get("envelope")
                .and_then(|v| v.as_object())
                .unwrap_or_else(|| {
                    panic!("{PROFILE_SCHEMA}:{tier}_{metric}:missing_or_invalid_envelope")
                });

            // Per-metric envelope structure validation
            match *metric {
                "cpu" => {
                    for phase in &["idle", "seeding", "query_load"] {
                        let phase_obj = envelope
                            .get(*phase)
                            .and_then(|v| v.as_object())
                            .unwrap_or_else(|| {
                                panic!("{PROFILE_SCHEMA}:{tier}_{metric}:cpu_missing_phase_{phase}")
                            });
                        assert!(
                            phase_obj.contains_key("cpu_user_pct"),
                            "{PROFILE_SCHEMA}:{tier}_{metric}:cpu_{phase}_missing_cpu_user_pct"
                        );
                        assert!(
                            phase_obj.contains_key("cpu_idle_pct"),
                            "{PROFILE_SCHEMA}:{tier}_{metric}:cpu_{phase}_missing_cpu_idle_pct"
                        );
                    }
                }
                "mem" => {
                    for phase in &["idle", "post_seed", "query_load"] {
                        let phase_obj = envelope
                            .get(*phase)
                            .and_then(|v| v.as_object())
                            .unwrap_or_else(|| {
                                panic!("{PROFILE_SCHEMA}:{tier}_{metric}:mem_missing_phase_{phase}")
                            });
                        assert!(
                            phase_obj.contains_key("rss_bytes"),
                            "{PROFILE_SCHEMA}:{tier}_{metric}:mem_{phase}_missing_rss_bytes"
                        );
                    }
                }
                "disk" => {
                    let post_seed = envelope
                        .get("post_seed")
                        .and_then(|v| v.as_object())
                        .unwrap_or_else(|| {
                            panic!("{PROFILE_SCHEMA}:{tier}_{metric}:disk_missing_post_seed")
                        });
                    assert!(
                        post_seed.contains_key("disk_bytes"),
                        "{PROFILE_SCHEMA}:{tier}_{metric}:disk_post_seed_missing_disk_bytes"
                    );
                }
                "latency" => {
                    for key in &["p50_ms", "p95_ms", "p99_ms", "count"] {
                        assert!(
                            envelope.contains_key(*key),
                            "{PROFILE_SCHEMA}:{tier}_{metric}:latency_missing_{key}"
                        );
                    }
                }
                _ => unreachable!("unknown metric: {metric}"),
            }
        }
    }
}

/// Assert that `mem.query_load.rss_bytes` in each tier's profile is within
/// 0.1x–10x of the `PROFILE_*K.mem_rss_bytes` constant.
///
/// `cpu_weight`, `query_rps`, and `indexing_rps` have no direct profile artifact
/// equivalent — they are architectural scheduling weights, not measured values.
///
/// Reason code: `PROFILE_DRIFT:mem:{tier}`
#[test]
fn profile_mem_drift_within_tolerance() {
    let profiles = [
        ("1k", common::capacity_profiles::PROFILE_1K.mem_rss_bytes),
        ("10k", common::capacity_profiles::PROFILE_10K.mem_rss_bytes),
        (
            "100k",
            common::capacity_profiles::PROFILE_100K.mem_rss_bytes,
        ),
    ];

    for (tier, constant_bytes) in profiles {
        if let Some(json) = load_profile(tier, "mem") {
            assert_drift_within_tolerance(
                tier,
                "mem",
                &json,
                "/envelope/query_load/rss_bytes",
                constant_bytes,
            );
        }
    }
}

/// Assert that `disk.post_seed.disk_bytes` in each tier's profile is within
/// 0.1x–10x of the `PROFILE_*K.disk_bytes` constant.
///
/// Reason code: `PROFILE_DRIFT:disk:{tier}`
#[test]
fn profile_disk_drift_within_tolerance() {
    let profiles = [
        ("1k", common::capacity_profiles::PROFILE_1K.disk_bytes),
        ("10k", common::capacity_profiles::PROFILE_10K.disk_bytes),
        ("100k", common::capacity_profiles::PROFILE_100K.disk_bytes),
    ];

    for (tier, constant_bytes) in profiles {
        if let Some(json) = load_profile(tier, "disk") {
            assert_drift_within_tolerance(
                tier,
                "disk",
                &json,
                "/envelope/post_seed/disk_bytes",
                constant_bytes,
            );
        }
    }
}

#[test]
fn bootstraps_missing_profiles_from_seed_script() {
    let unique = format!(
        "reliability-bootstrap-test-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .expect("system clock should be after epoch")
            .as_nanos()
    );
    let scratch_root = std::env::temp_dir().join(unique);
    let profiles_dir = scratch_root.join("profiles");
    let seed_script = scratch_root.join("seed.sh");
    std::fs::create_dir_all(&scratch_root).expect("scratch root should be creatable");

    // Keep the bootstrap fixture tiny: just make the files this test suite requires.
    let mut seed_program = format!(
        "#!/usr/bin/env bash\nset -euo pipefail\nmkdir -p \"{}\"\n",
        profiles_dir.display()
    );
    for tier in TIERS {
        for metric in METRICS {
            seed_program.push_str(&format!(
                "printf '{{}}\\n' > \"{}/{}_{}.json\"\n",
                profiles_dir.display(),
                tier,
                metric
            ));
        }
    }
    seed_program.push_str(&format!(
        "printf '{{}}\\n' > \"{}/summary.json\"\n",
        profiles_dir.display()
    ));
    std::fs::write(&seed_script, seed_program).expect("seed script should be writable");
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mut perms = std::fs::metadata(&seed_script)
            .expect("seed script metadata should exist")
            .permissions();
        perms.set_mode(0o755);
        std::fs::set_permissions(&seed_script, perms).expect("seed script should be executable");
    }

    let bootstrap_result = ensure_profile_artifacts_with_seed(&profiles_dir, &seed_script);
    assert!(
        bootstrap_result.is_ok(),
        "bootstrap should succeed with executable seed script: {bootstrap_result:?}"
    );
    assert!(
        profile_artifacts_exist_in(&profiles_dir),
        "bootstrap should materialize expected profile artifacts"
    );

    std::fs::remove_dir_all(&scratch_root).expect("scratch root should be removable");
}
