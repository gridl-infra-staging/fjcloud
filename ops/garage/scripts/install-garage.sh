#!/usr/bin/env bash
# install-garage.sh — Install Garage object storage as a systemd service
#
# Downloads a pinned Garage binary with SHA256 verification, creates the
# garage system user and data directories, installs the systemd unit +
# sysctl config, and reloads systemd.
#
# Usage: install-garage.sh
#
# Prerequisites:
#   - Root access (sudo)
#   - curl installed
#   - Internet access to garagehq.deuxfleurs.fr

set -euo pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

GARAGE_VERSION="${GARAGE_VERSION:-2.2.0}"
GARAGE_URL="${GARAGE_URL:-https://garagehq.deuxfleurs.fr/_releases/v${GARAGE_VERSION}/x86_64-unknown-linux-musl/garage}"
GARAGE_SHA256="${GARAGE_SHA256:-ec761bb996e8453e86fe68ccc1cf222c73bb1ef05ae0b540bd4827e7d1931aab}"
GARAGE_BIN="${GARAGE_BIN:-/usr/local/bin/garage}"

GARAGE_USER="${GARAGE_USER:-garage}"
GARAGE_GROUP="${GARAGE_GROUP:-garage}"

META_DIR="${META_DIR:-/var/lib/garage/meta}"
DATA_DIR="${DATA_DIR:-/var/lib/garage/data}"
CONF_DIR="${CONF_DIR:-/etc/garage}"
UNIT_DEST="${UNIT_DEST:-/etc/systemd/system/garage.service}"
SYSCTL_DEST="${SYSCTL_DEST:-/etc/sysctl.d/99-garage.conf}"
GROUP_FILE="${GROUP_FILE:-/etc/group}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

TAG="garage-install"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

require_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script must be run as root"
    return 1
  fi
}

require_command() {
  local command_name="$1"

  if ! command -v "$command_name" &>/dev/null; then
    echo "ERROR: ${command_name} is required but not installed"
    return 1
  fi
}

group_exists() {
  getent group "$GARAGE_GROUP" &>/dev/null || grep -q "^${GARAGE_GROUP}:" "$GROUP_FILE" 2>/dev/null
}

ensure_garage_account() {
  local primary_group

  if ! group_exists; then
    groupadd --system "$GARAGE_GROUP"
    logger -t "$TAG" "Created system group: ${GARAGE_GROUP}"
  fi

  if ! id "$GARAGE_USER" &>/dev/null; then
    useradd --system --gid "$GARAGE_GROUP" --shell /usr/sbin/nologin --home-dir /var/lib/garage "$GARAGE_USER"
    logger -t "$TAG" "Created system user: ${GARAGE_USER}"
    return 0
  fi

  primary_group="$(id -gn "$GARAGE_USER")"
  if [[ "$primary_group" != "$GARAGE_GROUP" ]]; then
    echo "ERROR: Existing user ${GARAGE_USER} uses primary group ${primary_group}, expected ${GARAGE_GROUP}"
    return 1
  fi

  logger -t "$TAG" "System user ${GARAGE_USER} already exists"
}

preflight_checks() {
  require_root
  require_command curl
  require_command groupadd
  require_command openssl
  require_command sha256sum
  require_command systemctl
  require_command useradd
}

download_and_install_binary() {
  local tmpbin actual_sha256

  logger -t "$TAG" "Downloading Garage v${GARAGE_VERSION} binary"

  tmpbin="$(mktemp)"
  trap 'rm -f "$tmpbin"' RETURN

  curl -fsSL -o "$tmpbin" "$GARAGE_URL"

  actual_sha256="$(sha256sum "$tmpbin" | awk '{print $1}')"
  if [[ "$actual_sha256" != "$GARAGE_SHA256" ]]; then
    logger -t "$TAG" "ERROR: SHA256 mismatch — expected ${GARAGE_SHA256}, got ${actual_sha256}"
    echo "ERROR: SHA256 verification failed"
    echo "  Expected: ${GARAGE_SHA256}"
    echo "  Got:      ${actual_sha256}"
    return 1
  fi

  logger -t "$TAG" "SHA256 verified: ${GARAGE_SHA256}"

  install -m 0755 "$tmpbin" "$GARAGE_BIN"
  logger -t "$TAG" "Installed binary to ${GARAGE_BIN}"
}

prepare_storage_directories() {
  local fs_type

  mkdir -p "$META_DIR" "$DATA_DIR" "$CONF_DIR"
  chown "${GARAGE_USER}:${GARAGE_GROUP}" "$META_DIR" "$DATA_DIR"
  chmod 0750 "$META_DIR" "$DATA_DIR"
  logger -t "$TAG" "Created directories: ${META_DIR}, ${DATA_DIR}, ${CONF_DIR}"

  if command -v stat &>/dev/null; then
    fs_type="$(stat -f -c '%T' "$DATA_DIR" 2>/dev/null || echo "unknown")"
    if [[ "$fs_type" != "xfs" && "$fs_type" != "unknown" ]]; then
      logger -t "$TAG" "WARNING: ${DATA_DIR} is on ${fs_type}, not XFS. XFS is recommended for production (ext4 inode limits)."
      echo "WARNING: ${DATA_DIR} is on ${fs_type}. XFS is recommended for production."
    fi
  fi
}

escape_sed_replacement() {
  printf '%s' "$1" | sed -e 's/[&|]/\\&/g'
}

replace_template_placeholder() {
  local placeholder="$1"
  local replacement="$2"
  local target_file="$3"
  local escaped_replacement rendered_file

  escaped_replacement="$(escape_sed_replacement "$replacement")"
  rendered_file="$(mktemp "${target_file}.render.XXXXXX")"
  trap 'rm -f "$rendered_file"' RETURN

  sed "s|${placeholder}|${escaped_replacement}|g" "$target_file" > "$rendered_file"
  mv "$rendered_file" "$target_file"
  trap - RETURN
}

install_config_template() {
  local rpc_secret admin_token toml_dest template_src tmp_toml

  toml_dest="${CONF_DIR}/garage.toml"
  if [[ ! -f "$toml_dest" ]]; then
    template_src="${OPS_DIR}/garage.toml.template"
    if [[ -f "$template_src" ]]; then
      tmp_toml="$(mktemp "${CONF_DIR}/garage.toml.tmp.XXXXXX")"
      trap 'rm -f "$tmp_toml"' RETURN
      cat "$template_src" > "$tmp_toml"

      if grep -q '%%GARAGE_RPC_SECRET%%' "$tmp_toml"; then
        rpc_secret="$(openssl rand -hex 32)"
        replace_template_placeholder '%%GARAGE_RPC_SECRET%%' "$rpc_secret" "$tmp_toml"
      fi
      if grep -q '%%GARAGE_ADMIN_TOKEN%%' "$tmp_toml"; then
        admin_token="$(openssl rand -base64 32)"
        replace_template_placeholder '%%GARAGE_ADMIN_TOKEN%%' "$admin_token" "$tmp_toml"
      fi
      replace_template_placeholder '%%GARAGE_META_DIR%%' "$META_DIR" "$tmp_toml"
      replace_template_placeholder '%%GARAGE_DATA_DIR%%' "$DATA_DIR" "$tmp_toml"
      chown root:"${GARAGE_GROUP}" "$tmp_toml"
      chmod 0640 "$tmp_toml"
      mv "$tmp_toml" "$toml_dest"
      trap - RETURN
      logger -t "$TAG" "Installed config from template to ${toml_dest}"
    else
      logger -t "$TAG" "WARNING: No config template found at ${OPS_DIR}/garage.toml.template — create ${toml_dest} manually"
    fi
  else
    logger -t "$TAG" "Config already exists at ${toml_dest}, skipping"
  fi

  printf '%s' "$toml_dest"
}

install_systemd_unit() {
  local unit_src

  unit_src="${OPS_DIR}/garage.service"
  if [[ -f "$unit_src" ]]; then
    install -m 0644 "$unit_src" "$UNIT_DEST"
    logger -t "$TAG" "Installed systemd unit to ${UNIT_DEST}"
    return 0
  fi

  echo "ERROR: systemd unit not found at ${unit_src}"
  return 1
}

install_sysctl_config() {
  local sysctl_src

  sysctl_src="${OPS_DIR}/sysctl-garage.conf"
  if [[ -f "$sysctl_src" ]]; then
    install -m 0644 "$sysctl_src" "$SYSCTL_DEST"
    sysctl --system --quiet 2>/dev/null || true
    logger -t "$TAG" "Installed sysctl config to ${SYSCTL_DEST}"
  else
    logger -t "$TAG" "WARNING: sysctl config not found at ${sysctl_src}, skipping"
  fi
}

enable_garage_service() {
  systemctl daemon-reload
  systemctl enable garage.service
  logger -t "$TAG" "Garage v${GARAGE_VERSION} installation complete. Start with: systemctl start garage"
}

print_install_summary() {
  local toml_dest="$1"

  echo ""
  echo "Garage v${GARAGE_VERSION} installed successfully."
  echo ""
  echo "Next steps:"
  echo "  1. Review config:    ${toml_dest}"
  echo "  2. Start service:    sudo systemctl start garage"
  echo "  3. Initialize:       sudo ops/garage/scripts/init-cluster.sh"
}

main() {
  local toml_dest

  # ---------------------------------------------------------------------------
  # 1. Preflight checks
  # ---------------------------------------------------------------------------

  logger -t "$TAG" "Starting Garage v${GARAGE_VERSION} installation"

  preflight_checks

  # ---------------------------------------------------------------------------
  # 2. Download and verify binary
  # ---------------------------------------------------------------------------

  download_and_install_binary

  # ---------------------------------------------------------------------------
  # 3. Create system user
  # ---------------------------------------------------------------------------

  ensure_garage_account

  # ---------------------------------------------------------------------------
  # 4. Create data directories
  # ---------------------------------------------------------------------------

  prepare_storage_directories

  # ---------------------------------------------------------------------------
  # 5. Install config template (if no config exists)
  # ---------------------------------------------------------------------------

  toml_dest="$(install_config_template)"

  # ---------------------------------------------------------------------------
  # 6. Install systemd unit
  # ---------------------------------------------------------------------------

  install_systemd_unit

  # ---------------------------------------------------------------------------
  # 7. Install sysctl config
  # ---------------------------------------------------------------------------

  install_sysctl_config

  # ---------------------------------------------------------------------------
  # 8. Reload systemd and enable service
  # ---------------------------------------------------------------------------

  enable_garage_service
  print_install_summary "$toml_dest"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
