
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
