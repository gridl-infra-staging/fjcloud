pub(crate) fn doc_comment_immediately_before(
    source: &str,
    owner_declaration: &str,
) -> Option<String> {
    let source_lines = source.lines().collect::<Vec<_>>();
    let owner_index = source_lines
        .iter()
        .position(|line| *line == owner_declaration)?;
    let mut doc_lines = source_lines[..owner_index]
        .iter()
        .rev()
        .take_while(|line| line.starts_with("///"))
        .copied()
        .collect::<Vec<_>>();

    if doc_lines.is_empty() {
        return None;
    }

    doc_lines.reverse();
    Some(doc_lines.join("\n"))
}

#[cfg(test)]
mod tests {
    use super::doc_comment_immediately_before;

    #[test]
    fn extracts_only_the_contiguous_doc_comment_before_owner() {
        let source = "unrelated\n/// First line.\n/// Second line.\npub const OWNER: u8 = 1;\n";

        assert_eq!(
            doc_comment_immediately_before(source, "pub const OWNER: u8 = 1;"),
            Some("/// First line.\n/// Second line.".to_string())
        );
    }

    #[test]
    fn owner_lookup_ignores_target_literals_in_test_body() {
        let source = r#"
mod tests {
    const TARGETS: &[&str] = &[
        "pub const DEDICATED_MASTER_INSTANCE_NAME: &str = \"m6g.large.search\";",
        "pub fn estimate(workload: &WorkloadProfile) -> EstimatedCost {",
        "const ELASTICSEARCH_MIN_RAM_GIB: Decimal = dec!(4.0);",
    ];
}
"#;

        for target in [
            "pub const DEDICATED_MASTER_INSTANCE_NAME: &str = \"m6g.large.search\";",
            "pub fn estimate(workload: &WorkloadProfile) -> EstimatedCost {",
            "const ELASTICSEARCH_MIN_RAM_GIB: Decimal = dec!(4.0);",
        ] {
            assert_eq!(doc_comment_immediately_before(source, target), None);
        }
    }

    #[test]
    fn rejects_a_non_adjacent_doc_comment() {
        let source = "/// Stale docs.\n\npub fn owner() {}\n";

        assert_eq!(
            doc_comment_immediately_before(source, "pub fn owner() {}"),
            None
        );
    }

    #[test]
    fn rejects_a_longer_owner_name_with_the_same_prefix() {
        let source = "/// Different owner's docs.\npub fn owner_v2() {}\n";

        assert_eq!(
            doc_comment_immediately_before(source, "pub fn owner() {}"),
            None
        );
    }
}
