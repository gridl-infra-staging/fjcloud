use serde_json::{json, Map, Value};

const CONTRACT_JSON: &str = include_str!("../fixtures/algolia_migration_engine_contract.json");
const RECEIPT_JSON: &str = include_str!(
    "../../../../docs/runbooks/evidence/algolia-migration/20260726_l20_privacy_exact_erasure_acceptance_receipt.json"
);
// This historical receipt must retain the engine it actually tested even as the live
// migration contract advances to newer engine revisions.
const RECEIPT_ENGINE_SHA: &str = "320132fcd12a71d441d70a30c34ce66c64f21d46";

type ReceiptMutation = (&'static str, Box<dyn Fn(&mut Value)>, &'static str);

#[test]
fn privacy_exact_erasure_receipt_records_exact_counts() {
    let contract = contract();
    let receipt = receipt();

    validate_receipt(&receipt, &contract).expect("exact-erasure receipt must validate");
}

#[test]
fn privacy_exact_erasure_receipt_rejects_drifted_evidence() {
    let contract = contract();
    let baseline = receipt();

    let mutations: Vec<ReceiptMutation> = vec![
        (
            "missing declared resource class",
            Box::new(|payload| {
                payload["exact_absence_resource_classes"]
                    .as_array_mut()
                    .expect("classes must be mutable")
                    .pop();
            }),
            "receipt exact absence classes must match contract",
        ),
        (
            "duplicate durable ACK",
            Box::new(|payload| {
                payload["final_counts"]["durable_acks"] = json!(2);
            }),
            "durable ACK count must be exactly 1",
        ),
        (
            "extra transmission",
            Box::new(|payload| {
                payload["final_counts"]["transmissions"] = json!(3);
            }),
            "receipt field transmissions must be 2",
        ),
        (
            "missing tombstone",
            Box::new(|payload| {
                payload["final_counts"]["tombstones"] = json!(0);
            }),
            "receipt field tombstones must be 1",
        ),
        (
            "uncompacted tombstone",
            Box::new(|payload| {
                payload["final_counts"]["compacted_tombstones"] = json!(0);
            }),
            "receipt field compacted_tombstones must be 1",
        ),
        (
            "customer residue",
            Box::new(|payload| {
                payload["final_counts"]["residue_counts"]["customer_rows"] = json!(1);
            }),
            "final residue customer_rows must be 0",
        ),
        (
            "missing residue count",
            Box::new(|payload| {
                payload["final_counts"]["residue_counts"]
                    .as_object_mut()
                    .expect("residue counts must be mutable")
                    .remove("active_claims");
            }),
            "receipt field active_claims must be an unsigned integer",
        ),
        (
            "undeclared residue count",
            Box::new(|payload| {
                payload["final_counts"]["residue_counts"]["unexpected_rows"] = json!(0);
            }),
            "final residue counts must contain only declared fields",
        ),
        (
            "missing cleanup state",
            Box::new(|payload| {
                payload["database"]
                    .as_object_mut()
                    .unwrap()
                    .remove("cleanup_state");
            }),
            "database cleanup_state must be nonempty",
        ),
        (
            "skipped command",
            Box::new(|payload| {
                payload["green_commands"][0]["skipped_count"] = json!(1);
            }),
            "command skipped_count must be 0",
        ),
    ];

    for (name, mutate, expected) in mutations {
        let mut mutated = baseline.clone();
        mutate(&mut mutated);
        let error =
            validate_receipt(&mutated, &contract).expect_err("receipt mutation must be rejected");
        assert!(
            error.contains(expected),
            "mutation {name} rejected for wrong reason: {error}"
        );
    }
}

fn contract() -> Value {
    serde_json::from_str(CONTRACT_JSON).expect("contract fixture must parse")
}

fn receipt() -> Value {
    serde_json::from_str(RECEIPT_JSON).expect("receipt fixture must parse")
}

fn validate_receipt(receipt: &Value, contract: &Value) -> Result<(), String> {
    let contract_receipt = object_at(contract, "/privacy_scrub_contract/receipt")?;
    let f10e = object_at(receipt, "/source_pins/f10e")?;
    assert_string_eq(f10e, "pinned_engine_sha", RECEIPT_ENGINE_SHA)?;
    assert_string_eq(
        f10e,
        "validated_head_sha",
        string_from(contract_receipt, "validated_head_sha")?,
    )?;
    assert_string_eq(f10e, "path", string_from(contract_receipt, "path")?)?;

    let expected_classes = strings_at(
        contract,
        "/privacy_scrub_contract/receipt/exact_absence_resource_classes",
    )?;
    let receipt_classes = strings_at(receipt, "/exact_absence_resource_classes")?;
    if receipt_classes != expected_classes {
        return Err(format!(
            "receipt exact absence classes must match contract: {receipt_classes:?} != {expected_classes:?}"
        ));
    }

    let database = object_at(receipt, "/database")?;
    assert_string_eq(database, "connection_locality", "loopback_only")?;
    assert_bool_eq(database, "database_url_recorded", false)?;
    let cleanup_state = database
        .get("cleanup_state")
        .and_then(Value::as_str)
        .unwrap_or("");
    if cleanup_state.trim().is_empty() {
        return Err("database cleanup_state must be nonempty".to_string());
    }

    let scope = object_at(receipt, "/scope")?;
    assert_bool_eq(scope, "f10e_executed_live", false)?;
    assert_bool_eq(scope, "raw_payload_bodies_recorded", false)?;

    let denominators = object_at(receipt, "/seeded_denominators")?;
    assert_u64_eq(denominators, "total_imported_before_erasure", 6)?;
    let per_class = object_at(receipt, "/seeded_denominators/per_class")?;
    let class_absence = object_at(receipt, "/final_counts/exact_absence_class_counts")?;
    for class in &expected_classes {
        let seeded = object_from(per_class, class)?;
        assert_u64_eq(seeded, "expected", 2)?;
        assert_u64_eq(seeded, "imported", 2)?;
        assert_u64_eq(class_absence, class, 0)?;
    }

    validate_final_counts(receipt)?;

    let commands = array_at(receipt, "/green_commands")?;
    if commands.is_empty() {
        return Err("green command evidence must be nonempty".to_string());
    }
    for command in commands {
        let command = command
            .as_object()
            .ok_or_else(|| "green command evidence must be objects".to_string())?;
        if u64_from(command, "passed_count")? == 0 {
            return Err("command passed_count must be nonzero".to_string());
        }
        assert_u64_eq(command, "failed_count", 0)?;
        if u64_from(command, "skipped_count")? != 0 {
            return Err("command skipped_count must be 0".to_string());
        }
    }

    let red_mutations = array_at(receipt, "/red_mutations")?;
    if red_mutations.len() < 5 {
        return Err("red mutation evidence must include every Stage 1 mutation".to_string());
    }
    for mutation in red_mutations {
        let mutation = mutation
            .as_object()
            .ok_or_else(|| "red mutation evidence must be objects".to_string())?;
        assert_u64_eq(mutation, "passed_count", 0)?;
        assert_u64_eq(mutation, "failed_count", 1)?;
        if string_from(mutation, "failure_excerpt")?.trim().is_empty() {
            return Err("red mutation failure excerpt must be nonempty".to_string());
        }
    }

    Ok(())
}

fn validate_final_counts(receipt: &Value) -> Result<(), String> {
    let final_counts = object_at(receipt, "/final_counts")?;
    assert_u64_eq(final_counts, "durable_acks", 1)
        .map_err(|_| "durable ACK count must be exactly 1".to_string())?;
    assert_u64_eq(final_counts, "transmissions", 2)?;
    assert_u64_eq(final_counts, "tombstones", 1)?;
    assert_u64_eq(final_counts, "compacted_tombstones", 1)?;

    let residue = object_at(receipt, "/final_counts/residue_counts")?;
    const REQUIRED_ZERO_RESIDUE_COUNTS: [&str; 7] = [
        "customer_rows",
        "non_null_erasure_handles",
        "active_reservations",
        "handle_mappings",
        "active_claims",
        "vm_retirement_blockers",
        "uncompacted_scrub_handles",
    ];
    for name in REQUIRED_ZERO_RESIDUE_COUNTS {
        let value = u64_from(residue, name)?;
        if value != 0 {
            return Err(format!("final residue {name} must be 0"));
        }
    }
    if residue.len() != REQUIRED_ZERO_RESIDUE_COUNTS.len() {
        return Err("final residue counts must contain only declared fields".to_string());
    }
    Ok(())
}

fn object_at<'a>(value: &'a Value, pointer: &str) -> Result<&'a Map<String, Value>, String> {
    value
        .pointer(pointer)
        .and_then(Value::as_object)
        .ok_or_else(|| format!("receipt path {pointer} must be an object"))
}

fn object_from<'a>(
    object: &'a Map<String, Value>,
    key: &str,
) -> Result<&'a Map<String, Value>, String> {
    object
        .get(key)
        .and_then(Value::as_object)
        .ok_or_else(|| format!("receipt field {key} must be an object"))
}

fn array_at<'a>(value: &'a Value, pointer: &str) -> Result<&'a Vec<Value>, String> {
    value
        .pointer(pointer)
        .and_then(Value::as_array)
        .ok_or_else(|| format!("receipt path {pointer} must be an array"))
}

fn strings_at(value: &Value, pointer: &str) -> Result<Vec<String>, String> {
    value
        .pointer(pointer)
        .and_then(Value::as_array)
        .ok_or_else(|| format!("receipt path {pointer} must be an array"))?
        .iter()
        .map(|item| {
            item.as_str()
                .map(str::to_string)
                .ok_or_else(|| format!("receipt path {pointer} must contain only strings"))
        })
        .collect()
}

fn string_from<'a>(object: &'a Map<String, Value>, key: &str) -> Result<&'a str, String> {
    object
        .get(key)
        .and_then(Value::as_str)
        .ok_or_else(|| format!("receipt field {key} must be a string"))
}

fn u64_from(object: &Map<String, Value>, key: &str) -> Result<u64, String> {
    object
        .get(key)
        .and_then(Value::as_u64)
        .ok_or_else(|| format!("receipt field {key} must be an unsigned integer"))
}

fn assert_string_eq(object: &Map<String, Value>, key: &str, expected: &str) -> Result<(), String> {
    let actual = string_from(object, key)?;
    if actual != expected {
        return Err(format!(
            "receipt field {key} must be {expected}, got {actual}"
        ));
    }
    Ok(())
}

fn assert_bool_eq(object: &Map<String, Value>, key: &str, expected: bool) -> Result<(), String> {
    let actual = object
        .get(key)
        .and_then(Value::as_bool)
        .ok_or_else(|| format!("receipt field {key} must be a bool"))?;
    if actual != expected {
        return Err(format!(
            "receipt field {key} must be {expected}, got {actual}"
        ));
    }
    Ok(())
}

fn assert_u64_eq(object: &Map<String, Value>, key: &str, expected: u64) -> Result<(), String> {
    let actual = u64_from(object, key)?;
    if actual != expected {
        return Err(format!(
            "receipt field {key} must be {expected}, got {actual}"
        ));
    }
    Ok(())
}
