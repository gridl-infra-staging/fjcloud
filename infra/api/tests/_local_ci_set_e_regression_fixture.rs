//! Regression fixture for scripts/tests/local_ci_gate_set_e_test.sh.
#[test]
fn fixture_intentionally_too_long() {
    assert_eq!(std::env::var("LOCAL_CI_REGRESSION_FIXTURE").ok().as_deref(), Some("intentional_long_line_to_force_a_rustfmt_diff_so_we_test_the_gate_contract"));
}
