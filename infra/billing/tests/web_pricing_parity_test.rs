use std::collections::HashMap;

#[derive(Debug, Clone, PartialEq, Eq)]
struct PricingSnapshot {
    storage_rate_per_mb_month: String,
    cold_storage_rate_per_gb_month: String,
    minimum_spend_cents: i64,
    region_pricing: Vec<RegionPricing>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct RegionPricing {
    id: String,
    display_name: String,
    multiplier: String,
}

#[test]
fn marketing_pricing_and_migrations_stay_in_parity_for_launch_contract() {
    const PRICING_TS: &str = include_str!("../../../web/src/lib/pricing.ts");
    const MIGRATION_016: &str = include_str!("../../migrations/016_cold_storage_pricing.sql");
    const MIGRATION_036: &str = include_str!("../../migrations/036_per_mb_pricing.sql");
    const MIGRATION_042: &str =
        include_str!("../../migrations/042_align_launch_rate_card_marketing_contract.sql");

    let marketing_snapshot = extract_marketing_snapshot(PRICING_TS);
    let migration_snapshot =
        extract_migration_snapshot(PRICING_TS, MIGRATION_016, MIGRATION_036, MIGRATION_042);

    assert_eq!(
        migration_snapshot, marketing_snapshot,
        "launch migration snapshot must match MARKETING_PRICING for overlapping pricing contract fields",
    );
}

#[test]
fn extract_integer_field_requires_exact_field_name_match() {
    let pricing_object = r#"
        shared_minimum_spend_cents: 500,
        minimum_spend_cents: 1000,
    "#;

    assert_eq!(
        extract_integer_field(pricing_object, "minimum_spend_cents"),
        1000
    );
}

#[test]
fn extract_last_sql_assignment_ignores_shared_minimum_column() {
    let sql = r#"
        UPDATE rate_cards
        SET minimum_spend_cents = 1000,
            shared_minimum_spend_cents = 500
        WHERE name = 'launch-2026';
    "#;

    assert_eq!(
        extract_last_sql_assignment(sql, "minimum_spend_cents"),
        "1000"
    );
}

fn extract_marketing_snapshot(pricing_ts: &str) -> PricingSnapshot {
    let marketing_object =
        extract_balanced_block(pricing_ts, "export const MARKETING_PRICING", '{', '}');
    let region_array = extract_balanced_block(&marketing_object, "region_pricing", '[', ']');

    PricingSnapshot {
        storage_rate_per_mb_month: normalize_currency(&extract_single_quoted_field(
            &marketing_object,
            "storage_rate_per_mb_month",
        )),
        cold_storage_rate_per_gb_month: normalize_currency(&extract_single_quoted_field(
            &marketing_object,
            "cold_storage_rate_per_gb_month",
        )),
        minimum_spend_cents: extract_integer_field(&marketing_object, "minimum_spend_cents"),
        region_pricing: parse_marketing_regions(&region_array),
    }
}

fn extract_migration_snapshot(
    pricing_ts: &str,
    migration_016: &str,
    migration_036: &str,
    migration_042: &str,
) -> PricingSnapshot {
    let marketing_snapshot = extract_marketing_snapshot(pricing_ts);
    let display_name_by_region_id: HashMap<String, String> = marketing_snapshot
        .region_pricing
        .iter()
        .map(|region| (region.id.clone(), region.display_name.clone()))
        .collect();

    let storage_rate_per_mb_month = normalize_currency(&extract_last_sql_assignment(
        migration_036,
        "storage_rate_per_mb_month",
    ));
    let cold_storage_rate_per_gb_month = normalize_currency(&extract_last_sql_assignment(
        migration_016,
        "cold_storage_rate_per_gb_month",
    ));
    let minimum_spend_cents = extract_last_sql_assignment(migration_042, "minimum_spend_cents")
        .parse::<i64>()
        .expect("minimum_spend_cents assignment must be an integer");

    let migration_region_order = parse_region_multiplier_json_object(migration_042);
    let region_pricing = migration_region_order
        .into_iter()
        .map(|(region_id, raw_multiplier)| {
            let display_name = display_name_by_region_id
                .get(&region_id)
                .unwrap_or_else(|| {
                    panic!(
                        "migration region_multipliers contains unknown region id: {}",
                        region_id,
                    )
                })
                .clone();

            RegionPricing {
                id: region_id,
                display_name,
                multiplier: normalize_multiplier(&raw_multiplier),
            }
        })
        .collect();

    PricingSnapshot {
        storage_rate_per_mb_month,
        cold_storage_rate_per_gb_month,
        minimum_spend_cents,
        region_pricing,
    }
}

fn parse_marketing_regions(region_array: &str) -> Vec<RegionPricing> {
    region_array
        .lines()
        .filter_map(|line| {
            let trimmed = line.trim();
            if !trimmed.starts_with('{') {
                return None;
            }

            Some(RegionPricing {
                id: extract_single_quoted_field(trimmed, "id"),
                display_name: extract_single_quoted_field(trimmed, "display_name"),
                multiplier: normalize_multiplier(&extract_single_quoted_field(
                    trimmed,
                    "multiplier",
                )),
            })
        })
        .collect()
}

fn parse_region_multiplier_json_object(migration_042: &str) -> Vec<(String, String)> {
    let json_block = extract_between(migration_042, "region_multipliers = '{", "}'::jsonb");

    json_block
        .lines()
        .filter_map(|line| {
            let trimmed = line.trim().trim_end_matches(',');
            if !trimmed.starts_with('"') {
                return None;
            }
            let (region_id, raw_multiplier) = trimmed
                .split_once(':')
                .expect("region multiplier line must contain ':' separator");
            Some((
                region_id.trim().trim_matches('"').to_string(),
                raw_multiplier.trim().trim_matches('"').to_string(),
            ))
        })
        .collect()
}

fn extract_single_quoted_field(input: &str, field_name: &str) -> String {
    let marker = format!("{}:", field_name);
    let field_start = input
        .find(&marker)
        .unwrap_or_else(|| panic!("missing field '{}'", field_name));
    let after_marker = &input[field_start + marker.len()..];
    let quote_start = after_marker
        .find('\'')
        .unwrap_or_else(|| panic!("field '{}' is missing opening quote", field_name));
    let rest = &after_marker[quote_start + 1..];
    let quote_end = rest
        .find('\'')
        .unwrap_or_else(|| panic!("field '{}' is missing closing quote", field_name));
    rest[..quote_end].to_string()
}

fn extract_integer_field(input: &str, field_name: &str) -> i64 {
    for line in input.lines() {
        let trimmed = line.trim();
        let Some((lhs, rhs)) = trimmed.split_once(':') else {
            continue;
        };
        let lhs_token = lhs
            .split_whitespace()
            .last()
            .unwrap_or_default()
            .trim_end_matches(',');
        if lhs_token != field_name {
            continue;
        }

        let numeric: String = rhs
            .chars()
            .skip_while(|ch| ch.is_whitespace())
            .take_while(|ch| ch.is_ascii_digit())
            .collect();

        return numeric
            .parse::<i64>()
            .unwrap_or_else(|_| panic!("field '{}' is not an integer", field_name));
    }

    panic!("missing integer field '{}'", field_name)
}

fn extract_last_sql_assignment(sql: &str, column_name: &str) -> String {
    let mut last_value: Option<String> = None;

    for line in sql.lines() {
        let trimmed = line.trim();
        let Some((lhs, rhs)) = trimmed.split_once('=') else {
            continue;
        };
        let lhs_token = lhs
            .split_whitespace()
            .last()
            .unwrap_or_default()
            .trim_end_matches(',');
        if lhs_token != column_name {
            continue;
        }

        let value: String = rhs
            .chars()
            .skip_while(|ch| ch.is_whitespace())
            .take_while(|ch| ch.is_ascii_digit() || *ch == '.')
            .collect();
        if !value.is_empty() {
            last_value = Some(value);
        }
    }

    last_value.unwrap_or_else(|| panic!("missing assignment for '{}'", column_name))
}

fn normalize_currency(raw: &str) -> String {
    let decimal = parse_decimal(raw);
    format!("${decimal:.2}")
}

fn normalize_multiplier(raw: &str) -> String {
    let decimal = parse_decimal(raw);
    format!("{decimal:.2}x")
}

fn parse_decimal(raw: &str) -> f64 {
    let cleaned = raw.trim().trim_start_matches('$').trim_end_matches('x');
    cleaned
        .parse::<f64>()
        .unwrap_or_else(|_| panic!("could not parse decimal value '{}'", raw))
}

fn extract_between<'a>(input: &'a str, start_marker: &str, end_marker: &str) -> &'a str {
    let start = input
        .find(start_marker)
        .unwrap_or_else(|| panic!("missing start marker '{}'", start_marker));
    let after_start = start + start_marker.len();
    let end = input[after_start..]
        .find(end_marker)
        .unwrap_or_else(|| panic!("missing end marker '{}'", end_marker));
    &input[after_start..after_start + end]
}

fn extract_balanced_block(input: &str, anchor: &str, open: char, close: char) -> String {
    let anchor_index = input
        .find(anchor)
        .unwrap_or_else(|| panic!("missing anchor '{}'", anchor));
    let start = input[anchor_index..]
        .find(open)
        .map(|offset| anchor_index + offset)
        .unwrap_or_else(|| panic!("missing opening delimiter '{}' for '{}'", open, anchor));

    let mut depth = 0usize;
    for (offset, ch) in input[start..].char_indices() {
        if ch == open {
            depth += 1;
        } else if ch == close {
            depth = depth
                .checked_sub(1)
                .unwrap_or_else(|| panic!("unbalanced delimiters around '{}'", anchor));
            if depth == 0 {
                return input[start..=start + offset].to_string();
            }
        }
    }

    panic!("unterminated block for anchor '{}'", anchor);
}
