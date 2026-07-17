#!/usr/bin/env bash
# Probe seeded demo template image URLs for malformed, placeholder, and unreachable values.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

MOVIES_JSON_PATH="${FJCLOUD_DEMO_MOVIES_JSON:-$REPO_ROOT/web/src/lib/search_templates/movies.json}"
PRODUCTS_JSON_PATH="${FJCLOUD_DEMO_PRODUCTS_JSON:-$REPO_ROOT/web/src/lib/search_templates/products.json}"

image_rows="$(
    python3 - "$MOVIES_JSON_PATH" "$PRODUCTS_JSON_PATH" <<'PY'
import json
import sys
from pathlib import Path
from urllib.parse import urlparse

bad_hosts = {"example.com", "placeholder.com"}
bad_owner_paths = {
    "image.tmdb.org/placeholder",
    "images.example.com/placeholder",
}
seen = set()

for template_name, raw_path in (("movies", sys.argv[1]), ("products", sys.argv[2])):
    path = Path(raw_path)
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except Exception as exc:
        raise SystemExit(f"{template_name}: failed to read JSON from {path}: {exc}")
    if not isinstance(payload, list):
        raise SystemExit(f"{template_name}: expected top-level JSON array in {path}")

    for index, document in enumerate(payload):
        if not isinstance(document, dict):
            continue
        image = document.get("image")
        if image in (None, ""):
            continue
        if not isinstance(image, str):
            raise SystemExit(f"{template_name}[{index}]: image must be a string")
        parsed = urlparse(image)
        if parsed.scheme != "https" or not parsed.netloc:
            raise SystemExit(f"{template_name}[{index}]: image must be an absolute HTTPS URL: {image}")
        hostname = (parsed.hostname or "").lower()
        path_segments = [segment for segment in parsed.path.split("/") if segment]
        owner_path = f"{hostname}{parsed.path}"
        if (
            hostname in bad_hosts
            or any(hostname.endswith(f".{bad_host}") for bad_host in bad_hosts)
            or any(owner_path.startswith(bad_owner_path) for bad_owner_path in bad_owner_paths)
            or "placeholder" in path_segments
        ):
            raise SystemExit(f"{template_name}[{index}]: image uses placeholder/example URL: {image}")
        if image in seen:
            continue
        seen.add(image)
        print(f"{template_name}\t{image}")
PY
)"

if [[ -z "$image_rows" ]]; then
    echo "No demo template image URLs found." >&2
    exit 1
fi

checked_count=0
while IFS=$'\t' read -r template_name url; do
    [[ -n "$url" ]] || continue
    if ! curl -fsSL --retry 2 --max-time 20 --range 0-0 "$url" >/dev/null; then
        echo "Image URL probe failed for ${template_name}: ${url}" >&2
        exit 1
    fi
    checked_count=$((checked_count + 1))
done <<< "$image_rows"

echo "Checked $checked_count unique demo template image URLs."
