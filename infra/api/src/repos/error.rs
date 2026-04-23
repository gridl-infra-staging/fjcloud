#[derive(Debug, thiserror::Error)]
pub enum RepoError {
    #[error("entity not found")]
    NotFound,

    #[error("{0}")]
    Conflict(String),

    #[error("{0}")]
    Other(String),
}

/// Returns true if a sqlx error is a Postgres unique constraint violation (code 23505).
/// Shared helper used by all Pg repo implementations.
pub fn is_unique_violation(err: &sqlx::Error) -> bool {
    matches!(err, sqlx::Error::Database(db_err) if db_err.code().as_deref() == Some("23505"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::borrow::Cow;

    /// Minimal mock of `sqlx::error::DatabaseError` for unit-testing
    /// `is_unique_violation` without a real Postgres connection.
    #[derive(Debug)]
    struct MockDbError {
        code: Option<String>,
    }

    impl std::fmt::Display for MockDbError {
        fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
            write!(f, "mock db error")
        }
    }

    impl std::error::Error for MockDbError {}

    impl sqlx::error::DatabaseError for MockDbError {
        fn message(&self) -> &str {
            "mock db error"
        }

        fn code(&self) -> Option<Cow<'_, str>> {
            self.code.as_deref().map(Cow::Borrowed)
        }

        fn as_error(&self) -> &(dyn std::error::Error + Send + Sync + 'static) {
            self
        }

        fn as_error_mut(&mut self) -> &mut (dyn std::error::Error + Send + Sync + 'static) {
            self
        }

        fn into_error(self: Box<Self>) -> Box<dyn std::error::Error + Send + Sync + 'static> {
            self
        }

        fn kind(&self) -> sqlx::error::ErrorKind {
            sqlx::error::ErrorKind::UniqueViolation
        }
    }

    fn db_error(code: Option<&str>) -> sqlx::Error {
        sqlx::Error::Database(Box::new(MockDbError {
            code: code.map(String::from),
        }))
    }

    #[test]
    fn unique_violation_23505_returns_true() {
        assert!(is_unique_violation(&db_error(Some("23505"))));
    }

    #[test]
    fn different_code_returns_false() {
        // 23503 = foreign_key_violation
        assert!(!is_unique_violation(&db_error(Some("23503"))));
    }

    #[test]
    fn no_code_returns_false() {
        assert!(!is_unique_violation(&db_error(None)));
    }

    #[test]
    fn non_database_error_returns_false() {
        let err = sqlx::Error::RowNotFound;
        assert!(!is_unique_violation(&err));
    }

    #[test]
    fn configuration_error_returns_false() {
        let err = sqlx::Error::Configuration("test".into());
        assert!(!is_unique_violation(&err));
    }
}
