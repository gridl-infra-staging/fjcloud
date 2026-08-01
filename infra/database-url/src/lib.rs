//! Shared policy for database connection URLs.
//!
//! This boundary is independent of the API crate because the metering agent,
//! aggregation job, and retention job must enforce the same connection policy
//! without depending on the API binary's application layer.

use std::net::IpAddr;

use percent_encoding::percent_decode_str;
use url::Url;

/// The `sslmode` values that enforce TLS on the PostgreSQL connection.
///
/// Single source of truth: the acceptance guard and the operator-facing error
/// message both derive their vocabulary from this list so they cannot drift.
const ACCEPTED_SSLMODES: [&str; 3] = ["require", "verify-ca", "verify-full"];

/// Validates the transport-security policy for `DATABASE_URL`.
///
/// SQLx defaults PostgreSQL connections to fallback-capable `sslmode=prefer`,
/// so non-loopback URLs must opt in to an enforcing mode explicitly. This
/// mirrors the API's requirement for `STORAGE_ENCRYPTION_KEY` outside local
/// development: unsafe defaults are allowed only when locality proves that the
/// connection is for development.
pub fn validate_database_url_tls(database_url: &str) -> Result<(), String> {
    let parsed_url = Url::parse(database_url)
        .map_err(|error| format!("invalid DATABASE_URL: {error}; {}", accepted_modes_clause()))?;

    if uses_local_database_transport(&parsed_url) {
        return Ok(());
    }

    // sqlx-postgres honors both `sslmode` and its `ssl-mode` alias
    // (sqlx-postgres src/options/parse.rs:52), applies repeated parameters in
    // order, and lowercases the final value before parsing
    // (src/options/ssl_mode.rs:38). Match that vocabulary exactly so this
    // guard validates the same effective mode sqlx will use.
    let effective_ssl_mode = parsed_url
        .query_pairs()
        .filter_map(|(key, value)| (key == "sslmode" || key == "ssl-mode").then_some(value))
        .last();

    match effective_ssl_mode {
        Some(ssl_mode) if ACCEPTED_SSLMODES.contains(&ssl_mode.to_ascii_lowercase().as_str()) => {
            Ok(())
        }
        _ => Err(tls_policy_error()),
    }
}

fn uses_local_database_transport(parsed_url: &Url) -> bool {
    let mut transport = DatabaseTransport::from_authority_host(parsed_url.host_str());

    for (key, value) in parsed_url.query_pairs() {
        match key.as_ref() {
            "host" => transport.apply_host_query_value(value.as_ref()),
            "hostaddr" => transport.apply_hostaddr_query_value(value.as_ref()),
            _ => {}
        }
    }

    transport.is_local()
}

enum DatabaseTransport {
    UnixSocket,
    TcpHost(Option<String>),
}

impl DatabaseTransport {
    fn from_authority_host(host: Option<&str>) -> Self {
        match host {
            Some(host)
                if percent_decode_str(host)
                    .decode_utf8_lossy()
                    .starts_with('/') =>
            {
                Self::UnixSocket
            }
            Some(host) => Self::TcpHost(Some(host.to_owned())),
            None => Self::TcpHost(None),
        }
    }

    fn apply_host_query_value(&mut self, host: &str) {
        if host.starts_with('/') {
            *self = Self::UnixSocket;
            return;
        }

        if matches!(self, Self::TcpHost(_)) {
            *self = Self::TcpHost(Some(host.to_owned()));
        }
    }

    fn apply_hostaddr_query_value(&mut self, host: &str) {
        if matches!(self, Self::TcpHost(_)) {
            *self = Self::TcpHost(Some(host.to_owned()));
        }
    }

    fn is_local(&self) -> bool {
        match self {
            Self::UnixSocket => true,
            Self::TcpHost(host) => is_loopback_host(host.as_deref()),
        }
    }
}

fn is_loopback_host(host: Option<&str>) -> bool {
    let Some(host) = host else {
        return false;
    };
    let address_text = host
        .strip_prefix('[')
        .and_then(|host| host.strip_suffix(']'))
        .unwrap_or(host);

    host.eq_ignore_ascii_case("localhost")
        || address_text
            .parse::<IpAddr>()
            .is_ok_and(|address| address.is_loopback())
}

fn tls_policy_error() -> String {
    format!(
        "DATABASE_URL must use {} for non-loopback PostgreSQL hosts",
        accepted_modes_clause()
    )
}

/// Renders the accepted enforcing modes as an operator-facing clause, e.g.
/// `sslmode=require, sslmode=verify-ca, or sslmode=verify-full`.
fn accepted_modes_clause() -> String {
    let rendered = ACCEPTED_SSLMODES
        .iter()
        .map(|mode| format!("sslmode={mode}"))
        .collect::<Vec<_>>();
    match rendered.split_last() {
        Some((last, leading)) if !leading.is_empty() => {
            format!("{}, or {last}", leading.join(", "))
        }
        _ => rendered.join(", "),
    }
}

#[cfg(test)]
mod tests {
    use super::validate_database_url_tls;

    #[test]
    fn database_url_tls_rejects_non_loopback_urls_without_enforced_tls() {
        let insecure_database_urls = [
            (
                "postgres without sslmode",
                "postgres://user:password@db.example.com/app",
            ),
            (
                "postgres with sslmode=disable",
                "postgres://user:password@db.example.com/app?sslmode=disable",
            ),
            (
                "postgres with sslmode=allow",
                "postgres://user:password@db.example.com/app?sslmode=allow",
            ),
            (
                "postgres with sslmode=prefer",
                "postgres://user:password@db.example.com/app?sslmode=prefer",
            ),
            (
                "postgresql without sslmode",
                "postgresql://user:password@db.example.com/app",
            ),
            (
                "postgresql with sslmode=disable",
                "postgresql://user:password@db.example.com/app?sslmode=disable",
            ),
            (
                "postgresql with sslmode=allow",
                "postgresql://user:password@db.example.com/app?sslmode=allow",
            ),
            (
                "postgresql with sslmode=prefer",
                "postgresql://user:password@db.example.com/app?sslmode=prefer",
            ),
        ];

        let unexpectedly_accepted = insecure_database_urls
            .iter()
            .filter_map(|(case, database_url)| {
                validate_database_url_tls(database_url)
                    .is_ok()
                    .then_some(*case)
            })
            .collect::<Vec<_>>();

        assert!(
            unexpectedly_accepted.is_empty(),
            "non-loopback DATABASE_URL values without enforced TLS were accepted: {}",
            unexpectedly_accepted.join(", ")
        );
    }

    #[test]
    fn database_url_tls_accepts_non_loopback_urls_with_enforced_tls() {
        for scheme in ["postgres", "postgresql"] {
            for sslmode in ["require", "verify-ca", "verify-full"] {
                let database_url =
                    format!("{scheme}://user:password@db.example.com/app?sslmode={sslmode}");

                assert_eq!(
                    validate_database_url_tls(&database_url),
                    Ok(()),
                    "{scheme} URL with sslmode={sslmode} should be accepted"
                );
            }
        }
    }

    #[test]
    fn database_url_tls_rejects_ssl_mode_alias_downgrade() {
        // sqlx-postgres honors the `ssl-mode` alias key with last-write-wins
        // (parse.rs:52), so an enforcing `sslmode` followed by a weakening
        // `ssl-mode` connects in plaintext. The validator must fail closed.
        let database_url =
            "postgres://user:password@db.example.com/app?sslmode=require&ssl-mode=disable";

        assert!(
            validate_database_url_tls(database_url).is_err(),
            "ssl-mode alias downgrading to disable must be rejected: {database_url}"
        );
    }

    #[test]
    fn database_url_tls_accepts_final_enforcing_ssl_mode() {
        // sqlx-postgres applies repeated `sslmode` and `ssl-mode` parameters
        // with last-write-wins semantics, so the final effective value governs.
        let database_url =
            "postgres://user:password@db.example.com/app?sslmode=disable&ssl-mode=require";

        assert_eq!(
            validate_database_url_tls(database_url),
            Ok(()),
            "a final enforcing ssl-mode value should be accepted"
        );
    }

    #[test]
    fn database_url_tls_accepts_ssl_mode_alias_key() {
        // sqlx accepts `ssl-mode` as an alias for `sslmode` (parse.rs:52), so a
        // secure connection configured that way must not be refused at startup.
        let database_url = "postgres://user:password@db.example.com/app?ssl-mode=require";

        assert_eq!(
            validate_database_url_tls(database_url),
            Ok(()),
            "ssl-mode alias with an enforcing value should be accepted"
        );
    }

    #[test]
    fn database_url_tls_accepts_uppercase_sslmode_value() {
        // sqlx lowercases the sslmode value before parsing (ssl_mode.rs:38), so
        // `REQUIRE` is a valid enforcing mode and must not be refused.
        for sslmode in ["REQUIRE", "Verify-CA", "VERIFY-FULL"] {
            let database_url =
                format!("postgres://user:password@db.example.com/app?sslmode={sslmode}");

            assert_eq!(
                validate_database_url_tls(&database_url),
                Ok(()),
                "uppercase sslmode={sslmode} should be accepted"
            );
        }
    }

    #[test]
    fn database_url_tls_accepts_loopback_urls_without_sslmode() {
        for host in ["localhost", "127.0.0.1", "[::1]"] {
            let database_url = format!("postgres://user:password@{host}/app");

            assert_eq!(
                validate_database_url_tls(&database_url),
                Ok(()),
                "loopback host {host} should remain valid for local development"
            );
        }
    }

    #[test]
    fn database_url_tls_rejects_remote_host_query_override() {
        let database_url = "postgres://user:password@localhost/app?host=db.example.com";

        assert!(
            validate_database_url_tls(database_url).is_err(),
            "sqlx host override must determine locality: {database_url}"
        );
    }

    #[test]
    fn database_url_tls_rejects_remote_hostaddr_query_override() {
        let database_url = "postgres://user:password@127.0.0.1/app?hostaddr=203.0.113.10";

        assert!(
            validate_database_url_tls(database_url).is_err(),
            "sqlx hostaddr override must determine locality: {database_url}"
        );
    }

    #[test]
    fn database_url_tls_accepts_unix_socket_host_override() {
        let database_url = "postgres://user:password@db.example.com/app?host=/var/run/postgresql";

        assert_eq!(
            validate_database_url_tls(database_url),
            Ok(()),
            "Unix-domain socket transport is local and should be exempt"
        );
    }

    #[test]
    fn database_url_tls_uses_last_sqlx_host_override() {
        let database_url = concat!(
            "postgres://user:password@localhost/app",
            "?host=db.example.com&hostaddr=127.0.0.1"
        );

        assert_eq!(
            validate_database_url_tls(database_url),
            Ok(()),
            "sqlx applies host and hostaddr query parameters in order"
        );
    }

    #[test]
    fn database_url_tls_accepts_percent_encoded_authority_unix_socket() {
        let database_url = "postgres://%2Fvar%2Flib%2Fpostgres/database";

        assert_eq!(
            validate_database_url_tls(database_url),
            Ok(()),
            "sqlx percent-decodes slash-prefixed authority hosts as Unix sockets"
        );
    }

    #[test]
    fn database_url_tls_keeps_socket_transport_after_later_hostaddr() {
        let database_url = concat!(
            "postgres://user:password@db.example.com/app",
            "?host=/var/run/postgresql&hostaddr=203.0.113.10"
        );

        assert_eq!(
            validate_database_url_tls(database_url),
            Ok(()),
            "sqlx keeps the selected Unix socket even when later hostaddr updates the TCP host"
        );
    }

    #[test]
    fn database_url_tls_rejection_explains_the_required_configuration() {
        let error = validate_database_url_tls("postgres://user:password@db.example.com/app")
            .expect_err("a non-loopback DATABASE_URL without sslmode must be rejected");
        let message = error.to_string();

        for expected_text in [
            "DATABASE_URL",
            "sslmode=require",
            "sslmode=verify-ca",
            "sslmode=verify-full",
        ] {
            assert!(
                message.contains(expected_text),
                "validation error should mention {expected_text:?}, got {message:?}"
            );
        }
    }
}
