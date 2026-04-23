// Public library interface for the aggregation-job crate.
// Exposes rollup and config modules so integration tests in other crates
// can import ROLLUP_SQL and day_window without duplicating them.

pub mod config;
pub mod rollup;
