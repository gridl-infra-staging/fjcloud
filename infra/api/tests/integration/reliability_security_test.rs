use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};

fn project_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .unwrap()
        .parent()
        .unwrap()
        .to_path_buf()
}

fn scan_for_unsafe_sql_patterns(dir: &PathBuf) -> Vec<(String, String)> {
    let mut findings = Vec::new();
    let unsafe_pattern = "sqlx::query(&";

    if let Ok(entries) = std::fs::read_dir(dir) {
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_dir() {
                findings.extend(scan_for_unsafe_sql_patterns(&path));
            } else if path.extension().is_some_and(|ext| ext == "rs") {
                if let Ok(content) = std::fs::read_to_string(&path) {
                    let mut search_content = content.as_str();
                    while let Some(pos) = search_content.find(unsafe_pattern) {
                        let line_num = content[..content.len() - search_content.len() + pos]
                            .matches('\n')
                            .count()
                            + 1;
                        let file = path
                            .file_name()
                            .and_then(|n| n.to_str())
                            .unwrap_or("unknown");
                        findings.push((file.to_string(), format!("line {}", line_num)));
                        search_content = &search_content[pos + unsafe_pattern.len()..];
                    }
                }
            }
        }
    }

    findings
}

fn scan_for_safe_sql_patterns(dir: &PathBuf) -> Vec<(String, String)> {
    let mut findings = Vec::new();

    let safe_patterns = ["sqlx::query(\"", "sqlx::query(r#\"", "sqlx::query(CONST"];

    if let Ok(entries) = std::fs::read_dir(dir) {
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_dir() {
                findings.extend(scan_for_safe_sql_patterns(&path));
            } else if path.extension().is_some_and(|ext| ext == "rs") {
                if let Ok(content) = std::fs::read_to_string(&path) {
                    for pattern in &safe_patterns {
                        if content.contains(pattern) {
                            let file = path
                                .file_name()
                                .and_then(|n| n.to_str())
                                .unwrap_or("unknown");
                            findings.push((file.to_string(), "safe pattern found".to_string()));
                        }
                    }
                }
            }
        }
    }

    findings
}

#[test]
fn test_sql_guard_detects_unsafe_patterns_in_fixture() {
    let fixture_path = project_root()
        .join("scripts")
        .join("reliability")
        .join("fixtures")
        .join("security");

    let findings = scan_for_unsafe_sql_patterns(&fixture_path);

    assert!(
        !findings.is_empty(),
        "SQL guard should detect unsafe patterns in fixture"
    );

    assert!(
        findings.iter().any(|(file, _)| file.contains("unsafe_sql")),
        "Should find unsafe pattern in unsafe_sql_examples.rs"
    );

    assert!(
        findings.iter().any(|(_, location)| location == "line 11"),
        "SQL guard should detect a query string passed by variable reference"
    );
}

#[test]
fn test_sql_guard_allows_safe_patterns() {
    let src_path = project_root().join("infra").join("api").join("src");

    let unsafe_findings = scan_for_unsafe_sql_patterns(&src_path);

    assert!(
        unsafe_findings.is_empty(),
        "Production source should have no unsafe SQL patterns, but found: {:?}",
        unsafe_findings
    );
}

#[test]
fn test_sql_guard_safe_patterns_exist() {
    let src_path = project_root().join("infra").join("api").join("src");

    let safe_findings = scan_for_safe_sql_patterns(&src_path);

    assert!(
        !safe_findings.is_empty(),
        "Production source should have safe sqlx::query patterns"
    );
}

#[test]
fn test_sql_guard_metering_agent_safe() {
    let src_path = project_root()
        .join("infra")
        .join("metering-agent")
        .join("src");

    if !src_path.exists() {
        return;
    }

    let unsafe_findings = scan_for_unsafe_sql_patterns(&src_path);

    assert!(
        unsafe_findings.is_empty(),
        "Metering agent should have no unsafe SQL patterns, but found: {:?}",
        unsafe_findings
    );
}

#[test]
fn test_sql_guard_does_not_flag_plus_outside_query_expression() {
    let ts = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let tmp_dir = std::env::temp_dir().join(format!("sql_guard_plus_outside_{ts}"));
    std::fs::create_dir_all(&tmp_dir).unwrap();
    let fixture_file = tmp_dir.join("outside_plus.rs");

    std::fs::write(
        &fixture_file,
        r#"
fn build_query() {
    let _ = sqlx::query("SELECT 1");
    let _unrelated = 1 + 2;
}
"#,
    )
    .unwrap();

    let findings = scan_for_unsafe_sql_patterns(&tmp_dir);

    std::fs::remove_dir_all(&tmp_dir).unwrap();

    assert!(
        findings.is_empty(),
        "plus outside sqlx::query argument should not be flagged, found: {:?}",
        findings
    );
}

#[test]
fn test_sql_guard_flags_plus_inside_query_expression() {
    let ts = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let tmp_dir = std::env::temp_dir().join(format!("sql_guard_plus_inside_{ts}"));
    std::fs::create_dir_all(&tmp_dir).unwrap();
    let fixture_file = tmp_dir.join("inside_plus.rs");

    std::fs::write(
        &fixture_file,
        r#"
fn build_query(base: String, suffix: String) {
    let _ = sqlx::query(&(base + suffix));
}
"#,
    )
    .unwrap();

    let findings = scan_for_unsafe_sql_patterns(&tmp_dir);

    std::fs::remove_dir_all(&tmp_dir).unwrap();

    assert!(
        !findings.is_empty(),
        "plus inside sqlx::query argument should be flagged"
    );
}
