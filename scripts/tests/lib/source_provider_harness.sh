#!/usr/bin/env bash
# Shared captured-state fixtures for hermetic source-provider harness tests.

write_mock_provider_capture_payloads() {
    local output_root="$1"
    mkdir -p "$output_root"
    python3 - "$FIXTURE_ROOT" "$output_root" <<'PY'
import json
import pathlib
import sys

fixture_root = pathlib.Path(sys.argv[1])
output_root = pathlib.Path(sys.argv[2])


def read_json(path):
    return json.loads(path.read_text(encoding="utf-8"))


def read_jsonl(path):
    return [
        json.loads(line)
        for line in path.read_text(encoding="utf-8").splitlines()
        if line
    ]


def write_json(name, value):
    (output_root / name).write_text(
        json.dumps(value, ensure_ascii=False),
        encoding="utf-8",
    )


meili_expected = read_json(fixture_root / "meilisearch" / "expected_bundle.json")
meili_settings = read_json(
    fixture_root / "meilisearch" / "configured_primary_key_settings.json"
)
typesense_expected = read_json(fixture_root / "typesense" / "expected_bundle.json")
typesense_products = read_jsonl(fixture_root / "typesense" / "seed_products.jsonl")
typesense_categories = read_jsonl(fixture_root / "typesense" / "seed_categories.jsonl")

before = meili_expected["documents"]["beforeMutation"]
after = meili_expected["documents"]["afterMutation"]
inferred = meili_expected["documents"]["inferred"]
indexes = meili_expected["indexes"]
write_json("meili_version_capture.json", meili_expected["source"]["version"])
write_json(
    "meili_indexes_capture.json",
    {
        "results": [
            {"uid": indexes["configured"]["uid"], "primaryKey": indexes["configured"]["primaryKey"]},
            {"uid": indexes["inferred"]["uid"], "primaryKey": indexes["inferred"]["primaryKey"]},
            {"uid": indexes["ambiguous"]["uid"], "primaryKey": indexes["ambiguous"]["primaryKey"]},
        ]
    },
)
write_json(
    "meili_configured_before_page0_capture.json",
    {"results": before[:2], "offset": 0, "limit": 2, "total": len(before)},
)
write_json(
    "meili_configured_before_page1_capture.json",
    {"results": before[2:], "offset": 2, "limit": 2, "total": len(before)},
)
write_json(
    "meili_inferred_capture.json",
    {"results": inferred, "offset": 0, "limit": 10, "total": len(inferred)},
)
write_json("meili_settings_capture.json", meili_settings)
write_json(
    "meili_configured_after_capture.json",
    {"results": after, "offset": 0, "limit": 10, "total": len(after)},
)
write_json("meili_search_capture.json", {"hits": [meili_expected["documents"]["mutation"]]})
write_json(
    "meili_stats_before_capture.json",
    {"databaseSize": meili_expected["documents"]["databaseSizeBefore"]},
)
write_json(
    "meili_stats_after_capture.json",
    {"databaseSize": meili_expected["documents"]["databaseSizeAfter"]},
)

task_uids = {
    "create_configured": 0,
    "seed_configured": 1,
    "settings_configured": 2,
    "create_inferred": 3,
    "seed_inferred": 4,
    "create_ambiguous": 5,
    "seed_ambiguous": 6,
    "mutation": 7,
    "dump": 8,
    "snapshot": 9,
}
for label, task_uid in task_uids.items():
    write_json(f"meili_response_{label}.json", {"taskUid": task_uid})

write_json("meili_task_0.json", {"uid": 0, "status": "succeeded"})
write_json("meili_task_1.json", {"uid": 1, "status": "succeeded"})
write_json("meili_task_2.json", {"uid": 2, "status": "succeeded"})
write_json("meili_task_3.json", {"uid": 3, "status": "succeeded"})
write_json("meili_task_4.json", {"uid": 4, "status": "succeeded"})
write_json("meili_task_5.json", {"uid": 5, "status": "succeeded"})
write_json(
    "meili_task_6.json",
    {
        "uid": 6,
        "status": "failed",
        "error": {"code": meili_expected["tasks"]["ambiguous"]["failureCode"]},
    },
)
write_json(
    "meili_task_7.json",
    {
        "uid": 7,
        "status": "succeeded",
        "type": meili_expected["tasks"]["mutation"]["type"],
    },
)
write_json(
    "meili_task_8.json",
    {
        "uid": 8,
        "status": "succeeded",
        "type": meili_expected["tasks"]["dump"]["type"],
    },
)
write_json(
    "meili_task_9.json",
    {
        "uid": 9,
        "status": "succeeded",
        "type": meili_expected["tasks"]["snapshot"]["type"],
    },
)

collections = {
    collection["name"]: collection
    for collection in typesense_expected["source"]["collections"]
}
for name, collection in collections.items():
    schema = {key: value for key, value in collection.items() if key != "documents"}
    write_json(f"typesense_capture_{name}_schema.json", schema)

(output_root / "typesense_capture_products_export.jsonl").write_text(
    "\n".join(json.dumps(item, ensure_ascii=False) for item in typesense_products) + "\n",
    encoding="utf-8",
)
(output_root / "typesense_capture_categories_export.jsonl").write_text(
    "\n".join(json.dumps(item, ensure_ascii=False) for item in typesense_categories) + "\n",
    encoding="utf-8",
)
write_json("typesense_capture_alias.json", typesense_expected["source"]["aliases"][0])
write_json("typesense_capture_synonym_set.json", typesense_expected["source"]["synonym_sets"][0])
write_json(
    "typesense_capture_unrelated_synonym_set.json",
    {
        "name": "outside_stage2_global_synonyms",
        "items": [
            {
                "id": "external_synonym",
                "root": "external",
                "synonyms": ["outside-regex"],
            }
        ],
    },
)
write_json("typesense_capture_curation_set.json", typesense_expected["source"]["curation_sets"][0])
write_json(
    "typesense_health_capture.json",
    typesense_expected["source"]["provider_evidence"]["health"],
)
write_json(
    "typesense_debug_capture.json",
    typesense_expected["source"]["provider_evidence"]["debug"],
)
PY
}
