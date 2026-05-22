import json
import sys
from pathlib import Path

raw = Path(sys.argv[1])
pre = json.loads((raw / "cf_pages_project_pre_patch.json").read_text())
post = json.loads((raw / "cf_pages_project_post_patch.json").read_text())
pre_prev = pre["result"]["deployment_configs"]["preview"]["env_vars"]
post_prev = post["result"]["deployment_configs"]["preview"]["env_vars"]
pre_prod = pre["result"]["deployment_configs"]["production"]["env_vars"]
post_prod = post["result"]["deployment_configs"]["production"]["env_vars"]

errors = []
if post_prev.get("API_BASE_URL", {}).get("value") != "https://api.staging.flapjack.foo":
    errors.append("preview API_BASE_URL was not updated to staging")
if post_prev.get("API_BASE_URL", {}).get("type") != "plain_text":
    errors.append("preview API_BASE_URL type changed from plain_text")
if post_prev.get("ENVIRONMENT", {}).get("value") != "staging":
    errors.append("preview ENVIRONMENT is not staging")
if post_prev.get("ENVIRONMENT", {}).get("type") != "plain_text":
    errors.append("preview ENVIRONMENT type changed from plain_text")
for secret_key in ("JWT_SECRET", "ADMIN_KEY"):
    if post_prev.get(secret_key, {}).get("type") != "secret_text":
        errors.append(f"preview {secret_key} type is not secret_text")

missing_keys = sorted(set(pre_prev.keys()) - set(post_prev.keys()))
if missing_keys:
    errors.append("preview keys lost after patch: " + ", ".join(missing_keys))

for k in pre_prev.keys() & post_prev.keys():
    pre_t = pre_prev[k].get("type")
    post_t = post_prev[k].get("type")
    if pre_t != post_t and k not in {"API_BASE_URL", "ENVIRONMENT"}:
        errors.append(f"preview key {k} type changed unexpectedly: {pre_t} -> {post_t}")

if pre_prod != post_prod:
    errors.append("production env_vars changed during preview-only patch")

if errors:
    for e in errors:
        print(f"ASSERTION_FAIL: {e}")
    raise SystemExit(1)
print("ASSERTION_PASS: preview merge and production immutability checks passed")
