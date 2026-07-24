#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/test_helpers.sh"

validator="ops/packer/validate_flapjack_ami_input.sh"
packer_file="ops/packer/flapjack-ami.pkr.hcl"

assert_file_executable() {
  local file="$1"
  local description="$2"
  assert_file_exists "$file" "${description} exists"
  if [[ -x "$file" ]]; then
    pass "${description} is executable"
  else
    fail "${description} is executable"
  fi
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

write_flapjack_binary() {
  local path="$1"
  local build_json="$2"
  cat >"$path" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [[ "\${1:-}" == "build-info" && "\${2:-}" == "--json" ]]; then
  cat <<'JSON'
$build_json
JSON
  exit 0
fi
exit 64
EOF
  chmod 0755 "$path"
}

write_manifest() {
  local path="$1"
  local archive_name="$2"
  local archive_sha="$3"
  local build_json="$4"
  jq -n \
    --arg file "$archive_name" \
    --arg target "aarch64-unknown-linux-musl" \
    --arg arch "aarch64" \
    --arg profile "release" \
    --arg sha "$archive_sha" \
    --argjson build "$build_json" \
    '{
      schemaVersion: 1,
      artifact: {
        file: $file,
        target: $target,
        arch: $arch,
        profile: $profile,
        sha256: $sha
      },
      build: $build
    }' >"$path"
}

make_good_fixture() {
  local fixture_dir="$1"
  local build_json='{"schemaVersion":1,"version":"1.0.11","revision":"0123456789abcdef0123456789abcdef01234567","revisionKnown":true,"dirty":null,"dirtyKnown":false,"workspaceDigest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","profile":"release","target":"aarch64-unknown-linux-musl","features":[],"capabilities":{"vectorSearch":false,"vectorSearchLocal":false}}'
  mkdir -p "$fixture_dir/archive-root"
  write_flapjack_binary "$fixture_dir/archive-root/flapjack" "$build_json"
  (cd "$fixture_dir/archive-root" && tar -czf "../flapjack-aarch64-unknown-linux-musl.tar.gz" .)
  write_manifest \
    "$fixture_dir/flapjack-aarch64-unknown-linux-musl.manifest.json" \
    "flapjack-aarch64-unknown-linux-musl.tar.gz" \
    "$(sha256_file "$fixture_dir/flapjack-aarch64-unknown-linux-musl.tar.gz")" \
    "$build_json"
}

run_validator_expect_success() {
  local description="$1"
  local fixture_dir="$2"
  local output_file="$fixture_dir/out/flapjack"
  mkdir -p "$fixture_dir/out"
  if "$validator" \
    --manifest "$fixture_dir/flapjack-aarch64-unknown-linux-musl.manifest.json" \
    --archive "$fixture_dir/flapjack-aarch64-unknown-linux-musl.tar.gz" \
    --out "$output_file" >/dev/null 2>&1 && [[ -x "$output_file" ]]; then
    pass "$description"
  else
    fail "$description"
  fi
}

run_validator_expect_failure() {
  local description="$1"
  local fixture_dir="$2"
  local output_file="$fixture_dir/out/flapjack"
  mkdir -p "$fixture_dir/out"
  if "$validator" \
    --manifest "$fixture_dir/flapjack-aarch64-unknown-linux-musl.manifest.json" \
    --archive "$fixture_dir/flapjack-aarch64-unknown-linux-musl.tar.gz" \
    --out "$output_file" >/dev/null 2>&1; then
    fail "$description"
  elif [[ -e "$output_file" ]]; then
    fail "$description leaves no output artifact"
  else
    pass "$description"
  fi
}

mutate_manifest() {
  local fixture_dir="$1"
  local jq_filter="$2"
  local tmp_file="$fixture_dir/mutated-manifest.json"
  jq "$jq_filter" "$fixture_dir/flapjack-aarch64-unknown-linux-musl.manifest.json" >"$tmp_file"
  mv "$tmp_file" "$fixture_dir/flapjack-aarch64-unknown-linux-musl.manifest.json"
}

mutate_build_identity_pair() {
  local fixture_dir="$1"
  local build_filter="$2"
  local manifest_path="$fixture_dir/flapjack-aarch64-unknown-linux-musl.manifest.json"
  local archive_path="$fixture_dir/flapjack-aarch64-unknown-linux-musl.tar.gz"
  local build_json
  local archive_sha256
  local tmp_file="$fixture_dir/mutated-manifest.json"

  build_json="$(jq -c ".build | $build_filter" "$manifest_path")"
  write_flapjack_binary "$fixture_dir/archive-root/flapjack" "$build_json"
  (cd "$fixture_dir/archive-root" && tar -czf "$archive_path" .)
  archive_sha256="$(sha256_file "$archive_path")"
  jq \
    --argjson build "$build_json" \
    --arg sha256 "$archive_sha256" \
    '.build = $build | .artifact.sha256 = $sha256' \
    "$manifest_path" >"$tmp_file"
  mv "$tmp_file" "$manifest_path"
}

with_fixture() {
  local name="$1"
  local tmp_root="$2"
  local fixture_dir="$tmp_root/$name"
  make_good_fixture "$fixture_dir"
  printf '%s\n' "$fixture_dir"
}

tmp_root="$(mktemp -d)"
trap 'rm -rf "$tmp_root"' EXIT

assert_file_executable "$validator" "validate_flapjack_ami_input.sh"
assert_file_contains "$validator" 'EXPECTED_SCHEMA_VERSION=1' "validator checks canonical E3 schema version"
assert_file_contains "$validator" 'aarch64-unknown-linux-musl' "validator checks E3 target"
assert_file_contains "$validator" 'build-info --json' "validator checks binary build-info"
assert_file_contains "$validator" 'jq -S -c .*\.build' "validator canonicalizes manifest build object"
assert_file_contains "$validator" 'tar -tzf' "validator lists archive members before extraction"

good_fixture="$(with_fixture good "$tmp_root")"
run_validator_expect_success "validator accepts exact E3 manifest/archive pair" "$good_fixture"

missing_manifest_fixture="$(with_fixture missing-manifest "$tmp_root")"
rm -f "$missing_manifest_fixture/flapjack-aarch64-unknown-linux-musl.manifest.json"
run_validator_expect_failure "validator rejects absent manifest input" "$missing_manifest_fixture"

missing_archive_fixture="$(with_fixture missing-archive "$tmp_root")"
rm -f "$missing_archive_fixture/flapjack-aarch64-unknown-linux-musl.tar.gz"
run_validator_expect_failure "validator rejects absent archive input" "$missing_archive_fixture"

malformed_fixture="$(with_fixture malformed "$tmp_root")"
printf '{not-json' >"$malformed_fixture/flapjack-aarch64-unknown-linux-musl.manifest.json"
run_validator_expect_failure "validator rejects malformed manifest JSON" "$malformed_fixture"

wrong_schema_fixture="$(with_fixture wrong-schema "$tmp_root")"
mutate_manifest "$wrong_schema_fixture" '.schemaVersion = 2'
run_validator_expect_failure "validator rejects wrong schemaVersion" "$wrong_schema_fixture"

wrong_schema_type_fixture="$(with_fixture wrong-schema-type "$tmp_root")"
mutate_manifest "$wrong_schema_type_fixture" '.schemaVersion = "1"'
run_validator_expect_failure "validator rejects non-numeric schemaVersion" "$wrong_schema_type_fixture"

wrong_file_fixture="$(with_fixture wrong-file "$tmp_root")"
mutate_manifest "$wrong_file_fixture" '.artifact.file = "other.tar.gz"'
run_validator_expect_failure "validator rejects artifact.file that does not name selected archive" "$wrong_file_fixture"

wrong_target_fixture="$(with_fixture wrong-target "$tmp_root")"
mutate_manifest "$wrong_target_fixture" '.artifact.target = "x86_64-unknown-linux-musl"'
run_validator_expect_failure "validator rejects non-E3 target" "$wrong_target_fixture"

wrong_arch_fixture="$(with_fixture wrong-arch "$tmp_root")"
mutate_manifest "$wrong_arch_fixture" '.artifact.arch = "x86_64"'
run_validator_expect_failure "validator rejects non-arm64 artifact arch" "$wrong_arch_fixture"

wrong_profile_fixture="$(with_fixture wrong-profile "$tmp_root")"
mutate_manifest "$wrong_profile_fixture" '.artifact.profile = "debug"'
run_validator_expect_failure "validator rejects non-release artifact profile" "$wrong_profile_fixture"

unknown_identity_fixture="$(with_fixture unknown-identity "$tmp_root")"
mutate_manifest "$unknown_identity_fixture" '.build.version = "unknown"'
run_validator_expect_failure "validator rejects unknown release identity" "$unknown_identity_fixture"

unknown_revision_fixture="$(with_fixture unknown-revision "$tmp_root")"
mutate_manifest "$unknown_revision_fixture" '.build.revisionKnown = false | .build.revision = null'
run_validator_expect_failure "validator rejects unknown release revision" "$unknown_revision_fixture"

invalid_revision_fixture="$(with_fixture invalid-revision "$tmp_root")"
mutate_manifest "$invalid_revision_fixture" '.build.revision = "abc123"'
run_validator_expect_failure "validator rejects non-canonical release revision" "$invalid_revision_fixture"

unknown_digest_fixture="$(with_fixture unknown-digest "$tmp_root")"
mutate_manifest "$unknown_digest_fixture" '.build.workspaceDigest = ""'
run_validator_expect_failure "validator rejects unknown workspace digest" "$unknown_digest_fixture"

dirty_identity_fixture="$(with_fixture dirty-identity "$tmp_root")"
mutate_build_identity_pair "$dirty_identity_fixture" '.dirtyKnown = true | .dirty = true'
run_validator_expect_failure "validator rejects dirty release identity" "$dirty_identity_fixture"

known_dirty_without_value_fixture="$(with_fixture known-dirty-without-value "$tmp_root")"
mutate_build_identity_pair \
  "$known_dirty_without_value_fixture" \
  '.dirtyKnown = true | .dirty = null'
run_validator_expect_failure \
  "validator rejects known dirty state without a boolean value" \
  "$known_dirty_without_value_fixture"

unknown_dirty_with_value_fixture="$(with_fixture unknown-dirty-with-value "$tmp_root")"
mutate_build_identity_pair \
  "$unknown_dirty_with_value_fixture" \
  '.dirtyKnown = false | .dirty = false'
run_validator_expect_failure \
  "validator rejects unknown dirty state with a boolean value" \
  "$unknown_dirty_with_value_fixture"

wrong_build_target_fixture="$(with_fixture wrong-build-target "$tmp_root")"
mutate_manifest "$wrong_build_target_fixture" '.build.target = "x86_64-unknown-linux-musl"'
run_validator_expect_failure "validator rejects build target that disagrees with artifact target" "$wrong_build_target_fixture"

mutated_archive_fixture="$(with_fixture mutated-archive "$tmp_root")"
printf x >>"$mutated_archive_fixture/flapjack-aarch64-unknown-linux-musl.tar.gz"
run_validator_expect_failure "validator rejects archive checksum mutation" "$mutated_archive_fixture"

build_mismatch_fixture="$(with_fixture build-mismatch "$tmp_root")"
write_flapjack_binary "$build_mismatch_fixture/archive-root/flapjack" '{"schemaVersion":1,"version":"1.0.11","revision":"ffffffffffffffffffffffffffffffffffffffff","revisionKnown":true,"dirty":null,"dirtyKnown":false,"workspaceDigest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","profile":"release","target":"aarch64-unknown-linux-musl","features":[],"capabilities":{"vectorSearch":false,"vectorSearchLocal":false}}'
(cd "$build_mismatch_fixture/archive-root" && tar -czf "../flapjack-aarch64-unknown-linux-musl.tar.gz" .)
mutate_manifest "$build_mismatch_fixture" ".artifact.sha256 = \"$(sha256_file "$build_mismatch_fixture/flapjack-aarch64-unknown-linux-musl.tar.gz")\""
run_validator_expect_failure "validator rejects binary build-info mismatch" "$build_mismatch_fixture"

unsafe_member_fixture="$(with_fixture unsafe-member "$tmp_root")"
rm -rf "$unsafe_member_fixture/archive-root"
mkdir -p "$unsafe_member_fixture/archive-root/nested"
write_flapjack_binary "$unsafe_member_fixture/archive-root/nested/flapjack" '{"schemaVersion":1,"version":"1.0.11","revision":"0123456789abcdef0123456789abcdef01234567","revisionKnown":true,"dirty":null,"dirtyKnown":false,"workspaceDigest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","profile":"release","target":"aarch64-unknown-linux-musl","features":[],"capabilities":{"vectorSearch":false,"vectorSearchLocal":false}}'
(cd "$unsafe_member_fixture/archive-root" && tar -czf "../flapjack-aarch64-unknown-linux-musl.tar.gz" nested/flapjack)
mutate_manifest "$unsafe_member_fixture" ".artifact.sha256 = \"$(sha256_file "$unsafe_member_fixture/flapjack-aarch64-unknown-linux-musl.tar.gz")\""
run_validator_expect_failure "validator rejects unsafe archive member path" "$unsafe_member_fixture"

symlink_member_fixture="$(with_fixture symlink-member "$tmp_root")"
mv "$symlink_member_fixture/archive-root/flapjack" "$symlink_member_fixture/host-flapjack"
ln -s "$symlink_member_fixture/host-flapjack" "$symlink_member_fixture/archive-root/flapjack"
(cd "$symlink_member_fixture/archive-root" && tar -czf "../flapjack-aarch64-unknown-linux-musl.tar.gz" flapjack)
mutate_manifest "$symlink_member_fixture" ".artifact.sha256 = \"$(sha256_file "$symlink_member_fixture/flapjack-aarch64-unknown-linux-musl.tar.gz")\""
run_validator_expect_failure "validator rejects symlink archive member" "$symlink_member_fixture"

ambiguous_member_fixture="$(with_fixture ambiguous-member "$tmp_root")"
printf 'extra' >"$ambiguous_member_fixture/archive-root/extra"
(cd "$ambiguous_member_fixture/archive-root" && tar -czf "../flapjack-aarch64-unknown-linux-musl.tar.gz" flapjack extra)
mutate_manifest "$ambiguous_member_fixture" ".artifact.sha256 = \"$(sha256_file "$ambiguous_member_fixture/flapjack-aarch64-unknown-linux-musl.tar.gz")\""
run_validator_expect_failure "validator rejects ambiguous archive members" "$ambiguous_member_fixture"

assert_file_exists "$packer_file" "flapjack AMI Packer template exists"
assert_file_contains "$packer_file" 'variable "flapjack_manifest_path"' "Packer requires upstream manifest path input"
assert_file_contains "$packer_file" 'variable "flapjack_archive_path"' "Packer requires upstream archive path input"
assert_file_contains "$packer_file" 'jsondecode\(file\(var\.flapjack_manifest_path\)\)' "Packer parses selected manifest with HCL"
assert_file_not_contains "$packer_file" 'filesha256\(' "Packer template avoids the unsupported filesha256 function"
assert_file_contains "$packer_file" 'sha256\(file\(var\.flapjack_manifest_path\)\)' "Packer receipts selected manifest bytes"
assert_file_contains "$packer_file" 'flapjack_release_manifest\.artifact\.sha256' "Packer receipts the validator-owned archive digest"
assert_file_contains "$packer_file" 'validate_flapjack_ami_input\.sh' "Packer delegates install validation to validator"
assert_file_not_contains "$packer_file" 'variable "flapjack_version"' "Packer has no independent flapjack_version input"
assert_file_not_contains "$packer_file" '\$\{var\.binary_dir\}/flapjack' "Packer does not read loose flapjack from binary_dir"
assert_file_contains "$packer_file" 'flapjack_upstream_manifest_sha256' "Packer manifest custom_data receipts upstream manifest sha"
assert_file_contains "$packer_file" 'flapjack_upstream_archive_sha256' "Packer manifest custom_data receipts upstream archive sha"
assert_file_contains "$packer_file" 'flapjack_release_identifier' "Packer manifest custom_data receipts release identifier"
assert_file_not_contains "$packer_file" 's3_etag|object_version|object-version|capability|build-schema|build_schema' "Packer dependency receipt excludes upstream-owned mutable/object schema fields"

test_summary "Flapjack AMI identity static checks"
