//! Engine runtime-identity and compatibility classification.
//!
//! Extracted from `mod.rs` (2026-08-06) purely to keep that file under the
//! 850-line `check-sizes` limit; behaviour is unchanged. This is the seam the
//! sibling `engine_compatibility_tests.rs` was already written against, so the
//! split follows an existing boundary rather than inventing one.
//!
//! Everything here answers one question: given a flapjack engine's `/health`
//! payload and the identity fjcloud requires, is this engine the one we pinned?
//! `mod.rs` owns transport and the proxy surface; this module owns the verdict.

use serde::Deserialize;

const REQUIRED_FLAPJACK_IDENTITY_ENV_NAMES: [&str; 4] = [
    "FJCLOUD_FLAPJACK_VERSION",
    "FJCLOUD_FLAPJACK_REQUIRED_REVISION",
    "FJCLOUD_FLAPJACK_REQUIRED_BUILD_ID",
    "FJCLOUD_FLAPJACK_REQUIRED_SHA256",
];

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
#[error("incomplete Flapjack engine identity configuration; missing {missing_variables:?}")]
pub struct FlapjackEngineRequirementsError {
    missing_variables: Vec<&'static str>,
}

impl FlapjackEngineRequirementsError {
    pub fn missing_variables(&self) -> &[&'static str] {
        &self.missing_variables
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FlapjackEngineRequirements {
    pub expected_version: Option<String>,
    pub required_revision: Option<String>,
    pub required_build_id: Option<String>,
    pub required_sha256: Option<String>,
    pub required_capability: Option<String>,
}

impl FlapjackEngineRequirements {
    pub fn new(
        expected_version: Option<&str>,
        required_revision: Option<&str>,
        required_build_id: Option<&str>,
        required_sha256: Option<&str>,
        required_capability: Option<&str>,
    ) -> Self {
        Self {
            expected_version: non_empty_string(expected_version),
            required_revision: non_empty_string(required_revision),
            required_build_id: non_empty_string(required_build_id),
            required_sha256: non_empty_string(required_sha256),
            required_capability: non_empty_string(required_capability),
        }
    }

    pub fn from_env() -> Result<Self, FlapjackEngineRequirementsError> {
        Self::from_lookup(|name| std::env::var(name).ok())
    }

    pub(super) fn from_lookup(
        mut lookup: impl FnMut(&str) -> Option<String>,
    ) -> Result<Self, FlapjackEngineRequirementsError> {
        let mut configured_value =
            |name| lookup(name).and_then(|value| non_empty_string(Some(value.as_str())));
        let requirements = Self {
            expected_version: configured_value("FJCLOUD_FLAPJACK_VERSION"),
            required_revision: configured_value("FJCLOUD_FLAPJACK_REQUIRED_REVISION"),
            required_build_id: configured_value("FJCLOUD_FLAPJACK_REQUIRED_BUILD_ID"),
            required_sha256: configured_value("FJCLOUD_FLAPJACK_REQUIRED_SHA256"),
            // No capability is required by DEFAULT. fjcloud's search path forwards
            // opaque query bodies and uses no engine feature (see search.rs), and NO
            // shipped flapjack build advertises a vector capability — not the release
            // Linux musl assets fjcloud downloads/bakes, not the Docker image, not the
            // prod AMI (flapjack-1.0.2-pl13). A hard default of "vectorSearchLocal"
            // could therefore never be satisfied by any real engine, turning the
            // identity + Algolia-import admission gate into a permanent MissingCapability
            // failure (this was the local-dev-up-smoke blocker). Identity stays anchored
            // on version/revision/build_id/sha256; a specific required capability is
            // opt-in via FJCLOUD_FLAPJACK_REQUIRED_CAPABILITY, ready to re-enable when
            // local vector search is actually productized.
            required_capability: configured_value("FJCLOUD_FLAPJACK_REQUIRED_CAPABILITY"),
        };
        let configured_identity = [
            requirements.expected_version.as_ref(),
            requirements.required_revision.as_ref(),
            requirements.required_build_id.as_ref(),
            requirements.required_sha256.as_ref(),
        ];
        let missing_variables = REQUIRED_FLAPJACK_IDENTITY_ENV_NAMES
            .into_iter()
            .zip(configured_identity)
            .filter_map(|(name, value)| value.is_none().then_some(name))
            .collect::<Vec<_>>();
        if missing_variables.is_empty() {
            Ok(requirements)
        } else {
            Err(FlapjackEngineRequirementsError { missing_variables })
        }
    }

    fn exact_identity_required(&self) -> bool {
        self.required_revision.is_some() || self.required_build_id.is_some()
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FlapjackEngineCompatibilityResult {
    pub reason: FlapjackRuntimeIdentityReason,
}

impl FlapjackEngineCompatibilityResult {
    pub(super) fn new(reason: FlapjackRuntimeIdentityReason) -> Self {
        Self { reason }
    }

    pub fn is_match(&self) -> bool {
        self.reason == FlapjackRuntimeIdentityReason::Match
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FlapjackRuntimeIdentityReason {
    Match,
    /// The engine reports a version OLDER than the configured floor.
    VersionMismatch,
    /// Either the engine's reported version or the configured floor is not a
    /// strict MAJOR.MINOR.PATCH numeric version, so they cannot be ordered.
    /// Kept distinct from [`Self::VersionMismatch`] because "your engine is too
    /// old" and "I cannot read this version string" need different fixes, and
    /// collapsing them is how an unhelpful rejection message gets built.
    VersionUnparseable,
    RevisionMismatch,
    BuildIdMismatch,
    ChecksumMismatch,
    DirtyLocalBuild,
    MissingCapability,
    LegacyMalformedHealth,
    RuntimeUnreachable,
}

impl FlapjackRuntimeIdentityReason {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Match => "match",
            Self::VersionMismatch => "version_mismatch",
            Self::VersionUnparseable => "version_unparseable",
            Self::RevisionMismatch => "revision_mismatch",
            Self::BuildIdMismatch => "build_id_mismatch",
            Self::ChecksumMismatch => "checksum_mismatch",
            Self::DirtyLocalBuild => "dirty_local_build",
            Self::MissingCapability => "missing_capability",
            Self::LegacyMalformedHealth => "legacy_malformed_health",
            Self::RuntimeUnreachable => "runtime_unreachable",
        }
    }
}

fn non_empty_string(value: Option<&str>) -> Option<String> {
    value
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToOwned::to_owned)
}

pub(super) fn flapjack_health_url(flapjack_base_url: &str) -> String {
    format!("{}/health", flapjack_base_url.trim_end_matches('/'))
}

pub(super) fn flapjack_base_url_is_loopback(flapjack_base_url: &str) -> bool {
    reqwest::Url::parse(flapjack_base_url)
        .ok()
        .and_then(|url| url.host_str().map(str::to_owned))
        .is_some_and(|host| {
            host == "localhost"
                || host
                    .parse::<std::net::IpAddr>()
                    .is_ok_and(|ip| ip.is_loopback())
        })
}

pub(super) fn classify_flapjack_health(
    body: &str,
    requirements: &FlapjackEngineRequirements,
    allow_loopback_legacy_identity: bool,
) -> FlapjackRuntimeIdentityReason {
    let Ok(health) = serde_json::from_str::<serde_json::Value>(body) else {
        return FlapjackRuntimeIdentityReason::LegacyMalformedHealth;
    };
    let Some(health) = health.as_object() else {
        return FlapjackRuntimeIdentityReason::LegacyMalformedHealth;
    };
    let build = health
        .get("build")
        .and_then(serde_json::Value::as_object)
        .unwrap_or(health);

    classify_flapjack_identity(
        requirements,
        observed_identity(build, health),
        allow_loopback_legacy_identity,
    )
}

/// Build the observed identity for a parsed health payload.
///
/// Runtime identity is anchored on the fields Flapjack actually self-reports:
/// version, revision, build_id, dirty, and capabilities. The configured binary
/// SHA is verified by source/launch tooling before API startup; if a runtime
/// health payload does report a SHA, this classifier still checks it for drift.
/// The `runtime_security` seam is resolved the same way `capabilities` is
/// (build object first, then the top-level health object) but is
/// *forward-compatible only*: it carries non-build runtime security
/// observations and is never consulted by `classify_flapjack_identity`.
pub(super) fn observed_identity<'a>(
    build: &'a serde_json::Map<String, serde_json::Value>,
    health: &'a serde_json::Map<String, serde_json::Value>,
) -> ObservedFlapjackIdentity<'a> {
    let version = first_string(build, &["version"]).or_else(|| first_string(health, &["version"]));
    ObservedFlapjackIdentity {
        version,
        revision: first_string(build, &["producer_revision", "revision"]),
        build_id: first_string(build, &["build_id", "workspaceDigest"]),
        binary_sha: first_string(build, &["binary_sha256", "sha256"]),
        dirty: build.get("dirty").and_then(serde_json::Value::as_bool),
        capabilities: build
            .get("capabilities")
            .or_else(|| health.get("capabilities")),
        runtime_security: build
            .get("runtime_security")
            .or_else(|| health.get("runtime_security"))
            .and_then(|value| {
                serde_json::from_value::<ObservedRuntimeSecurity>(value.clone()).ok()
            }),
    }
}

pub(super) struct ObservedFlapjackIdentity<'a> {
    version: Option<&'a str>,
    revision: Option<&'a str>,
    build_id: Option<&'a str>,
    binary_sha: Option<&'a str>,
    dirty: Option<bool>,
    capabilities: Option<&'a serde_json::Value>,
    /// Forward-compatible runtime security observations. Populated from the
    /// health payload but intentionally NOT consulted by
    /// `classify_flapjack_identity`; build/capability compatibility is decided
    /// solely by the immutable-identity fields above. See
    /// [`ObservedRuntimeSecurity`].
    ///
    /// Not yet read by production code — this is a deliberate forward seam for
    /// future runtime-security enforcement.
    #[allow(dead_code)]
    pub(super) runtime_security: Option<ObservedRuntimeSecurity>,
}

/// Typed, forward-compatible view of an engine's *runtime* security posture as
/// reported by its health payload.
///
/// This is a deliberate seam for FUTURE non-build security observations. It is
/// never consulted for build/capability decisions (those stay owned by
/// `FlapjackEngineRequirements`, `FlapjackRuntimeIdentityReason`, and
/// `classify_flapjack_identity`). Unknown/future runtime-security fields are
/// tolerated on purpose — there is no `#[serde(deny_unknown_fields)]` — so
/// newer engines can report additional posture signals without regressing
/// build-identity classification. Field names are intentionally generic
/// runtime-posture observations, not build-identity or issuance concepts.
#[derive(Debug, Clone, Default, PartialEq, Eq, Deserialize)]
pub(super) struct ObservedRuntimeSecurity {
    #[serde(default)]
    posture: Option<String>,
    #[serde(default)]
    enforced: Option<bool>,
}

// Typed accessors for the forward seam. Exercised by tests today; production
// enforcement will consume them in a later stage.
#[allow(dead_code)]
impl ObservedRuntimeSecurity {
    /// Reported runtime security posture label, if the engine advertised one.
    pub(super) fn posture(&self) -> Option<&str> {
        self.posture.as_deref()
    }

    /// Whether the engine reports runtime security enforcement active, if
    /// advertised.
    pub(super) fn enforced(&self) -> Option<bool> {
        self.enforced
    }
}

fn classify_flapjack_identity(
    requirements: &FlapjackEngineRequirements,
    observed: ObservedFlapjackIdentity<'_>,
    allow_loopback_legacy_identity: bool,
) -> FlapjackRuntimeIdentityReason {
    if observed.version.is_none() {
        return FlapjackRuntimeIdentityReason::LegacyMalformedHealth;
    }
    // FJCLOUD_FLAPJACK_VERSION is a FLOOR, not an equality target: the pinned
    // release or anything newer is accepted, older is refused.
    //
    // It cannot be an equality target, because the same constant is ALSO the
    // exact release tag CI downloads (.github/workflows/ci.yml,
    // scripts/devbox/fetch_flapjack_release.sh). flapjack `main` bumps its
    // version the moment work lands and the matching release is cut later, so
    // between those two moments no value of the pin satisfies both consumers:
    // pointing it at the unpublished version 404s CI's download (which gates
    // both deploy jobs), and leaving it behind rejects every locally
    // source-built engine. Equality was measured rejecting correct checkouts
    // and provoking lanes to repoint FLAPJACK_DEV_DIR at a stale checkout —
    // a false green.
    //
    // The shared spec for this rule, read by this suite AND by the Python
    // implementation in scripts/lib/local_stack_contract.sh, lives at
    // scripts/tests/fixtures/flapjack_version_floor_cases.json.
    if let Some(floor) = requirements.expected_version.as_deref() {
        match (
            observed.version.and_then(parse_engine_version),
            parse_engine_version(floor),
        ) {
            (Some(observed_version), Some(floor_version)) => {
                if observed_version < floor_version {
                    return FlapjackRuntimeIdentityReason::VersionMismatch;
                }
            }
            // Fail closed: an unreadable version on either side cannot establish
            // that the engine satisfies the floor.
            _ => return FlapjackRuntimeIdentityReason::VersionUnparseable,
        }
    }
    if observed.dirty == Some(true) {
        return FlapjackRuntimeIdentityReason::DirtyLocalBuild;
    }
    if requirements
        .required_revision
        .as_deref()
        .is_some_and(|expected| observed.revision.is_some_and(|actual| actual != expected))
    {
        return FlapjackRuntimeIdentityReason::RevisionMismatch;
    }
    if requirements
        .required_build_id
        .as_deref()
        .is_some_and(|expected| observed.build_id.is_some_and(|actual| actual != expected))
    {
        return FlapjackRuntimeIdentityReason::BuildIdMismatch;
    }
    if requirements
        .required_sha256
        .as_deref()
        .is_some_and(|expected| observed.binary_sha.is_some_and(|actual| actual != expected))
    {
        return FlapjackRuntimeIdentityReason::ChecksumMismatch;
    }
    if missing_required_runtime_identity(requirements, &observed, allow_loopback_legacy_identity) {
        return FlapjackRuntimeIdentityReason::LegacyMalformedHealth;
    }
    if !required_capability_present(requirements, observed.capabilities) {
        return FlapjackRuntimeIdentityReason::MissingCapability;
    }
    FlapjackRuntimeIdentityReason::Match
}

/// Parse a strict MAJOR.MINOR.PATCH numeric version, or `None`.
///
/// Deliberately strict, and deliberately NOT lenient about suffixes. fjcloud
/// pins published flapjack releases, which are always three numeric components.
/// A `-rc` suffix is refused rather than stripped: semver orders `1.0.12-rc.1`
/// BELOW `1.0.12`, so a suffix-stripping parser would rank a release candidate
/// equal to the finished release and let it satisfy a floor it does not meet.
///
/// Must stay behaviourally identical to `parse_version` in
/// `scripts/lib/local_stack_contract.sh`; the shared cases in
/// `scripts/tests/fixtures/flapjack_version_floor_cases.json` hold both to it.
fn parse_engine_version(value: &str) -> Option<(u64, u64, u64)> {
    let mut parts = value.split('.');
    let mut numbers = [0u64; 3];
    for slot in numbers.iter_mut() {
        let part = parts.next()?;
        // `u64::from_str` would accept a leading `+`, so screen the bytes first.
        if part.is_empty() || !part.bytes().all(|byte| byte.is_ascii_digit()) {
            return None;
        }
        *slot = part.parse().ok()?;
    }
    // More than three components is not a version fjcloud knows how to order.
    if parts.next().is_some() {
        return None;
    }
    Some((numbers[0], numbers[1], numbers[2]))
}

fn missing_required_runtime_identity(
    requirements: &FlapjackEngineRequirements,
    observed: &ObservedFlapjackIdentity<'_>,
    allow_loopback_legacy_identity: bool,
) -> bool {
    let missing_runtime_identity = requirements.exact_identity_required()
        && (observed.dirty.is_none() || observed.revision.is_none() || observed.build_id.is_none());
    missing_runtime_identity && !allow_loopback_legacy_identity
}

fn required_capability_present(
    requirements: &FlapjackEngineRequirements,
    capabilities: Option<&serde_json::Value>,
) -> bool {
    let Some(required_capability) = requirements.required_capability.as_deref() else {
        return true;
    };
    match capabilities {
        Some(serde_json::Value::Array(items)) => items
            .iter()
            .any(|item| item.as_str() == Some(required_capability)),
        Some(serde_json::Value::Object(map)) => map
            .get(required_capability)
            .is_some_and(|value| value.as_bool() == Some(true)),
        _ => false,
    }
}

fn first_string<'a>(
    payload: &'a serde_json::Map<String, serde_json::Value>,
    names: &[&str],
) -> Option<&'a str> {
    names.iter().find_map(|name| {
        payload
            .get(*name)
            .and_then(serde_json::Value::as_str)
            .filter(|value| !value.is_empty())
    })
}
