# Validation Summary

Bundle: `docs/runbooks/evidence/panics-alarm/20260710T210400Z/`

HEAD at validation start: `4e1581fe0cf762187e00d7a79491a20dd10074b0`

## Passing Commands

- PASS `grep -R "AWS_ACCESS_KEY\|AWS_SECRET\|CLOUDFLARE\|STRIPE\|DATABASE_URL\|ADMIN_KEY" docs/runbooks/evidence/panics-alarm/20260710T210400Z || true`
  - Initial output before this validation summary was written: no matches; exit 0.
  - Final output after this validation summary was written: one self-match on the literal grep command above; inspected as variable names only, with no secret values present.

- PASS `git diff --check -- ROADMAP.md docs/runbooks/evidence/panics-alarm/20260710T210400Z/`
  - Output: no findings; exit 0.

- PASS evidence-shape check:

```bash
python3 - docs/runbooks/evidence/panics-alarm/20260710T210400Z <<'PY'
import json
import pathlib
import re
import sys

ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")
bundle = pathlib.Path(sys.argv[1])
required_files = ("plan.txt", "plan_show.txt", "apply.txt", "describe_alarms.json")
expected = {
    "staging": {
        "alarm": "fjcloud-staging-api-panics-high",
        "namespace": "fjcloud/api",
        "action": "arn:aws:sns:us-east-1:213880904778:fjcloud-alerts-staging",
    },
    "prod": {
        "alarm": "fjcloud-prod-api-panics-high",
        "namespace": "fjcloud/api",
        "action": "arn:aws:sns:us-east-1:213880904778:fjcloud-alerts-prod",
    },
}
for env, values in expected.items():
    env_dir = bundle / env
    gap = env_dir / "gap.md"
    missing = [name for name in required_files if not (env_dir / name).exists()]
    if missing:
        if not gap.exists():
            raise SystemExit(f"{env}: missing {missing} and no gap.md")
        continue
    plan_text = ANSI_RE.sub("", (env_dir / "plan.txt").read_text(encoding="utf-8", errors="replace"))
    apply_text = ANSI_RE.sub("", (env_dir / "apply.txt").read_text(encoding="utf-8", errors="replace"))
    if "Plan: 1 to add, 0 to change, 0 to destroy" not in plan_text:
        raise SystemExit(f"{env}: plan.txt missing exact add-only plan summary")
    if "Apply complete! Resources: 1 added, 0 changed, 0 destroyed." not in apply_text:
        raise SystemExit(f"{env}: apply.txt missing exact apply summary")
    with (env_dir / "describe_alarms.json").open(encoding="utf-8") as f:
        alarms = json.load(f)
    if not isinstance(alarms, list):
        raise SystemExit(f"{env}: describe_alarms.json is not a list")
    if not any(
        isinstance(row, list)
        and len(row) >= 3
        and row[0] == values["alarm"]
        and row[1] == values["namespace"]
        and isinstance(row[2], list)
        and values["action"] in row[2]
        for row in alarms
    ):
        raise SystemExit(f"{env}: readback missing expected alarm/namespace/action")
print("PASS evidence shape: staging and prod plan/apply/readback artifacts are valid")
PY
```

  - Output: `PASS evidence shape: staging and prod plan/apply/readback artifacts are valid`; exit 0.

- PASS `bash scripts/check_roadmap_v2_shape.sh`
  - Output: `OK: ROADMAP.md satisfies v2 shape contract (86 lines)`; exit 0.

- PASS `cd web && pnpm install --frozen-lockfile`
  - Reason: first `bash scripts/local-ci.sh --fast` run failed only because `web/node_modules` was missing.
  - Output tail: `Done in 7.6s using pnpm v11.1.2`; exit 0.

- PASS `bash scripts/local-ci.sh --fast`
  - Output summary: `Totals: pass=18 fail=0 skip=0`; `Result: PASS`; exit 0.
