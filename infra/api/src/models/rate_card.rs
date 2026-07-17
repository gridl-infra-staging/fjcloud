//! Rate card database model and API conversion layer.
use crate::errors::ApiError;
use chrono::{DateTime, Utc};
use rust_decimal::Decimal;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use uuid::Uuid;

/// Database row representing a pricing configuration. Includes rates for hot and cold storage, object storage, region multipliers, and minimum spend tiers. Implements serialization and database row mapping.
#[derive(Debug, Clone, Serialize, Deserialize, sqlx::FromRow)]
pub struct RateCardRow {
    pub id: Uuid,
    pub name: String,
    pub effective_from: DateTime<Utc>,
    pub effective_until: Option<DateTime<Utc>>,
    pub storage_rate_per_mb_month: Decimal,
    pub region_multipliers: serde_json::Value,
    pub minimum_spend_cents: i64,
    pub shared_minimum_spend_cents: i64,
    pub cold_storage_rate_per_gb_month: Decimal,
    pub object_storage_rate_per_gb_month: Decimal,
    pub object_storage_egress_rate_per_gb: Decimal,
    pub created_at: DateTime<Utc>,
}

impl RateCardRow {
    /// Parse a JSON value (string or number) into a Decimal, with a contextual error message.
    fn parse_json_decimal(value: &serde_json::Value, context: &str) -> Result<Decimal, ApiError> {
        match value {
            serde_json::Value::String(raw) => raw
                .parse::<Decimal>()
                .map_err(|_| ApiError::Internal(format!("{context} must be a decimal string"))),
            serde_json::Value::Number(raw) => raw
                .to_string()
                .parse::<Decimal>()
                .map_err(|_| ApiError::Internal(format!("{context} must be a decimal number"))),
            _ => Err(ApiError::Internal(format!(
                "{context} must be a decimal string"
            ))),
        }
    }

    fn decimal_override(
        overrides: &serde_json::Value,
        field: &str,
    ) -> Result<Option<Decimal>, ApiError> {
        let Some(value) = overrides.get(field) else {
            return Ok(None);
        };
        Self::parse_json_decimal(value, &format!("rate card override field `{field}`")).map(Some)
    }

    fn integer_override(
        overrides: &serde_json::Value,
        field: &str,
    ) -> Result<Option<i64>, ApiError> {
        let Some(value) = overrides.get(field) else {
            return Ok(None);
        };

        value.as_i64().map(Some).ok_or_else(|| {
            ApiError::Internal(format!(
                "rate card override field `{field}` must be an integer"
            ))
        })
    }

    fn apply_decimal_override(
        target: &mut Decimal,
        overrides: &serde_json::Value,
        field: &str,
    ) -> Result<(), ApiError> {
        if let Some(value) = Self::decimal_override(overrides, field)? {
            *target = value;
        }
        Ok(())
    }

    fn apply_integer_override(
        target: &mut i64,
        overrides: &serde_json::Value,
        field: &str,
    ) -> Result<(), ApiError> {
        if let Some(value) = Self::integer_override(overrides, field)? {
            *target = value;
        }
        Ok(())
    }

    /// Parses a JSON object into a `HashMap<String, Decimal>` of region
    /// multipliers. Rejects non-object input and negative multiplier values.
    pub fn parse_region_multiplier_map(
        region_multipliers: &serde_json::Value,
    ) -> Result<HashMap<String, Decimal>, ApiError> {
        let serde_json::Value::Object(entries) = region_multipliers else {
            return Err(ApiError::Internal(
                "region_multipliers must be a JSON object keyed by region".into(),
            ));
        };

        let mut parsed = HashMap::new();
        for (region, value) in entries {
            let multiplier =
                Self::parse_json_decimal(value, &format!("region multiplier for `{region}`"))?;

            if multiplier < Decimal::ZERO {
                return Err(ApiError::Internal(format!(
                    "region multiplier for `{region}` must not be negative"
                )));
            }

            parsed.insert(region.clone(), multiplier);
        }

        Ok(parsed)
    }

    pub fn normalized_region_multiplier_value(
        region_multipliers: &serde_json::Value,
    ) -> Result<serde_json::Value, ApiError> {
        let parsed = Self::parse_region_multiplier_map(region_multipliers)?;
        let normalized = parsed
            .into_iter()
            .map(|(region, multiplier)| (region, serde_json::Value::String(multiplier.to_string())))
            .collect();
        Ok(serde_json::Value::Object(normalized))
    }

    /// Clones self and applies decimal and integer field overrides from a JSON
    /// object, then re-normalizes `region_multipliers` from the updated JSON.
    pub fn with_overrides(&self, overrides: &serde_json::Value) -> Result<Self, ApiError> {
        let mut result = self.clone();

        Self::apply_decimal_override(
            &mut result.storage_rate_per_mb_month,
            overrides,
            "storage_rate_per_mb_month",
        )?;
        Self::apply_decimal_override(
            &mut result.cold_storage_rate_per_gb_month,
            overrides,
            "cold_storage_rate_per_gb_month",
        )?;
        Self::apply_decimal_override(
            &mut result.object_storage_rate_per_gb_month,
            overrides,
            "object_storage_rate_per_gb_month",
        )?;
        Self::apply_decimal_override(
            &mut result.object_storage_egress_rate_per_gb,
            overrides,
            "object_storage_egress_rate_per_gb",
        )?;

        Self::apply_integer_override(
            &mut result.minimum_spend_cents,
            overrides,
            "minimum_spend_cents",
        )?;
        Self::apply_integer_override(
            &mut result.shared_minimum_spend_cents,
            overrides,
            "shared_minimum_spend_cents",
        )?;

        if let Some(v) = overrides.get("region_multipliers") {
            result.region_multipliers = Self::normalized_region_multiplier_value(v)?;
        }

        Ok(result)
    }

    /// Converts this row into the billing crate.s [`RateCard`], parsing the
    /// `region_multipliers` JSON field.
    pub fn to_billing_rate_card(&self) -> Result<billing::rate_card::RateCard, ApiError> {
        let multipliers = Self::parse_region_multiplier_map(&self.region_multipliers)?;

        Ok(billing::rate_card::RateCard {
            id: self.id,
            name: self.name.clone(),
            effective_from: self.effective_from,
            effective_until: self.effective_until,
            storage_rate_per_mb_month: self.storage_rate_per_mb_month,
            region_multipliers: multipliers,
            minimum_spend_cents: self.minimum_spend_cents,
            shared_minimum_spend_cents: self.shared_minimum_spend_cents,
            cold_storage_rate_per_gb_month: self.cold_storage_rate_per_gb_month,
            object_storage_rate_per_gb_month: self.object_storage_rate_per_gb_month,
            object_storage_egress_rate_per_gb: self.object_storage_egress_rate_per_gb,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::Utc;
    use rust_decimal_macros::dec;
    use serde_json::json;

    /// Test helper: creates a [`RateCardRow`] with standard test values.
    fn test_card() -> RateCardRow {
        RateCardRow {
            id: Uuid::new_v4(),
            name: "default".to_string(),
            effective_from: Utc::now(),
            effective_until: None,
            storage_rate_per_mb_month: dec!(0.20),
            region_multipliers: json!({}),
            minimum_spend_cents: 500,
            shared_minimum_spend_cents: 200,
            cold_storage_rate_per_gb_month: dec!(0.02),
            object_storage_rate_per_gb_month: dec!(0.024),
            object_storage_egress_rate_per_gb: dec!(0.01),
            created_at: Utc::now(),
        }
    }

    /// Verifies that `storage_rate` and minimum-spend fields are overridden.
    #[test]
    fn with_overrides_applies_decimal_fields() {
        let card = test_card();
        let overrides = json!({
            "storage_rate_per_mb_month": "1.00",
            "minimum_spend_cents": 1000,
            "shared_minimum_spend_cents": 800
        });
        let effective = card
            .with_overrides(&overrides)
            .expect("overrides should parse");

        assert_eq!(effective.storage_rate_per_mb_month, dec!(1.00));
        assert_eq!(effective.minimum_spend_cents, 1000);
        assert_eq!(effective.shared_minimum_spend_cents, 800);
        assert_eq!(
            effective.object_storage_rate_per_gb_month,
            card.object_storage_rate_per_gb_month
        );
    }

    /// Verifies that `cold_storage_rate` is overridden while other rates
    /// remain unchanged.
    #[test]
    fn with_overrides_applies_cold_storage() {
        let card = test_card();
        let overrides = json!({
            "cold_storage_rate_per_gb_month": "0.01",
        });
        let effective = card
            .with_overrides(&overrides)
            .expect("overrides should parse");

        assert_eq!(effective.cold_storage_rate_per_gb_month, dec!(0.01));
        assert_eq!(
            effective.storage_rate_per_mb_month,
            card.storage_rate_per_mb_month
        );
        assert_eq!(effective.minimum_spend_cents, card.minimum_spend_cents);
        assert_eq!(
            effective.shared_minimum_spend_cents,
            card.shared_minimum_spend_cents
        );
    }

    /// Verifies that empty overrides leave all fields unchanged.
    #[test]
    fn with_overrides_noop_on_empty_json() {
        let card = test_card();
        let effective = card
            .with_overrides(&json!({}))
            .expect("empty overrides should parse");

        assert_eq!(
            effective.storage_rate_per_mb_month,
            card.storage_rate_per_mb_month
        );
        assert_eq!(effective.minimum_spend_cents, card.minimum_spend_cents);
        assert_eq!(
            effective.shared_minimum_spend_cents,
            card.shared_minimum_spend_cents
        );
        assert_eq!(effective.region_multipliers, card.region_multipliers);
        assert_eq!(
            effective.object_storage_rate_per_gb_month,
            card.object_storage_rate_per_gb_month
        );
        assert_eq!(
            effective.object_storage_egress_rate_per_gb,
            card.object_storage_egress_rate_per_gb
        );
    }

    /// Verifies that object storage rate and egress rate are overridden.
    #[test]
    fn with_overrides_applies_object_storage_fields() {
        let card = test_card();
        let overrides = json!({
            "object_storage_rate_per_gb_month": "0.05",
            "object_storage_egress_rate_per_gb": "0.02",
        });
        let effective = card
            .with_overrides(&overrides)
            .expect("overrides should parse");

        assert_eq!(effective.object_storage_rate_per_gb_month, dec!(0.05));
        assert_eq!(effective.object_storage_egress_rate_per_gb, dec!(0.02));
        // Other fields unchanged
        assert_eq!(
            effective.storage_rate_per_mb_month,
            card.storage_rate_per_mb_month
        );
        assert_eq!(
            effective.cold_storage_rate_per_gb_month,
            card.cold_storage_rate_per_gb_month
        );
    }

    /// Verifies that the shared minimum spend is overridden independently
    /// of other fields.
    #[test]
    fn with_overrides_applies_shared_minimum_spend_cents() {
        let card = test_card();
        let overrides = json!({
            "shared_minimum_spend_cents": 250,
        });
        let effective = card
            .with_overrides(&overrides)
            .expect("overrides should parse");

        assert_eq!(effective.shared_minimum_spend_cents, 250);
        assert_eq!(effective.minimum_spend_cents, card.minimum_spend_cents);
        assert_eq!(
            effective.storage_rate_per_mb_month,
            card.storage_rate_per_mb_month
        );
    }

    #[test]
    fn rate_card_row_serde_roundtrip_preserves_shared_minimum_spend_cents() {
        let card = test_card();
        let serialized = serde_json::to_string(&card).expect("serialize rate card");
        let parsed: RateCardRow = serde_json::from_str(&serialized).expect("deserialize rate card");

        assert_eq!(
            parsed.shared_minimum_spend_cents,
            card.shared_minimum_spend_cents
        );
    }

    #[test]
    fn to_billing_rate_card_includes_object_storage() {
        let card = test_card();
        let billing_card = card
            .to_billing_rate_card()
            .expect("rate card should convert");

        assert_eq!(billing_card.storage_rate_per_mb_month, dec!(0.20));
        assert_eq!(billing_card.object_storage_rate_per_gb_month, dec!(0.024));
        assert_eq!(billing_card.object_storage_egress_rate_per_gb, dec!(0.01));
        assert_eq!(
            billing_card.shared_minimum_spend_cents,
            card.shared_minimum_spend_cents
        );
    }

    #[test]
    fn with_overrides_rejects_invalid_decimal_override() {
        let card = test_card();
        let err = card
            .with_overrides(&json!({
                "storage_rate_per_mb_month": "not-a-decimal"
            }))
            .expect_err("invalid override should fail");

        match err {
            ApiError::Internal(msg) => {
                assert!(msg.contains("storage_rate_per_mb_month"));
            }
            other => panic!("expected Internal, got {other:?}"),
        }
    }

    #[test]
    fn parse_region_multiplier_map_rejects_invalid_shape() {
        let err = RateCardRow::parse_region_multiplier_map(&json!(["eu-west-1"]))
            .expect_err("invalid shape should fail");

        match err {
            ApiError::Internal(msg) => {
                assert!(msg.contains("region_multipliers"));
            }
            other => panic!("expected Internal, got {other:?}"),
        }
    }

    #[test]
    fn parse_region_multiplier_map_rejects_negative_values() {
        let err = RateCardRow::parse_region_multiplier_map(&json!({
            "eu-west-1": "-0.5"
        }))
        .expect_err("negative multiplier should fail");

        match err {
            ApiError::Internal(msg) => {
                assert!(msg.contains("must not be negative"));
            }
            other => panic!("expected Internal, got {other:?}"),
        }
    }
}
