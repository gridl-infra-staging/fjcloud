use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};
use std::path::Path;

fn main() {
    // `sqlx::migrate!` embeds the migration directory at compile time. Cargo
    // does not discover that proc-macro input by itself, so an incremental
    // build must be invalidated whenever a migration changes.
    println!("cargo:rerun-if-changed=../migrations");
    println!(
        "cargo:rustc-env=FJCLOUD_MIGRATIONS_FINGERPRINT={}",
        migration_fingerprint(Path::new("../migrations"))
    );

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

fn migration_fingerprint(migrations_dir: &Path) -> u64 {
    let mut paths = std::fs::read_dir(migrations_dir)
        .expect("read migrations directory")
        .map(|entry| entry.expect("read migration entry").path())
        .filter(|path| path.extension().is_some_and(|extension| extension == "sql"))
        .collect::<Vec<_>>();
    paths.sort();

    let mut hasher = DefaultHasher::new();
    for path in paths {
        path.file_name()
            .expect("migration filename")
            .hash(&mut hasher);
        std::fs::read(&path)
            .unwrap_or_else(|error| panic!("read migration {}: {error}", path.display()))
            .hash(&mut hasher);
    }
    hasher.finish()
}
