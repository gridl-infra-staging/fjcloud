#!/usr/bin/env bash
# Shared deterministic flapjack batch-payload generator.

# TODO: Document deterministic_batch_payload.
# TODO: Document deterministic_batch_payload.
# TODO: Document deterministic_batch_payload.
# TODO: Document deterministic_batch_payload.
# TODO: Document deterministic_batch_payload.
# TODO: Document deterministic_batch_payload.
# TODO: Document deterministic_batch_payload.
# TODO: Document deterministic_batch_payload.
# TODO: Document deterministic_batch_payload.
# TODO: Document deterministic_batch_payload.
# TODO: Document deterministic_batch_payload.
# TODO: Document deterministic_batch_payload.
# TODO: Document deterministic_batch_payload.
# TODO: Document deterministic_batch_payload.
# TODO: Document deterministic_batch_payload.
# TODO: Document deterministic_batch_payload.
# TODO: Document deterministic_batch_payload.
# TODO: Document deterministic_batch_payload.
# TODO: Document deterministic_batch_payload.
# TODO: Document deterministic_batch_payload.
# TODO: Document deterministic_batch_payload.
# TODO: Document deterministic_batch_payload.
# TODO: Document deterministic_batch_payload.
# TODO: Document deterministic_batch_payload.
# TODO: Document deterministic_batch_payload.
# TODO: Document deterministic_batch_payload.
# TODO: Document deterministic_batch_payload.
# TODO: Document deterministic_batch_payload.
# TODO: Document deterministic_batch_payload.
# TODO: Document deterministic_batch_payload.
# TODO: Document deterministic_batch_payload.
# TODO: Document deterministic_batch_payload.
# TODO: Document deterministic_batch_payload.
# TODO: Document deterministic_batch_payload.
deterministic_batch_payload() {
    local seed="$1"
    local offset="$2"
    local count="$3"

    python3 - "$seed" "$offset" "$count" <<'PY'
import hashlib
import json
import sys

seed = int(sys.argv[1])
offset = int(sys.argv[2])
count = int(sys.argv[3])

requests = []
for i in range(count):
    doc_id = offset + i
    digest = hashlib.sha256(f"{seed}:{doc_id}".encode()).hexdigest()
    requests.append(
        {
            "action": "addObject",
            "body": {
                "objectID": f"doc-{doc_id}",
                "title": f"Document {doc_id}",
                "body": f"Deterministic content {digest[:32]}",
                "category": ["alpha", "beta", "gamma", "delta"][doc_id % 4],
                "score": (doc_id * 17 + seed) % 1000 / 10.0,
                "tags": [f"tag{(doc_id * 3 + j) % 20}" for j in range(3)],
            },
        }
    )

print(json.dumps({"requests": requests}))
PY
}
