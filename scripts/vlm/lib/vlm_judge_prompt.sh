#!/usr/bin/env bash
set -euo pipefail

# Stage 1 locked model contract. Keep this literal centralized here.
readonly VLM_JUDGE_DEFAULT_MODEL="claude-sonnet-4-20250514"

build_vlm_judge_prompt() {
  local screenshot_path="$1"
  local manifesto_path="$2"
  local postmortems_path="$3"
  local screen_spec_path="$4"
  local tuple_context_path="${5:-}"
  local model="${6:-${VLM_JUDGE_DEFAULT_MODEL}}"

  python3 - "${model}" "${screenshot_path}" "${manifesto_path}" "${postmortems_path}" "${screen_spec_path}" "${tuple_context_path}" <<'PY'
import base64
import json
import os
import sys

model, screenshot_path, manifesto_path, postmortems_path, screen_spec_path, tuple_context_path = sys.argv[1:7]

with open(screenshot_path, "rb") as handle:
    screenshot_b64 = base64.b64encode(handle.read()).decode("ascii")
with open(manifesto_path, "r", encoding="utf-8") as handle:
    manifesto_text = handle.read()
with open(postmortems_path, "r", encoding="utf-8") as handle:
    postmortems_text = handle.read()
with open(screen_spec_path, "r", encoding="utf-8") as handle:
    screen_spec_text = handle.read()

tuple_context_section = ""
if tuple_context_path:
    with open(tuple_context_path, "r", encoding="utf-8") as handle:
        tuple_context_payload = json.load(handle)
    tuple_context_section = (
        "\n\nTuple context hints for this screenshot tuple:\n"
        f"{json.dumps(tuple_context_payload, sort_keys=True)}\n"
        "Use these registry-owned cues as hints for expected text and icon evidence."
    )

prompt_text = (
    "Evaluate the attached Uff screen screenshot against the three reference docs.\n"
    f"Screenshot: {os.path.basename(screenshot_path)}\n\n"
    f"Anchor: {manifesto_path}\n{manifesto_text}\n\n"
    f"Anchor: {postmortems_path}\n{postmortems_text}\n\n"
    f"Anchor: {screen_spec_path}\n{screen_spec_text}\n\n"
    f"{tuple_context_section}\n\n"
    "Return JSON only (no prose, no code fences) with keys: screen, score, "
    "verdict, summary, violations, actions. "
    "verdict must be exactly one of: pass, fail, advisory. "
    "Use \"pass\" when the screen meets every product-fit anchor with no "
    "blocking violations. "
    "Use \"fail\" when at least one violation contradicts the manifesto, a "
    "postmortem rule, or the screen spec's State contract or Visual defaults "
    "audit. "
    "Use \"advisory\" when violations are present but none are blocking — for "
    "example, low-severity polish notes. "
    "Each entry in \"violations\" must include \"rule_id\" set to the exact M.* "
    "or P.* anchor from the provided manifesto/postmortem docs. If no specific "
    "anchor applies, set \"rule_id\" to null and explain the issue in "
    "\"description\". Do not invent IDs."
)

payload = {
    "model": model,
    "max_tokens": 1024,
    "messages": [
        {
            "role": "user",
            "content": [
                {
                    "type": "image",
                    "source": {
                        "type": "base64",
                        "media_type": "image/png",
                        "data": screenshot_b64,
                    },
                },
                {"type": "text", "text": prompt_text},
            ],
        }
    ],
}

json.dump(payload, sys.stdout, separators=(",", ":"))
print()
PY
}

extract_vlm_judgment_json() {
  local anthropic_response_json="$1"
  local judgment_json=""

  # The model frequently wraps JSON output in ``` or ```json code fences even
  # when instructed to return JSON only. Strip an optional fenced block before
  # parsing so the extractor accepts both fenced and bare JSON.
  judgment_json="$(
    printf '%s' "${anthropic_response_json}" | jq -cer '
      ([.content[]? | select(.type == "text") | .text] | first) as $raw
      | if $raw == null then
          error("missing required judgment fields")
        else
          ($raw
            | sub("^[[:space:]]*```(json)?[[:space:]]*"; "")
            | sub("[[:space:]]*```[[:space:]]*$"; "")
          ) | fromjson
        end
    ' 2>/dev/null
  )" || {
    printf '%s\n' "missing required judgment fields" >&2
    return 1
  }

  if ! printf '%s' "${judgment_json}" | jq -e '
    has("screen")
    and (.screen | type == "string" and length > 0)
    and has("score")
    and (.score | type == "number")
    and has("verdict")
    and (.verdict | type == "string" and (. == "pass" or . == "fail" or . == "advisory"))
    and has("summary")
    and (.summary | type == "string" and length > 0)
    and has("violations")
    and (.violations | type == "array")
    and has("actions")
    and (.actions | type == "array")
  ' >/dev/null; then
    printf '%s\n' "missing required judgment fields" >&2
    return 1
  fi

  printf '%s\n' "${judgment_json}"
}
