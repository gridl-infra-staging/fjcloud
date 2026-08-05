use serde::Serialize;
use utoipa::ToSchema;

use crate::models::algolia_import_job::SourceImportProvider;

#[derive(Debug, Serialize, ToSchema, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct AlgoliaMigrationCapabilities {
    pub cancel: bool,
    pub preview: bool,
    pub resume: bool,
    pub replace: bool,
    pub verify: bool,
}

/// The single fail-closed capability set. Callers that must advertise nothing
/// name this constructor instead of spelling out an all-false literal, so a new
/// capability field never has to reopen every fail-closed call site.
pub fn fail_closed_migration_capabilities() -> AlgoliaMigrationCapabilities {
    AlgoliaMigrationCapabilities {
        cancel: false,
        preview: false,
        resume: false,
        replace: false,
        verify: false,
    }
}

/// Whether the source-verification engine can compare this provider's source
/// index against an fjcloud destination.
///
/// This helper and the `provider != SourceImportProvider::Algolia` guard in
/// `verify.rs::verify_source_migration` state the same Algolia-only rule and
/// must move together if source verification is widened past Algolia.
fn engine_supports_source_verification(source_provider: SourceImportProvider) -> bool {
    // Keep this match exhaustive so a new provider cannot silently inherit
    // verification support without an explicit engine-contract decision.
    match source_provider {
        SourceImportProvider::Algolia => true,
        SourceImportProvider::Meilisearch | SourceImportProvider::Typesense => false,
    }
}

#[allow(dead_code)]
pub fn route_mounted_migration_capabilities() -> AlgoliaMigrationCapabilities {
    AlgoliaMigrationCapabilities {
        cancel: true,
        preview: true,
        resume: false,
        replace: true,
        verify: true,
    }
}

#[allow(dead_code)]
pub fn engine_supported_migration_capabilities(
    source_provider: SourceImportProvider,
) -> AlgoliaMigrationCapabilities {
    // This is the code-owned engine support declaration, not a live HTTP probe.
    // Only preview support varies by provider; the lifecycle operations share
    // one provider-neutral engine implementation.
    AlgoliaMigrationCapabilities {
        cancel: true,
        // Keep this match exhaustive so a new provider cannot silently inherit
        // a fail-closed value without an explicit engine-contract decision.
        preview: match source_provider {
            SourceImportProvider::Algolia | SourceImportProvider::Meilisearch => true,
            SourceImportProvider::Typesense => false,
        },
        resume: false,
        replace: true,
        verify: engine_supports_source_verification(source_provider),
    }
}

pub fn migration_capabilities(
    route_mounted: AlgoliaMigrationCapabilities,
    engine_supported: AlgoliaMigrationCapabilities,
) -> AlgoliaMigrationCapabilities {
    // Future engine capability values must extend
    // ensure_algolia_import_engine_compatible/check_engine_compatibility instead
    // of introducing another engine probe.
    AlgoliaMigrationCapabilities {
        cancel: route_mounted.cancel && engine_supported.cancel,
        preview: route_mounted.preview && engine_supported.preview,
        resume: route_mounted.resume && engine_supported.resume,
        replace: route_mounted.replace && engine_supported.replace,
        verify: route_mounted.verify && engine_supported.verify,
    }
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::{
        engine_supported_migration_capabilities, fail_closed_migration_capabilities,
        migration_capabilities, route_mounted_migration_capabilities, AlgoliaMigrationCapabilities,
    };
    use crate::models::algolia_import_job::SourceImportProvider;
    use crate::routes::migration::AlgoliaMigrationAvailabilityResponse;

    /// Every capability true, so each case below only has to name the fields it
    /// varies via struct-update syntax.
    fn all_capabilities_supported() -> AlgoliaMigrationCapabilities {
        AlgoliaMigrationCapabilities {
            cancel: true,
            preview: true,
            resume: true,
            replace: true,
            verify: true,
        }
    }

    /// The serialized unavailable response is the customer-visible fail-closed
    /// contract, so it is asserted as exact JSON rather than field by field.
    #[test]
    fn capabilities_unavailable_response_serializes_complete_fail_closed_contract() {
        let serialized = serde_json::to_value(AlgoliaMigrationAvailabilityResponse::unavailable())
            .expect("unavailable response should serialize");

        assert_eq!(
            serialized,
            json!({
                "available": false,
                "reason": "temporarily_unavailable",
                "message": "Algolia migration is temporarily unavailable while we replace the importer.",
                "capabilities": {
                    "cancel": false,
                    "preview": false,
                    "resume": false,
                    "replace": false,
                    "verify": false
                }
            })
        );
    }

    /// A capability is published only when both the route and the engine sides
    /// declare it, so an all-supported intersection stays all-supported.
    #[test]
    fn capabilities_owner_returns_all_true_when_routes_and_engine_support_all_operations() {
        assert_eq!(
            migration_capabilities(all_capabilities_supported(), all_capabilities_supported()),
            all_capabilities_supported()
        );
    }

    /// Each capability must be intersected independently, from either side.
    #[test]
    fn capabilities_owner_returns_false_for_each_operation_when_either_side_is_false() {
        let cases = [
            (
                AlgoliaMigrationCapabilities {
                    cancel: false,
                    ..all_capabilities_supported()
                },
                all_capabilities_supported(),
                AlgoliaMigrationCapabilities {
                    cancel: false,
                    ..all_capabilities_supported()
                },
            ),
            (
                all_capabilities_supported(),
                AlgoliaMigrationCapabilities {
                    resume: false,
                    ..all_capabilities_supported()
                },
                AlgoliaMigrationCapabilities {
                    resume: false,
                    ..all_capabilities_supported()
                },
            ),
            (
                AlgoliaMigrationCapabilities {
                    replace: false,
                    ..all_capabilities_supported()
                },
                AlgoliaMigrationCapabilities {
                    replace: false,
                    ..all_capabilities_supported()
                },
                AlgoliaMigrationCapabilities {
                    replace: false,
                    ..all_capabilities_supported()
                },
            ),
            (
                AlgoliaMigrationCapabilities {
                    preview: false,
                    ..all_capabilities_supported()
                },
                all_capabilities_supported(),
                AlgoliaMigrationCapabilities {
                    preview: false,
                    ..all_capabilities_supported()
                },
            ),
            (
                all_capabilities_supported(),
                AlgoliaMigrationCapabilities {
                    preview: false,
                    ..all_capabilities_supported()
                },
                AlgoliaMigrationCapabilities {
                    preview: false,
                    ..all_capabilities_supported()
                },
            ),
            (
                AlgoliaMigrationCapabilities {
                    verify: false,
                    ..all_capabilities_supported()
                },
                all_capabilities_supported(),
                AlgoliaMigrationCapabilities {
                    verify: false,
                    ..all_capabilities_supported()
                },
            ),
            (
                all_capabilities_supported(),
                AlgoliaMigrationCapabilities {
                    verify: false,
                    ..all_capabilities_supported()
                },
                AlgoliaMigrationCapabilities {
                    verify: false,
                    ..all_capabilities_supported()
                },
            ),
        ];

        for (route_mounted, engine_supported, expected) in cases {
            assert_eq!(
                migration_capabilities(route_mounted, engine_supported),
                expected
            );
        }
    }

    #[test]
    fn capabilities_owner_publishes_nothing_from_the_fail_closed_constructor() {
        assert_eq!(
            migration_capabilities(
                fail_closed_migration_capabilities(),
                all_capabilities_supported()
            ),
            fail_closed_migration_capabilities()
        );
    }

    #[test]
    fn route_mounted_migration_capabilities_matches_mounted_route_surface() {
        // Mirrors infra/api/src/router/route_assembly.rs:add_migration_routes,
        // which mounts cancel, preview, replace, and verify but not resume.
        assert_eq!(
            route_mounted_migration_capabilities(),
            AlgoliaMigrationCapabilities {
                resume: false,
                ..all_capabilities_supported()
            }
        );
    }

    #[test]
    fn engine_supported_migration_capabilities_matches_provider_preview_and_verify_support() {
        let expectations = [
            (SourceImportProvider::Algolia, true, true),
            (SourceImportProvider::Meilisearch, true, false),
            (SourceImportProvider::Typesense, false, false),
        ];

        for (provider, preview, verify) in expectations {
            assert_eq!(
                engine_supported_migration_capabilities(provider),
                AlgoliaMigrationCapabilities {
                    preview,
                    resume: false,
                    verify,
                    ..all_capabilities_supported()
                },
                "engine capabilities must match the closed-union contract for {}",
                provider.as_str()
            );
        }
    }

    #[test]
    fn engine_supported_migration_capabilities_preserves_resume_false_invariant() {
        assert_eq!(
            engine_supported_migration_capabilities(SourceImportProvider::Algolia),
            AlgoliaMigrationCapabilities {
                resume: false,
                ..all_capabilities_supported()
            },
            "resume remains false even when the engine receipt includes base and cancel support"
        );
    }
}
