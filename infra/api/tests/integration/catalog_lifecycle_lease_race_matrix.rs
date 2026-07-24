use super::*;

#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd)]
enum RaceMatrixOwnerFamily {
    ImportReservationFinalizationVersusDelete,
    CreateSharedVmRoute,
    AdminSeedCreate,
    ColdTransitionRollback,
    Restore,
    MigrationBeginFinalizeRollbackRecovery,
    ReplicaCreateRemove,
    RegionFailover,
}

#[derive(Clone, Copy)]
struct RaceMatrixScenario {
    owner_family: RaceMatrixOwnerFamily,
    ordering_coverage: &'static str,
    focused_selection: &'static str,
    expired_claim_selection: &'static str,
    registration: CoverageRegistration,
}

#[derive(Debug, Default, PartialEq, Eq)]
struct RaceMatrixDenominatorValidation {
    missing_owner_families: BTreeSet<RaceMatrixOwnerFamily>,
    duplicate_canonical_writers: BTreeSet<String>,
    skipped_blocking_writers: BTreeSet<String>,
    wrong_owner_families: BTreeSet<String>,
    noncanonical_ordering_coverage: BTreeSet<String>,
    noncanonical_focused_selections: BTreeSet<String>,
    unexpected_writers: BTreeSet<String>,
    privacy_transition_writers: BTreeSet<String>,
    empty_focused_selections: BTreeSet<String>,
    duplicate_focused_selections: BTreeSet<String>,
    empty_expired_claim_selections: BTreeSet<String>,
    noncanonical_expired_claim_selections: BTreeSet<String>,
    duplicate_expired_claim_selections: BTreeSet<String>,
}

#[derive(Debug, Default, PartialEq, Eq)]
struct ExpiredClaimMatrixValidation {
    missing_state_family_cells: BTreeSet<String>,
    duplicate_state_family_cells: BTreeSet<String>,
    unexpected_state_family_cells: BTreeSet<String>,
}

const DENOMINATOR_SELECTION: &str = concat!(
    "catalog_lifecycle_leases::catalog_lifecycle_lease_remote_races::",
    "race_matrix_denominator_matches_blocking_inventory_once"
);
const CREATE_ROUTE_SELECTION: &str = concat!(
    "catalog_lifecycle_leases::catalog_lifecycle_lease_remote_races::",
    "create_index_on_shared_vm_reservation_races_after_intent_before_remote_work"
);
const DELETE_ROUTE_SELECTION: &str = concat!(
    "catalog_lifecycle_leases::catalog_lifecycle_lease_remote_races::",
    "delete_index_reservation_races_after_intent_before_finalization"
);
const COLD_TIER_SELECTION: &str = concat!(
    "catalog_lifecycle_leases::catalog_lifecycle_lease_remote_races::",
    "cold_tier_intent_blocks_replace_reservation_before_remote_export"
);
const ADMIN_SEED_SELECTION: &str = concat!(
    "catalog_lifecycle_leases::catalog_lifecycle_lease_remote_races::",
    "admin_seed_create_races_after_intent_before_remote_secret_work"
);
const MIGRATION_SELECTION: &str = concat!(
    "catalog_lifecycle_leases::catalog_lifecycle_lease_remote_races::",
    "migration_lifecycle_races_after_intent_before_remote_work"
);
const REPLICA_SELECTION: &str = concat!(
    "catalog_lifecycle_leases::catalog_lifecycle_lease_remote_races::",
    "replica_create_remove_races_after_intent_before_remote_work"
);
const RESTORE_SELECTION: &str = concat!(
    "catalog_lifecycle_leases::catalog_lifecycle_lease_remote_races::",
    "restore_lifecycle_races_after_intent_before_remote_work"
);
const REGION_FAILOVER_SELECTION: &str = concat!(
    "catalog_lifecycle_leases::catalog_lifecycle_lease_remote_races::",
    "region_failover_races_after_intent_before_remote_work"
);
const EXPIRED_CREATE_ROUTE_SELECTION: &str =
    "catalog_lifecycle_leases::expired_worker_lease_blocks_create_shared_vm_route_family";
const EXPIRED_DELETE_ROUTE_SELECTION: &str =
    "catalog_lifecycle_leases::expired_worker_lease_blocks_import_finalization_delete_family";
const EXPIRED_ADMIN_SEED_SELECTION: &str =
    "catalog_lifecycle_leases::expired_worker_lease_blocks_admin_seed_create_family";
const EXPIRED_COLD_TIER_SELECTION: &str =
    "catalog_lifecycle_leases::expired_worker_lease_blocks_cold_transition_rollback_family";
const EXPIRED_RESTORE_SELECTION: &str =
    "catalog_lifecycle_leases::expired_worker_lease_blocks_restore_family";
const EXPIRED_MIGRATION_SELECTION: &str =
    "catalog_lifecycle_leases::expired_worker_lease_blocks_migration_begin_rollback_family";
const EXPIRED_REPLICA_SELECTION: &str =
    "catalog_lifecycle_leases::expired_worker_lease_blocks_replica_create_remove_family";
const EXPIRED_REGION_FAILOVER_SELECTION: &str =
    "catalog_lifecycle_leases::expired_worker_lease_blocks_region_failover_family";

pub(super) fn assert_denominator_matches_blocking_inventory_once() {
    assert!(
        !DENOMINATOR_SELECTION.trim().is_empty(),
        "Stage 1 denominator selection must be named"
    );
    let inventory = inventory_by_key();
    let expected_ids = blocking_inventory_ids();
    let scenarios = race_matrix_scenarios();

    assert_eq!(
        validate_race_matrix_scenarios(&scenarios, &expected_ids, &inventory),
        RaceMatrixDenominatorValidation::default(),
        "race matrix denominator must classify every block_without_change writer exactly once"
    );
}

pub(super) fn assert_expired_claim_matrix_covers_retained_states_once() {
    let inventory = inventory_by_key();
    let expected_ids = blocking_inventory_ids();
    let scenarios = race_matrix_scenarios();
    assert_eq!(
        validate_race_matrix_scenarios(&scenarios, &expected_ids, &inventory),
        RaceMatrixDenominatorValidation::default(),
        "race matrix metadata must remain canonical before deriving expired-claim coverage"
    );
    let retained_labels = retained_reservation_case_labels();
    let expected_cells = expected_expired_claim_cells(&retained_labels);
    let observed_cells = expired_claim_cells_from_scenarios(&scenarios, &retained_labels);
    assert_eq!(
        validate_expired_claim_cells(&observed_cells, &expected_cells),
        ExpiredClaimMatrixValidation::default(),
        "expired-claim matrix must cover every retained state once per owner family"
    );
}

#[test]
fn race_matrix_denominator_validator_rejects_bad_metadata() {
    let inventory = inventory_by_key();
    let expected_ids = blocking_inventory_ids();
    let scenarios = race_matrix_scenarios();
    let first_id = registration_id(&scenarios[0].registration);

    let mut missing_family = scenarios.clone();
    let region_scenario = missing_family
        .iter_mut()
        .find(|scenario| scenario.owner_family == RaceMatrixOwnerFamily::RegionFailover)
        .expect("green metadata includes region failover");
    let region_id = registration_id(&region_scenario.registration);
    region_scenario.owner_family = RaceMatrixOwnerFamily::Restore;
    let mut expected_missing_family = RaceMatrixDenominatorValidation::default();
    expected_missing_family
        .missing_owner_families
        .insert(RaceMatrixOwnerFamily::RegionFailover);
    expected_missing_family
        .wrong_owner_families
        .insert(region_id.clone());
    expected_missing_family
        .noncanonical_ordering_coverage
        .insert(region_id.clone());
    expected_missing_family
        .noncanonical_focused_selections
        .insert(region_id.clone());
    expected_missing_family
        .noncanonical_expired_claim_selections
        .insert(region_id);
    assert_eq!(
        validate_race_matrix_scenarios(&missing_family, &expected_ids, &inventory),
        expected_missing_family,
        "missing owner family must be classified exactly"
    );

    let mut wrong_family = scenarios.clone();
    let wrong_family_scenario = wrong_family
        .iter_mut()
        .find(|scenario| scenario.owner_family == RaceMatrixOwnerFamily::CreateSharedVmRoute)
        .expect("green metadata includes create/shared-VM route");
    let wrong_family_id = registration_id(&wrong_family_scenario.registration);
    wrong_family_scenario.owner_family = RaceMatrixOwnerFamily::ColdTransitionRollback;
    let mut expected_wrong_family = RaceMatrixDenominatorValidation::default();
    expected_wrong_family
        .wrong_owner_families
        .insert(wrong_family_id.clone());
    expected_wrong_family
        .noncanonical_ordering_coverage
        .insert(wrong_family_id.clone());
    expected_wrong_family
        .noncanonical_focused_selections
        .insert(wrong_family_id.clone());
    expected_wrong_family
        .noncanonical_expired_claim_selections
        .insert(wrong_family_id);
    assert_eq!(
        validate_race_matrix_scenarios(&wrong_family, &expected_ids, &inventory),
        expected_wrong_family,
        "wrong owner family must be classified exactly"
    );

    let mut duplicate = scenarios.clone();
    duplicate.push(scenarios[0]);
    let mut expected_duplicate = RaceMatrixDenominatorValidation::default();
    expected_duplicate
        .duplicate_canonical_writers
        .insert(first_id.clone());
    assert_eq!(
        validate_race_matrix_scenarios(&duplicate, &expected_ids, &inventory),
        expected_duplicate,
        "duplicate canonical writer must be classified exactly"
    );

    let mut skipped = scenarios.clone();
    skipped.remove(0);
    let mut expected_skipped = RaceMatrixDenominatorValidation::default();
    expected_skipped
        .skipped_blocking_writers
        .insert(first_id.clone());
    assert_eq!(
        validate_race_matrix_scenarios(&skipped, &expected_ids, &inventory),
        expected_skipped,
        "skipped blocking writer must be classified exactly"
    );

    let unknown_registration = CoverageRegistration {
        scenario: "race_matrix_unknown_writer_negative_case",
        owner_path: "infra/api/src/services/restore.rs",
        function_name: "unknown_lifecycle_writer",
        source_anchor: "tenant_repo.set_tier",
    };
    let mut unknown = scenarios.clone();
    unknown[0].registration = unknown_registration;
    let mut expected_unknown = RaceMatrixDenominatorValidation::default();
    expected_unknown
        .skipped_blocking_writers
        .insert(first_id.clone());
    expected_unknown
        .unexpected_writers
        .insert(registration_id(&unknown_registration));
    assert_eq!(
        validate_race_matrix_scenarios(&unknown, &expected_ids, &inventory),
        expected_unknown,
        "unexpected writer must be classified exactly"
    );

    let privacy_registration = CoverageRegistration {
        scenario: "race_matrix_privacy_writer_negative_case",
        owner_path: "infra/api/src/routes/account.rs",
        function_name: "delete_account",
        source_anchor: "customer_repo.soft_delete",
    };
    let mut privacy = scenarios.clone();
    privacy[0].registration = privacy_registration;
    let mut expected_privacy = RaceMatrixDenominatorValidation::default();
    expected_privacy
        .skipped_blocking_writers
        .insert(first_id.clone());
    expected_privacy
        .privacy_transition_writers
        .insert(registration_id(&privacy_registration));
    assert_eq!(
        validate_race_matrix_scenarios(&privacy, &expected_ids, &inventory),
        expected_privacy,
        "privacy-transition writer inclusion must be classified exactly"
    );

    let mut empty_selection = scenarios.clone();
    empty_selection[0].focused_selection = "";
    let mut expected_empty_selection = RaceMatrixDenominatorValidation::default();
    expected_empty_selection
        .empty_focused_selections
        .insert(first_id);
    assert_eq!(
        validate_race_matrix_scenarios(&empty_selection, &expected_ids, &inventory),
        expected_empty_selection,
        "empty focused-selection name must be classified exactly"
    );

    let mut wrong_ordering = scenarios.clone();
    let wrong_ordering_scenario = wrong_ordering
        .iter_mut()
        .find(|scenario| scenario.owner_family == RaceMatrixOwnerFamily::Restore)
        .expect("green metadata includes restore");
    let wrong_ordering_id = registration_id(&wrong_ordering_scenario.registration);
    wrong_ordering_scenario.ordering_coverage = "noncanonical restore ordering coverage";
    let mut expected_wrong_ordering = RaceMatrixDenominatorValidation::default();
    expected_wrong_ordering
        .noncanonical_ordering_coverage
        .insert(wrong_ordering_id);
    assert_eq!(
        validate_race_matrix_scenarios(&wrong_ordering, &expected_ids, &inventory),
        expected_wrong_ordering,
        "noncanonical ordering coverage must be classified exactly"
    );

    let mut wrong_focused_selection = scenarios.clone();
    let wrong_focused_scenario = wrong_focused_selection
        .iter_mut()
        .find(|scenario| scenario.owner_family == RaceMatrixOwnerFamily::Restore)
        .expect("green metadata includes restore");
    let wrong_focused_id = registration_id(&wrong_focused_scenario.registration);
    wrong_focused_scenario.focused_selection = "catalog_lifecycle_leases::not_a_canonical_filter";
    let mut expected_wrong_focused = RaceMatrixDenominatorValidation::default();
    expected_wrong_focused
        .noncanonical_focused_selections
        .insert(wrong_focused_id);
    assert_eq!(
        validate_race_matrix_scenarios(&wrong_focused_selection, &expected_ids, &inventory),
        expected_wrong_focused,
        "noncanonical focused selection must be classified exactly"
    );

    let mut aliased_selection = scenarios.clone();
    let aliased_scenario = aliased_selection
        .iter_mut()
        .find(|scenario| scenario.owner_family == RaceMatrixOwnerFamily::CreateSharedVmRoute)
        .expect("green metadata includes create/shared-VM route");
    aliased_scenario.focused_selection = DELETE_ROUTE_SELECTION;
    let mut expected_aliased_selection = RaceMatrixDenominatorValidation::default();
    expected_aliased_selection
        .noncanonical_focused_selections
        .insert(registration_id(&aliased_scenario.registration));
    expected_aliased_selection
        .duplicate_focused_selections
        .insert(DELETE_ROUTE_SELECTION.to_string());
    assert_eq!(
        validate_race_matrix_scenarios(&aliased_selection, &expected_ids, &inventory),
        expected_aliased_selection,
        "focused selection aliased across owner families must be classified exactly"
    );
}

#[test]
fn expired_claim_matrix_validator_rejects_missing_duplicate_and_unclassified_cells() {
    let inventory = inventory_by_key();
    let expected_ids = blocking_inventory_ids();
    let scenarios = race_matrix_scenarios();
    let retained_labels = retained_reservation_case_labels();
    let expected_cells = expected_expired_claim_cells(&retained_labels);
    let cells = expired_claim_cells_from_scenarios(&scenarios, &retained_labels);
    let first_cell = cells[0].clone();

    let mut missing = cells.clone();
    missing.remove(0);
    let mut expected_missing = ExpiredClaimMatrixValidation::default();
    expected_missing
        .missing_state_family_cells
        .insert(first_cell.clone());
    assert_eq!(
        validate_expired_claim_cells(&missing, &expected_cells),
        expected_missing,
        "missing expired-claim state/family cell must be classified exactly"
    );

    let mut duplicate = cells.clone();
    duplicate.push(first_cell.clone());
    let mut expected_duplicate = ExpiredClaimMatrixValidation::default();
    expected_duplicate
        .duplicate_state_family_cells
        .insert(first_cell.clone());
    assert_eq!(
        validate_expired_claim_cells(&duplicate, &expected_cells),
        expected_duplicate,
        "duplicate expired-claim state/family cell must be classified exactly"
    );

    let mut unexpected = cells.clone();
    unexpected[0] = "UnknownFamily::queued__unknown__pending__resumable_false".to_string();
    let mut expected_unexpected = ExpiredClaimMatrixValidation::default();
    expected_unexpected
        .missing_state_family_cells
        .insert(first_cell);
    expected_unexpected
        .unexpected_state_family_cells
        .insert("UnknownFamily::queued__unknown__pending__resumable_false".to_string());
    assert_eq!(
        validate_expired_claim_cells(&unexpected, &expected_cells),
        expected_unexpected,
        "unclassified expired-claim state/family cell must be classified exactly"
    );

    let first_id = registration_id(&scenarios[0].registration);
    let mut empty_selection = scenarios.clone();
    empty_selection[0].expired_claim_selection = "";
    let mut expected_empty_selection = RaceMatrixDenominatorValidation::default();
    expected_empty_selection
        .empty_expired_claim_selections
        .insert(first_id.clone());
    assert_eq!(
        validate_race_matrix_scenarios(&empty_selection, &expected_ids, &inventory),
        expected_empty_selection,
        "empty expired-claim family selection must be classified exactly"
    );

    let mut aliased_selection = scenarios.clone();
    let aliased_scenario = aliased_selection
        .iter_mut()
        .find(|scenario| scenario.owner_family == RaceMatrixOwnerFamily::CreateSharedVmRoute)
        .expect("green metadata includes create/shared-VM route");
    aliased_scenario.expired_claim_selection = EXPIRED_DELETE_ROUTE_SELECTION;
    let mut expected_aliased_selection = RaceMatrixDenominatorValidation::default();
    expected_aliased_selection
        .noncanonical_expired_claim_selections
        .insert(registration_id(&aliased_scenario.registration));
    expected_aliased_selection
        .duplicate_expired_claim_selections
        .insert(EXPIRED_DELETE_ROUTE_SELECTION.to_string());
    assert_eq!(
        validate_race_matrix_scenarios(&aliased_selection, &expected_ids, &inventory),
        expected_aliased_selection,
        "aliased expired-claim family selection must be classified exactly"
    );

    let mut skipped_writer = scenarios.clone();
    let skipped_id = registration_id(&skipped_writer.remove(0).registration);
    let mut expected_skipped_writer = RaceMatrixDenominatorValidation::default();
    expected_skipped_writer
        .skipped_blocking_writers
        .insert(skipped_id);
    assert_eq!(
        validate_race_matrix_scenarios(&skipped_writer, &expected_ids, &inventory),
        expected_skipped_writer,
        "skipped blocking writer must remain classified by the race-matrix validator"
    );

    let mut duplicate_writer = scenarios.clone();
    duplicate_writer.push(scenarios[0]);
    let mut expected_duplicate_writer = RaceMatrixDenominatorValidation::default();
    expected_duplicate_writer
        .duplicate_canonical_writers
        .insert(registration_id(&scenarios[0].registration));
    assert_eq!(
        validate_race_matrix_scenarios(&duplicate_writer, &expected_ids, &inventory),
        expected_duplicate_writer,
        "duplicate blocking writer must remain classified by the race-matrix validator"
    );

    let unknown_registration = CoverageRegistration {
        scenario: "expired_claim_unknown_writer_negative_case",
        owner_path: "infra/api/src/services/restore.rs",
        function_name: "unknown_lifecycle_writer",
        source_anchor: "tenant_repo.set_tier",
    };
    let mut unknown_writer = scenarios.clone();
    let replaced_id = registration_id(&unknown_writer[0].registration);
    unknown_writer[0].registration = unknown_registration;
    let mut expected_unknown_writer = RaceMatrixDenominatorValidation::default();
    expected_unknown_writer
        .skipped_blocking_writers
        .insert(replaced_id);
    expected_unknown_writer
        .unexpected_writers
        .insert(registration_id(&unknown_registration));
    assert_eq!(
        validate_race_matrix_scenarios(&unknown_writer, &expected_ids, &inventory),
        expected_unknown_writer,
        "unknown writer must remain classified by the race-matrix validator"
    );

    let privacy_registration = CoverageRegistration {
        scenario: "expired_claim_privacy_writer_negative_case",
        owner_path: "infra/api/src/routes/account.rs",
        function_name: "delete_account",
        source_anchor: "customer_repo.soft_delete",
    };
    let mut privacy_writer = scenarios.clone();
    let replaced_id = registration_id(&privacy_writer[0].registration);
    privacy_writer[0].registration = privacy_registration;
    let mut expected_privacy_writer = RaceMatrixDenominatorValidation::default();
    expected_privacy_writer
        .skipped_blocking_writers
        .insert(replaced_id);
    expected_privacy_writer
        .privacy_transition_writers
        .insert(registration_id(&privacy_registration));
    assert_eq!(
        validate_race_matrix_scenarios(&privacy_writer, &expected_ids, &inventory),
        expected_privacy_writer,
        "privacy-transition writer must remain classified by the race-matrix validator"
    );
}

#[test]
fn extra_race_matrix_registrations_use_canonical_scenario_metadata() {
    for registration in extra_race_matrix_coverage_registrations() {
        let scenario = race_matrix_scenario(*registration);
        let owner_family = race_matrix_owner_family(registration);
        assert_eq!(
            scenario.owner_family, owner_family,
            "extra race matrix registration must use canonical owner-family classification"
        );
        assert_eq!(
            scenario.ordering_coverage,
            race_matrix_ordering_coverage(owner_family),
            "extra race matrix registration must use canonical ordering coverage"
        );
        assert_eq!(
            scenario.focused_selection,
            race_matrix_focused_selection(owner_family),
            "extra race matrix registration must use canonical focused selection"
        );
    }
}

fn blocking_inventory_ids() -> BTreeSet<String> {
    blocking_inventory_by_key()
        .values()
        .map(|writer| writer.id.clone())
        .collect()
}

fn race_matrix_scenarios() -> Vec<RaceMatrixScenario> {
    let inventory = inventory_by_key();
    route_owner_coverage_registrations(&inventory)
        .into_iter()
        .chain(service_owner_coverage_registrations(&inventory))
        .chain(extra_race_matrix_coverage_registrations().iter().copied())
        .map(race_matrix_scenario)
        .collect()
}

fn race_matrix_scenario(registration: CoverageRegistration) -> RaceMatrixScenario {
    let owner_family = race_matrix_owner_family(&registration);
    RaceMatrixScenario {
        owner_family,
        ordering_coverage: race_matrix_ordering_coverage(owner_family),
        focused_selection: race_matrix_focused_selection(owner_family),
        expired_claim_selection: race_matrix_expired_claim_selection(owner_family),
        registration,
    }
}

fn validate_race_matrix_scenarios(
    scenarios: &[RaceMatrixScenario],
    expected_ids: &BTreeSet<String>,
    inventory: &BTreeMap<(String, String), CatalogLifecycleWriter>,
) -> RaceMatrixDenominatorValidation {
    let registrations = scenarios
        .iter()
        .map(|scenario| scenario.registration)
        .collect::<Vec<_>>();
    let coverage = validate_coverage_registrations(&registrations, expected_ids, inventory);
    let present_families = scenarios
        .iter()
        .map(|scenario| scenario.owner_family)
        .collect::<BTreeSet<_>>();
    RaceMatrixDenominatorValidation {
        missing_owner_families: required_race_matrix_owner_families()
            .difference(&present_families)
            .copied()
            .collect(),
        duplicate_canonical_writers: coverage.duplicates,
        skipped_blocking_writers: coverage.missing,
        wrong_owner_families: scenarios
            .iter()
            .filter_map(|scenario| {
                let id = registration_id(&scenario.registration);
                if expected_ids.contains(&id)
                    && scenario.owner_family != race_matrix_owner_family(&scenario.registration)
                {
                    Some(id)
                } else {
                    None
                }
            })
            .collect(),
        noncanonical_ordering_coverage: scenarios
            .iter()
            .filter(|scenario| {
                !scenario.ordering_coverage.trim().is_empty()
                    && scenario.ordering_coverage
                        != race_matrix_ordering_coverage(scenario.owner_family)
            })
            .map(|scenario| registration_id(&scenario.registration))
            .collect(),
        noncanonical_focused_selections: scenarios
            .iter()
            .filter(|scenario| {
                !scenario.focused_selection.trim().is_empty()
                    && scenario.focused_selection
                        != race_matrix_focused_selection(scenario.owner_family)
            })
            .map(|scenario| registration_id(&scenario.registration))
            .collect(),
        unexpected_writers: coverage.unknown.union(&coverage.extra).cloned().collect(),
        privacy_transition_writers: coverage.wrong_disposition,
        empty_focused_selections: scenarios
            .iter()
            .filter(|scenario| {
                scenario.focused_selection.trim().is_empty()
                    || scenario.ordering_coverage.trim().is_empty()
            })
            .map(|scenario| registration_id(&scenario.registration))
            .collect(),
        duplicate_focused_selections: duplicate_focused_selections(scenarios),
        empty_expired_claim_selections: scenarios
            .iter()
            .filter(|scenario| scenario.expired_claim_selection.trim().is_empty())
            .map(|scenario| registration_id(&scenario.registration))
            .collect(),
        noncanonical_expired_claim_selections: scenarios
            .iter()
            .filter(|scenario| {
                !scenario.expired_claim_selection.trim().is_empty()
                    && scenario.expired_claim_selection
                        != race_matrix_expired_claim_selection(scenario.owner_family)
            })
            .map(|scenario| registration_id(&scenario.registration))
            .collect(),
        duplicate_expired_claim_selections: duplicate_expired_claim_selections(scenarios),
    }
}

/// A focused `cargo test` selection must belong to exactly one owner family; if
/// two families point at the same selection they silently alias distinct owner
/// races onto one test target, collapsing the one-selection-per-family contract.
///
/// Only well-formed scenarios — whose declared `owner_family` matches the
/// canonical classification of their registration — participate. Mislabeled or
/// unrecognized registrations are already reported via `wrong_owner_families`
/// and `unexpected_writers`, so excluding them keeps this signal a pure
/// cross-family aliasing report rather than a duplicate of those diagnostics.
fn duplicate_focused_selections(scenarios: &[RaceMatrixScenario]) -> BTreeSet<String> {
    duplicate_family_selections(scenarios, |scenario| scenario.focused_selection)
}

fn duplicate_expired_claim_selections(scenarios: &[RaceMatrixScenario]) -> BTreeSet<String> {
    duplicate_family_selections(scenarios, |scenario| scenario.expired_claim_selection)
}

fn duplicate_family_selections(
    scenarios: &[RaceMatrixScenario],
    selection: fn(&RaceMatrixScenario) -> &'static str,
) -> BTreeSet<String> {
    let mut families_by_selection: BTreeMap<&str, BTreeSet<RaceMatrixOwnerFamily>> =
        BTreeMap::new();
    for scenario in scenarios {
        let selection = selection(scenario);
        if selection.trim().is_empty() {
            continue;
        }
        if scenario.owner_family != race_matrix_owner_family(&scenario.registration) {
            continue;
        }
        families_by_selection
            .entry(selection)
            .or_default()
            .insert(scenario.owner_family);
    }
    families_by_selection
        .into_iter()
        .filter(|(_, families)| families.len() > 1)
        .map(|(selection, _)| selection.to_string())
        .collect()
}

fn required_race_matrix_owner_families() -> BTreeSet<RaceMatrixOwnerFamily> {
    BTreeSet::from([
        RaceMatrixOwnerFamily::ImportReservationFinalizationVersusDelete,
        RaceMatrixOwnerFamily::CreateSharedVmRoute,
        RaceMatrixOwnerFamily::AdminSeedCreate,
        RaceMatrixOwnerFamily::ColdTransitionRollback,
        RaceMatrixOwnerFamily::Restore,
        RaceMatrixOwnerFamily::MigrationBeginFinalizeRollbackRecovery,
        RaceMatrixOwnerFamily::ReplicaCreateRemove,
        RaceMatrixOwnerFamily::RegionFailover,
    ])
}

fn race_matrix_owner_family(registration: &CoverageRegistration) -> RaceMatrixOwnerFamily {
    if registration.owner_path.contains("/admin/indexes.rs") {
        return RaceMatrixOwnerFamily::AdminSeedCreate;
    }
    if registration.owner_path.contains("/cold_tier/") {
        return RaceMatrixOwnerFamily::ColdTransitionRollback;
    }
    if registration.owner_path.contains("/migration/") {
        return RaceMatrixOwnerFamily::MigrationBeginFinalizeRollbackRecovery;
    }
    if registration.owner_path.ends_with("/restore.rs") {
        return RaceMatrixOwnerFamily::Restore;
    }
    if registration.owner_path.ends_with("/replica.rs")
        || registration
            .owner_path
            .ends_with("/pg_index_replica_repo.rs")
        || registration.source_anchor.starts_with("replica_service.")
    {
        return RaceMatrixOwnerFamily::ReplicaCreateRemove;
    }
    if registration.owner_path.ends_with("/region_failover.rs") {
        return RaceMatrixOwnerFamily::RegionFailover;
    }
    match registration.function_name {
        "delete"
        | "delete_index"
        | "publish_delete_lifecycle_intent"
        | "rollback_shared_vm_delete_intent" => {
            RaceMatrixOwnerFamily::ImportReservationFinalizationVersusDelete
        }
        "clear_vm_id" | "set_cold_snapshot_id" | "set_tier" => {
            RaceMatrixOwnerFamily::ColdTransitionRollback
        }
        _ => RaceMatrixOwnerFamily::CreateSharedVmRoute,
    }
}

fn race_matrix_ordering_coverage(owner_family: RaceMatrixOwnerFamily) -> &'static str {
    match owner_family {
        RaceMatrixOwnerFamily::ImportReservationFinalizationVersusDelete => {
            "delete intent before import reservation/finalization"
        }
        RaceMatrixOwnerFamily::CreateSharedVmRoute => "create/shared-VM intent before remote work",
        RaceMatrixOwnerFamily::AdminSeedCreate => "admin seed/create intent before remote work",
        RaceMatrixOwnerFamily::ColdTransitionRollback => {
            "cold transition/rollback intent before remote export"
        }
        RaceMatrixOwnerFamily::Restore => "restore intent before remote import",
        RaceMatrixOwnerFamily::MigrationBeginFinalizeRollbackRecovery => {
            "migration begin/finalize/rollback/recovery intent before remote work"
        }
        RaceMatrixOwnerFamily::ReplicaCreateRemove => {
            "replica create/remove intent before remote work"
        }
        RaceMatrixOwnerFamily::RegionFailover => "region failover intent before remote work",
    }
}

fn race_matrix_focused_selection(owner_family: RaceMatrixOwnerFamily) -> &'static str {
    match owner_family {
        RaceMatrixOwnerFamily::ImportReservationFinalizationVersusDelete => DELETE_ROUTE_SELECTION,
        RaceMatrixOwnerFamily::CreateSharedVmRoute => CREATE_ROUTE_SELECTION,
        RaceMatrixOwnerFamily::AdminSeedCreate => ADMIN_SEED_SELECTION,
        RaceMatrixOwnerFamily::ColdTransitionRollback => COLD_TIER_SELECTION,
        RaceMatrixOwnerFamily::Restore => RESTORE_SELECTION,
        RaceMatrixOwnerFamily::MigrationBeginFinalizeRollbackRecovery => MIGRATION_SELECTION,
        RaceMatrixOwnerFamily::ReplicaCreateRemove => REPLICA_SELECTION,
        RaceMatrixOwnerFamily::RegionFailover => REGION_FAILOVER_SELECTION,
    }
}

fn race_matrix_expired_claim_selection(owner_family: RaceMatrixOwnerFamily) -> &'static str {
    match owner_family {
        RaceMatrixOwnerFamily::ImportReservationFinalizationVersusDelete => {
            EXPIRED_DELETE_ROUTE_SELECTION
        }
        RaceMatrixOwnerFamily::CreateSharedVmRoute => EXPIRED_CREATE_ROUTE_SELECTION,
        RaceMatrixOwnerFamily::AdminSeedCreate => EXPIRED_ADMIN_SEED_SELECTION,
        RaceMatrixOwnerFamily::ColdTransitionRollback => EXPIRED_COLD_TIER_SELECTION,
        RaceMatrixOwnerFamily::Restore => EXPIRED_RESTORE_SELECTION,
        RaceMatrixOwnerFamily::MigrationBeginFinalizeRollbackRecovery => {
            EXPIRED_MIGRATION_SELECTION
        }
        RaceMatrixOwnerFamily::ReplicaCreateRemove => EXPIRED_REPLICA_SELECTION,
        RaceMatrixOwnerFamily::RegionFailover => EXPIRED_REGION_FAILOVER_SELECTION,
    }
}

fn retained_reservation_case_labels() -> BTreeSet<String> {
    reservation_lifetime_denominator()
        .into_iter()
        .filter(|case| case.expectation == ReservationExpectation::Retain)
        .map(|case| case.label)
        .collect()
}

fn expired_claim_cells_from_scenarios(
    scenarios: &[RaceMatrixScenario],
    retained_labels: &BTreeSet<String>,
) -> Vec<String> {
    let families = scenarios
        .iter()
        .filter(|scenario| {
            scenario.owner_family == race_matrix_owner_family(&scenario.registration)
                && !scenario.expired_claim_selection.trim().is_empty()
        })
        .map(|scenario| scenario.owner_family)
        .collect::<BTreeSet<_>>();
    families
        .iter()
        .flat_map(|family| {
            retained_labels
                .iter()
                .map(move |label| expired_claim_cell(*family, label))
        })
        .collect()
}

fn expected_expired_claim_cells(retained_labels: &BTreeSet<String>) -> BTreeSet<String> {
    required_race_matrix_owner_families()
        .iter()
        .flat_map(|family| {
            retained_labels
                .iter()
                .map(move |label| expired_claim_cell(*family, label))
        })
        .collect()
}

fn expired_claim_cell(owner_family: RaceMatrixOwnerFamily, retained_label: &str) -> String {
    format!("{owner_family:?}::{retained_label}")
}

fn validate_expired_claim_cells(
    cells: &[String],
    expected_cells: &BTreeSet<String>,
) -> ExpiredClaimMatrixValidation {
    let mut seen = BTreeSet::new();
    let mut duplicates = BTreeSet::new();
    for cell in cells {
        if !seen.insert(cell.clone()) {
            duplicates.insert(cell.clone());
        }
    }
    ExpiredClaimMatrixValidation {
        missing_state_family_cells: expected_cells.difference(&seen).cloned().collect(),
        duplicate_state_family_cells: duplicates,
        unexpected_state_family_cells: seen.difference(expected_cells).cloned().collect(),
    }
}

fn extra_race_matrix_coverage_registrations() -> &'static [CoverageRegistration] {
    EXTRA_RACE_MATRIX_COVERAGE
}

const EXTRA_RACE_MATRIX_COVERAGE: &[CoverageRegistration] = &[
    CoverageRegistration {
        scenario: "race_matrix_denominator_metadata",
        owner_path: "infra/api/src/repos/pg_index_replica_repo.rs",
        function_name: "create",
        source_anchor: "pg_index_replica_repo.create",
    },
    CoverageRegistration {
        scenario: "race_matrix_denominator_metadata",
        owner_path: "infra/api/src/repos/pg_index_replica_repo.rs",
        function_name: "delete",
        source_anchor: "pg_index_replica_repo.delete",
    },
    CoverageRegistration {
        scenario: "race_matrix_denominator_metadata",
        owner_path: "infra/api/src/repos/pg_tenant_repo.rs",
        function_name: "clear_vm_id",
        source_anchor: "pg_tenant_repo.clear_vm_id",
    },
    CoverageRegistration {
        scenario: "race_matrix_denominator_metadata",
        owner_path: "infra/api/src/repos/pg_tenant_repo.rs",
        function_name: "set_cold_snapshot_id",
        source_anchor: "pg_tenant_repo.set_cold_snapshot_id",
    },
    CoverageRegistration {
        scenario: "race_matrix_denominator_metadata",
        owner_path: "infra/api/src/repos/pg_tenant_repo.rs",
        function_name: "set_tier",
        source_anchor: "pg_tenant_repo.set_tier",
    },
    CoverageRegistration {
        scenario: "race_matrix_denominator_metadata",
        owner_path: "infra/api/src/routes/indexes/replicas.rs",
        function_name: "create_replica",
        source_anchor: "replica_service.create_replica",
    },
    CoverageRegistration {
        scenario: "race_matrix_denominator_metadata",
        owner_path: "infra/api/src/routes/indexes/replicas.rs",
        function_name: "delete_replica",
        source_anchor: "replica_service.remove_replica",
    },
];
