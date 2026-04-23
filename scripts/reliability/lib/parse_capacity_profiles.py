#!/usr/bin/env python3
"""
Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/scripts/reliability/lib/parse_capacity_profiles.py.
"""

import json
import re
import sys


def parse_profile_block(rust_src: str, label: str) -> dict[str, int]:
    pattern = rf"pub const {label}:\s*ResourceVector\s*=\s*ResourceVector\s*\{{(.*?)\}};"
    match = re.search(pattern, rust_src, re.DOTALL)
    if not match:
        raise RuntimeError(f"missing const block: {label}")
    block = match.group(1)

    def extract_u64(field: str) -> int:
        field_match = re.search(rf"{field}:\s*([\d_]+)", block)
        if not field_match:
            raise RuntimeError(f"missing field {field} in {label}")
        return int(field_match.group(1).replace("_", ""))

    return {
        "mem_rss_bytes": extract_u64("mem_rss_bytes"),
        "disk_bytes": extract_u64("disk_bytes"),
    }


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: parse_capacity_profiles.py <capacity_profiles.rs>", file=sys.stderr)
        return 2

    path = sys.argv[1]
    try:
        with open(path, encoding="utf-8") as source_file:
            rust_src = source_file.read()
    except OSError as exc:
        print(f"error reading {path}: {exc}", file=sys.stderr)
        return 1

    try:
        parsed = {
            "1k": parse_profile_block(rust_src, "PROFILE_1K"),
            "10k": parse_profile_block(rust_src, "PROFILE_10K"),
            "100k": parse_profile_block(rust_src, "PROFILE_100K"),
        }
    except RuntimeError as exc:
        print(str(exc), file=sys.stderr)
        return 1

    print(json.dumps(parsed))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
