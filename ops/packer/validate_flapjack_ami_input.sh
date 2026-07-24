#!/usr/bin/env bash
set -euo pipefail

EXPECTED_SCHEMA_VERSION=1
EXPECTED_TARGET="aarch64-unknown-linux-musl"
EXPECTED_ARCH="aarch64"
EXPECTED_PROFILE="release"

usage() {
  cat <<USAGE
Usage: validate_flapjack_ami_input.sh --manifest <manifest.json> --archive <archive.tar.gz> --out <flapjack>

Validates the selected upstream Flapjack E3 release manifest/archive pair and
extracts the single flapjack executable to --out.
USAGE
}

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

require_command() {
  local command_name="$1"
  command -v "$command_name" >/dev/null 2>&1 || fail "missing required command: $command_name"
}

sha256_file() {
  local file="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print $1}'
  else
    shasum -a 256 "$file" | awk '{print $1}'
  fi
}

json_value() {
  local filter="$1"
  local file="$2"
  jq -er "$filter" "$file"
}

validate_args() {
  MANIFEST_PATH=""
  ARCHIVE_PATH=""
  OUTPUT_PATH=""
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --manifest)
        [[ "$#" -ge 2 ]] || return 1
        MANIFEST_PATH="$2"
        shift 2
        ;;
      --archive)
        [[ "$#" -ge 2 ]] || return 1
        ARCHIVE_PATH="$2"
        shift 2
        ;;
      --out)
        [[ "$#" -ge 2 ]] || return 1
        OUTPUT_PATH="$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        return 1
        ;;
    esac
  done
  [[ -n "$MANIFEST_PATH" && -n "$ARCHIVE_PATH" && -n "$OUTPUT_PATH" ]]
}

validate_manifest_json() {
  jq -e . "$MANIFEST_PATH" >/dev/null || fail "manifest is not valid JSON: $MANIFEST_PATH"
}

validate_manifest_envelope() {
  local artifact_file artifact_target artifact_arch artifact_profile archive_sha expected_archive_sha
  jq -e --argjson expected "$EXPECTED_SCHEMA_VERSION" '.schemaVersion == $expected' "$MANIFEST_PATH" >/dev/null \
    || fail "manifest schemaVersion must be numeric $EXPECTED_SCHEMA_VERSION"

  artifact_file="$(json_value '.artifact.file' "$MANIFEST_PATH")" || fail "manifest missing artifact.file"
  artifact_target="$(json_value '.artifact.target' "$MANIFEST_PATH")" || fail "manifest missing artifact.target"
  artifact_arch="$(json_value '.artifact.arch' "$MANIFEST_PATH")" || fail "manifest missing artifact.arch"
  artifact_profile="$(json_value '.artifact.profile' "$MANIFEST_PATH")" || fail "manifest missing artifact.profile"
  expected_archive_sha="$(json_value '.artifact.sha256' "$MANIFEST_PATH")" || fail "manifest missing artifact.sha256"
  archive_sha="$(sha256_file "$ARCHIVE_PATH")"

  [[ "$artifact_file" == "$(basename "$ARCHIVE_PATH")" ]] || fail "manifest artifact.file does not name selected archive"
  [[ "$artifact_target" == "$EXPECTED_TARGET" ]] || fail "manifest artifact.target must be $EXPECTED_TARGET"
  [[ "$artifact_arch" == "$EXPECTED_ARCH" ]] || fail "manifest artifact.arch must be $EXPECTED_ARCH"
  [[ "$artifact_profile" == "$EXPECTED_PROFILE" ]] || fail "manifest artifact.profile must be $EXPECTED_PROFILE"
  [[ "$expected_archive_sha" == "$archive_sha" ]] || fail "archive sha256 does not match manifest artifact.sha256"
}

validate_release_identity() {
  local version revision revision_known workspace_digest dirty build_schema build_profile build_target
  build_schema="$(json_value '.build.schemaVersion' "$MANIFEST_PATH")" || fail "manifest missing build.schemaVersion"
  version="$(json_value '.build.version' "$MANIFEST_PATH")" || fail "manifest missing build.version"
  revision="$(json_value '.build.revision' "$MANIFEST_PATH")" || fail "manifest missing build.revision"
  revision_known="$(json_value '.build.revisionKnown' "$MANIFEST_PATH")" || fail "manifest missing build.revisionKnown"
  workspace_digest="$(json_value '.build.workspaceDigest' "$MANIFEST_PATH")" || fail "manifest missing build.workspaceDigest"
  build_profile="$(json_value '.build.profile' "$MANIFEST_PATH")" || fail "manifest missing build.profile"
  build_target="$(json_value '.build.target' "$MANIFEST_PATH")" || fail "manifest missing build.target"
  jq -e '.build | has("dirty") and has("dirtyKnown")' "$MANIFEST_PATH" >/dev/null \
    || fail "manifest missing build dirty-state fields"
  jq -e '
    .build
    | (.dirtyKnown == true and (.dirty | type) == "boolean")
      or (.dirtyKnown == false and .dirty == null)
  ' "$MANIFEST_PATH" >/dev/null \
    || fail "manifest build dirty-state fields are inconsistent"
  dirty="$(jq -r '.build.dirty' "$MANIFEST_PATH")"

  [[ "$build_schema" == "$EXPECTED_SCHEMA_VERSION" ]] || fail "manifest build.schemaVersion must be $EXPECTED_SCHEMA_VERSION"
  [[ "$version" != "unknown" && -n "$version" ]] || fail "manifest build.version is unknown"
  [[ "$revision_known" == "true" ]] || fail "manifest build.revisionKnown must be true"
  [[ "$revision" =~ ^[0-9a-f]{40}$ ]] || fail "manifest build.revision must be 40 lowercase hexadecimal characters"
  [[ "$workspace_digest" =~ ^[0-9a-f]{64}$ ]] || fail "manifest build.workspaceDigest must be 64 lowercase hexadecimal characters"
  [[ "$build_profile" == "$EXPECTED_PROFILE" ]] || fail "manifest build.profile must be $EXPECTED_PROFILE"
  [[ "$build_target" == "$EXPECTED_TARGET" ]] || fail "manifest build.target must be $EXPECTED_TARGET"
  [[ "$dirty" != "true" ]] || fail "manifest build.dirty must not be true"
}

single_safe_archive_member() {
  local archive_list candidate member="" member_count=0
  archive_list="$(tar -tzf "$ARCHIVE_PATH")" || fail "archive member listing failed"
  [[ -n "$archive_list" ]] || fail "archive is empty"

  while IFS= read -r candidate; do
    case "$candidate" in
      .|./)
        ;;
      flapjack|./flapjack)
        member="$candidate"
        member_count=$((member_count + 1))
        ;;
      *)
        fail "archive may contain only its root directory and the flapjack executable"
        ;;
    esac
  done <<<"$archive_list"

  [[ "$member_count" == "1" ]] || fail "archive must contain exactly one flapjack executable"
  printf '%s\n' "$member"
}

extract_flapjack() {
  local member="$1"
  local tmp_dir extracted
  tmp_dir="$(mktemp -d)"
  tar -xzf "$ARCHIVE_PATH" -C "$tmp_dir" "$member" || fail "archive extraction failed"
  extracted="$tmp_dir/${member#./}"
  [[ ! -L "$extracted" ]] || fail "archive member must not be a symbolic link"
  [[ -f "$extracted" ]] || fail "archive did not extract flapjack executable"
  [[ -x "$extracted" ]] || fail "flapjack executable bit is not set"
  validate_build_info_matches_manifest "$extracted"
  cp "$extracted" "$OUTPUT_PATH"
  chmod 0755 "$OUTPUT_PATH"
  rm -rf "$tmp_dir"
}

validate_build_info_matches_manifest() {
  local binary_path="$1"
  local manifest_build binary_build
  manifest_build="$(jq -S -c '.build' "$MANIFEST_PATH")" || fail "manifest build object is invalid"
  binary_build="$("$binary_path" build-info --json | jq -S -c '.')" || fail "flapjack build-info --json failed"
  [[ "$manifest_build" == "$binary_build" ]] || fail "flapjack build-info --json does not match manifest .build"
}

main() {
  if ! validate_args "$@"; then
    usage >&2
    exit 64
  fi

  require_command jq
  require_command tar
  require_command mktemp
  [[ -f "$MANIFEST_PATH" ]] || fail "manifest file not found: $MANIFEST_PATH"
  [[ -f "$ARCHIVE_PATH" ]] || fail "archive file not found: $ARCHIVE_PATH"

  validate_manifest_json
  validate_manifest_envelope
  validate_release_identity
  extract_flapjack "$(single_safe_archive_member)"

  jq -n \
    --arg manifest_sha256 "$(sha256_file "$MANIFEST_PATH")" \
    --arg archive_sha256 "$(sha256_file "$ARCHIVE_PATH")" \
    --arg release_identifier "$(json_value '.build.version' "$MANIFEST_PATH")" \
    '{manifest_sha256: $manifest_sha256, archive_sha256: $archive_sha256, release_identifier: $release_identifier}'
}

main "$@"
