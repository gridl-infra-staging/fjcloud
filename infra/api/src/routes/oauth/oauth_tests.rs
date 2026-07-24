use super::GitHubEmailEntry;

#[test]
fn github_email_entry_deserializes_documented_schema() {
    let fixture = r#"[
        {
            "email": "octocat@github.com",
            "primary": true,
            "verified": true,
            "visibility": "public"
        },
        {
            "email": "backup@example.com",
            "primary": false,
            "verified": false,
            "visibility": null
        }
    ]"#;

    let entries: Vec<GitHubEmailEntry> =
        serde_json::from_str(fixture).expect("fixture must deserialize");
    assert_eq!(entries.len(), 2);

    let primary = entries
        .iter()
        .find(|e| e.primary)
        .expect("must have primary");
    assert_eq!(primary.email, "octocat@github.com");
    assert!(primary.verified);

    let secondary = entries
        .iter()
        .find(|e| !e.primary)
        .expect("must have non-primary");
    assert_eq!(secondary.email, "backup@example.com");
    assert!(!secondary.verified);
}
