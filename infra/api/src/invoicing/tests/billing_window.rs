use super::*;
use chrono::{TimeZone, Utc};

#[test]
fn billing_window_preserves_anchor_day_when_day_exists() {
    let anchor_at = Utc.with_ymd_and_hms(2026, 1, 15, 18, 45, 0).unwrap();
    let reference_at = Utc.with_ymd_and_hms(2026, 4, 20, 12, 0, 0).unwrap();

    let (start, end) = anchored_invoice_window_utc_dates(anchor_at, reference_at);

    assert_eq!(start, NaiveDate::from_ymd_opt(2026, 4, 15).unwrap());
    assert_eq!(end, NaiveDate::from_ymd_opt(2026, 5, 15).unwrap());
}

#[test]
fn billing_window_clamps_31st_anchor_for_shorter_months() {
    let anchor_at = Utc.with_ymd_and_hms(2026, 1, 31, 9, 0, 0).unwrap();

    let april_reference = Utc.with_ymd_and_hms(2026, 4, 30, 4, 0, 0).unwrap();
    let (april_start, april_end) = anchored_invoice_window_utc_dates(anchor_at, april_reference);
    assert_eq!(april_start, NaiveDate::from_ymd_opt(2026, 4, 30).unwrap());
    assert_eq!(april_end, NaiveDate::from_ymd_opt(2026, 5, 31).unwrap());

    let june_reference = Utc.with_ymd_and_hms(2026, 6, 30, 4, 0, 0).unwrap();
    let (june_start, june_end) = anchored_invoice_window_utc_dates(anchor_at, june_reference);
    assert_eq!(june_start, NaiveDate::from_ymd_opt(2026, 6, 30).unwrap());
    assert_eq!(june_end, NaiveDate::from_ymd_opt(2026, 7, 31).unwrap());
}

#[test]
fn billing_window_clamps_30th_anchor_for_february() {
    let anchor_at = Utc.with_ymd_and_hms(2026, 1, 30, 23, 0, 0).unwrap();
    let reference_at = Utc.with_ymd_and_hms(2026, 2, 28, 1, 0, 0).unwrap();

    let (start, end) = anchored_invoice_window_utc_dates(anchor_at, reference_at);

    assert_eq!(start, NaiveDate::from_ymd_opt(2026, 2, 28).unwrap());
    assert_eq!(end, NaiveDate::from_ymd_opt(2026, 3, 30).unwrap());
}

#[test]
fn billing_window_clamps_29th_anchor_for_non_leap_february() {
    let anchor_at = Utc.with_ymd_and_hms(2024, 2, 29, 12, 0, 0).unwrap();
    let reference_at = Utc.with_ymd_and_hms(2025, 2, 28, 8, 30, 0).unwrap();

    let (start, end) = anchored_invoice_window_utc_dates(anchor_at, reference_at);

    assert_eq!(start, NaiveDate::from_ymd_opt(2025, 2, 28).unwrap());
    assert_eq!(end, NaiveDate::from_ymd_opt(2025, 3, 29).unwrap());
}

#[test]
fn billing_window_has_deterministic_utc_dates_across_dst_crossing_anchor_timestamp() {
    // 2025-03-09 is the US spring DST transition date. The helper must
    // remain UTC-date deterministic regardless of that local-time boundary.
    let anchor_at = Utc.with_ymd_and_hms(2025, 3, 9, 7, 30, 0).unwrap();
    let reference_at = Utc.with_ymd_and_hms(2025, 11, 12, 5, 0, 0).unwrap();

    let (start, end) = anchored_invoice_window_utc_dates(anchor_at, reference_at);

    assert_eq!(start, NaiveDate::from_ymd_opt(2025, 11, 9).unwrap());
    assert_eq!(end, NaiveDate::from_ymd_opt(2025, 12, 9).unwrap());
}

#[test]
fn billing_window_handles_leap_year_february_anchor_day() {
    let anchor_at = Utc.with_ymd_and_hms(2024, 1, 31, 10, 0, 0).unwrap();
    let reference_at = Utc.with_ymd_and_hms(2024, 2, 29, 3, 0, 0).unwrap();

    let (start, end) = anchored_invoice_window_utc_dates(anchor_at, reference_at);

    assert_eq!(start, NaiveDate::from_ymd_opt(2024, 2, 29).unwrap());
    assert_eq!(end, NaiveDate::from_ymd_opt(2024, 3, 31).unwrap());
}

#[test]
fn billing_window_handles_non_leap_year_february_anchor_day() {
    let anchor_at = Utc.with_ymd_and_hms(2025, 1, 31, 10, 0, 0).unwrap();
    let reference_at = Utc.with_ymd_and_hms(2025, 2, 28, 3, 0, 0).unwrap();

    let (start, end) = anchored_invoice_window_utc_dates(anchor_at, reference_at);

    assert_eq!(start, NaiveDate::from_ymd_opt(2025, 2, 28).unwrap());
    assert_eq!(end, NaiveDate::from_ymd_opt(2025, 3, 31).unwrap());
}
