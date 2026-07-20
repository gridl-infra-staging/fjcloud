use serde::Serialize;
use utoipa::ToSchema;

#[derive(Debug, Serialize, ToSchema, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct AlgoliaMigrationCapabilities {
    pub cancel: bool,
    pub resume: bool,
    pub replace: bool,
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
        resume: route_mounted.resume && engine_supported.resume,
        replace: route_mounted.replace && engine_supported.replace,
    }
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::{migration_capabilities, AlgoliaMigrationCapabilities};
    use crate::routes::migration::AlgoliaMigrationAvailabilityResponse;

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
                    "resume": false,
                    "replace": false
                }
            })
        );
    }

    #[test]
    fn capabilities_owner_returns_all_true_when_routes_and_engine_support_all_operations() {
        assert_eq!(
            migration_capabilities(
                AlgoliaMigrationCapabilities {
                    cancel: true,
                    resume: true,
                    replace: true,
                },
                AlgoliaMigrationCapabilities {
                    cancel: true,
                    resume: true,
                    replace: true,
                },
            ),
            AlgoliaMigrationCapabilities {
                cancel: true,
                resume: true,
                replace: true,
            }
        );
    }

    #[test]
    fn capabilities_owner_returns_false_for_each_operation_when_either_side_is_false() {
        let cases = [
            (
                AlgoliaMigrationCapabilities {
                    cancel: false,
                    resume: true,
                    replace: true,
                },
                AlgoliaMigrationCapabilities {
                    cancel: true,
                    resume: true,
                    replace: true,
                },
                AlgoliaMigrationCapabilities {
                    cancel: false,
                    resume: true,
                    replace: true,
                },
            ),
            (
                AlgoliaMigrationCapabilities {
                    cancel: true,
                    resume: true,
                    replace: true,
                },
                AlgoliaMigrationCapabilities {
                    cancel: true,
                    resume: false,
                    replace: true,
                },
                AlgoliaMigrationCapabilities {
                    cancel: true,
                    resume: false,
                    replace: true,
                },
            ),
            (
                AlgoliaMigrationCapabilities {
                    cancel: true,
                    resume: true,
                    replace: false,
                },
                AlgoliaMigrationCapabilities {
                    cancel: true,
                    resume: true,
                    replace: false,
                },
                AlgoliaMigrationCapabilities {
                    cancel: true,
                    resume: true,
                    replace: false,
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
}
