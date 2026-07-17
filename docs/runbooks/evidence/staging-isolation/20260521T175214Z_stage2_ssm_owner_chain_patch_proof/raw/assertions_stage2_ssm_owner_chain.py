import json
import sys
from pathlib import Path

raw = Path(sys.argv[1])
pre = json.loads((raw / "cf_pages_project_pre_patch.json").read_text())
post = json.loads((raw / "cf_pages_project_post_patch.json").read_text())
resp = json.loads((raw / "cf_pages_patch_response.json").read_text())
pre_prev = pre["result"]["deployment_configs"]["preview"]["env_vars"]
post_prev = post["result"]["deployment_configs"]["preview"]["env_vars"]
pre_prod = pre["result"]["deployment_configs"]["production"]["env_vars"]
post_prod = post["result"]["deployment_configs"]["production"]["env_vars"]

errors = []
if not resp.get("success"):
    errors.append("PATCH response success=false")
if post_prev.get("API_BASE_URL", {}).get("value") != "https://api.staging.flapjack.foo":
    errors.append("preview API_BASE_URL not staging")
if post_prev.get("ENVIRONMENT", {}).get("value") != "staging":
    errors.append("preview ENVIRONMENT not staging")
for secret_key in ("JWT_SECRET", "ADMIN_KEY"):
    if post_prev.get(secret_key, {}).get("type") != "secret_text":
        errors.append(f"preview {secret_key} type not secret_text")
missing = sorted(set(pre_prev.keys()) - set(post_prev.keys()))
if missing:
    errors.append("preview keys lost: " + ", ".join(missing))
if pre_prod != post_prod:
    errors.append("production env_vars changed")

if errors:
    for item in errors:
        print("ASSERTION_FAIL:", item)
    raise SystemExit(1)
print("ASSERTION_PASS: preview merge + production immutability checks passed")
