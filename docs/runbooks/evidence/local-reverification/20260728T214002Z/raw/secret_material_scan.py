#!/usr/bin/env python3
import re
import sys
from pathlib import Path

bundle = Path(__file__).resolve().parents[1]
repo_root = bundle.parents[4]
roots = [bundle, repo_root / "ROADMAP.md"]
pattern = re.compile(
    r"sk_(?:test|live)_[A-Za-z0-9]+|"
    r"rk_(?:test|live)_[A-Za-z0-9]+|"
    r"whsec_[A-Za-z0-9]+"
)
known_false_positive_tokens = {"whsec" + "_prefix"}
violations = []
false_positive_count = 0
false_positive_locations = []
for root in roots:
    if not root.exists():
        violations.append((root, 0, "<missing_required_input>"))
        continue
    paths = (
        [root]
        if root.is_file()
        else [path for path in root.rglob("*") if path.is_file()]
    )
    for path in paths:
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except OSError as exc:
            violations.append((path, 0, f"<read_error:{exc.__class__.__name__}>"))
            continue
        for lineno, line in enumerate(text.splitlines(), start=1):
            for match in pattern.finditer(line):
                token = match.group(0)
                if token in known_false_positive_tokens:
                    false_positive_count += 1
                    false_positive_locations.append((path, lineno))
                    continue
                parts = token.split("_", 2)
                prefix = parts[0] + "_" + parts[1] + "_"
                violations.append(
                    (path, lineno, f"{prefix}<redacted:{len(token)} chars>")
                )
if violations:
    print("secret_material_scan=FAIL")
    for path, lineno, redacted in violations:
        print(f"{path}:{lineno}: {redacted}")
    sys.exit(1)
print("secret_material_scan=PASS")
print(f"known_false_positive_count={false_positive_count}")
for path, lineno in false_positive_locations:
    print(f"false_positive={path}:{lineno}:known_non_secret_test_identifier")
