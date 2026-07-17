#!/usr/bin/env bash
set -euo pipefail

EXPECTED_SCHEMA_VERSION="flapjack.release.e3.v1"
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
  local schema_version artifact_file artifact_target artifact_arch artifact_profile archive_sha expected_archive_sha
  schema_version="$(json_value '.schemaVersion' "$MANIFEST_PATH")" || fail "manifest missing schemaVersion"
  [[ "$schema_version" == "$EXPECTED_SCHEMA_VERSION" ]] || fail "manifest schemaVersion must be $EXPECTED_SCHEMA_VERSION"

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
  local version revision build_id dirty
  version="$(json_value '.build.version' "$MANIFEST_PATH")" || fail "manifest missing build.version"
  revision="$(json_value '.build.producer_revision' "$MANIFEST_PATH")" || fail "manifest missing build.producer_revision"
  build_id="$(json_value '.build.build_id' "$MANIFEST_PATH")" || fail "manifest missing build.build_id"
  jq -e '.build | has("dirty")' "$MANIFEST_PATH" >/dev/null || fail "manifest missing build.dirty"
  dirty="$(jq -r '.build.dirty' "$MANIFEST_PATH")"

  [[ "$version" != "unknown" && -n "$version" ]] || fail "manifest build.version is unknown"
  [[ "$revision" != "unknown" && -n "$revision" ]] || fail "manifest build.producer_revision is unknown"
  [[ "$build_id" != "unknown" && -n "$build_id" ]] || fail "manifest build.build_id is unknown"
  [[ "$dirty" == "false" ]] || fail "manifest build.dirty must be false"
}

single_safe_archive_member() {
  local archive_list archive_details member member_type normalized
  archive_list="$(tar -tzf "$ARCHIVE_PATH")" || fail "archive member listing failed"
  [[ -n "$archive_list" ]] || fail "archive is empty"
  [[ "$(printf '%s\n' "$archive_list" | wc -l | tr -d ' ')" == "1" ]] || fail "archive must contain exactly one member"
  archive_details="$(LC_ALL=C tar -tvzf "$ARCHIVE_PATH")" || fail "archive member inspection failed"
  [[ "$(printf '%s\n' "$archive_details" | wc -l | tr -d ' ')" == "1" ]] || fail "archive must contain exactly one member"
  member_type="${archive_details:0:1}"
  [[ "$member_type" == "-" ]] || fail "archive member must be a regular file"
  member="$archive_list"
  normalized="${member#./}"
  [[ "$member" != /* ]] || fail "archive member must be relative"
  [[ "$normalized" == "flapjack" ]] || fail "archive member must be the flapjack executable"
  [[ "$member" != *".."* ]] || fail "archive member must not contain parent traversal"
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
