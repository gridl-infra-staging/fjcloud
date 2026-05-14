//! Build-time injection of deploy-provenance environment variables.
//!
//! Embeds four pieces of information into the binary so the running API
//! can answer "what code is this and where did it come from?" via the
//! `/version` endpoint. Without this, debugging "is prod on current main?"
//! requires SSH/SSM into the host — see `docs/runbooks/infra-deploy.md`.
//!
//! Source of values:
//!   - `FJCLOUD_DEV_SHA`     dev-repo HEAD SHA at the time of debbie sync.
//!     Read from `.debbie/sync_manifest.json` in the mirror tree by CI before
//!     invoking cargo.
//!   - `FJCLOUD_MIRROR_SHA`  the mirror-repo commit SHA being built. CI sets
//!     this from `$GITHUB_SHA`.
//!   - `FJCLOUD_SYNCED_AT`   ISO 8601 UTC timestamp of the debbie sync that
//!     produced this mirror commit.
//!   - `FJCLOUD_BUILD_TIME`  ISO 8601 UTC timestamp of the cargo build. CI
//!     sets this; local dev gets the literal "local-dev" so env!() resolves
//!     without panic.
//!
//! All four fall back to "local-dev" so:
//!   1. `cargo build` outside CI doesn't fail (env! is a compile-time op).
//!   2. The /version response visibly signals "this isn't a real release."

fn main() {
    // Helper: forward an env var into the compiled binary, defaulting to
    // "local-dev" when unset. Keeps the pattern uniform across all four.
    fn forward(name: &str) {
        let value = std::env::var(name).unwrap_or_else(|_| "local-dev".into());
        println!("cargo:rustc-env={}={}", name, value);
        // Rebuild if the env var changes between cargo invocations. Without
        // this, cargo would cache the first value seen and ignore CI updates.
        println!("cargo:rerun-if-env-changed={}", name);
    }

    forward("FJCLOUD_DEV_SHA");
    forward("FJCLOUD_MIRROR_SHA");
    forward("FJCLOUD_SYNCED_AT");
    forward("FJCLOUD_BUILD_TIME");
}
