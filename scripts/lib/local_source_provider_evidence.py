#!/usr/bin/env python3
"""Build normalized source-provider evidence from captured provider state."""

import hashlib
import json
import pathlib
import sys


def read_json(path):
    return json.loads(pathlib.Path(path).read_text(encoding="utf-8"))


def read_jsonl(path):
    return [
        json.loads(line)
        for line in pathlib.Path(path).read_text(encoding="utf-8").splitlines()
        if line
    ]


def write_json(path, value):
    pathlib.Path(path).write_text(
        json.dumps(value, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )


def require_json(path):
    payload = read_json(path)
    if payload is None:
        raise ValueError(f"{path} must contain JSON content")
    return payload


def response_items(payload):
    if isinstance(payload, list):
        return payload
    for key in ("results", "hits", "documents"):
        value = payload.get(key)
        if isinstance(value, list):
            return value
    raise ValueError(f"unsupported response payload shape: {payload!r}")


def canonical_hash(documents):
    canonical = json.dumps(
        sorted(documents, key=lambda item: item["sku"]),
        ensure_ascii=False,
        separators=(",", ":"),
        sort_keys=True,
    )
    return hashlib.sha256((canonical + "\n").encode()).hexdigest()


def field_distribution(documents):
    distribution = {}
    for document in documents:
        for field in document:
            distribution[field] = distribution.get(field, 0) + 1
    return dict(sorted(distribution.items()))


def normalized_settings(settings, expected):
    typo_tolerance = settings["typoTolerance"]
    typo_tolerance["disableOnWords"] = [
        value.lower() for value in typo_tolerance["disableOnWords"]
    ]
    typo_tolerance["disableOnNumbers"] = False
    for key in ("embedders", "localizedAttributes", "facetSearch"):
        settings[key] = expected[key]
    return settings


def normalized_field(field):
    field_type = field["type"]
    sortable_by_default = (
        not field_type.endswith("[]")
        and field_type.startswith(("int", "float", "bool"))
    )
    result = {
        "name": field["name"],
        "type": field_type,
        "facet": field.get("facet", False),
        "optional": field.get("optional", False),
        "index": field.get("index", True),
        "store": field.get("store", True),
        "sort": field.get(
            "sort",
            sortable_by_default,
        ),
    }
    for key in ("num_dim", "vec_dist", "reference"):
        if key in field:
            result[key] = field[key]
    return result


def normalized_document(document, fields):
    stored_fields = {
        field["name"]
        for field in fields
        if field.get("store", True)
    }
    return {
        key: value
        for key, value in document.items()
        if value is not None and key in stored_fields | {"id"}
    }


def meili_task(runtime, label):
    response = require_json(runtime / f"meili_response_{label}.json")
    task_uid = response["taskUid"]
    task = require_json(runtime / f"meili_task_{task_uid}.json")
    return {
        "uid": task_uid,
        "status": task["status"],
        "type": task.get("type"),
        "failureCode": (task.get("error") or {}).get("code"),
    }


def meili_primary_keys(indexes):
    mapping = {}
    for item in indexes:
        mapping[item["uid"]] = item.get("primaryKey")
    return mapping


def mutation_from_documents(before, after):
    before_by_sku = {item["sku"]: item for item in before}
    additions = [item for item in after if before_by_sku.get(item["sku"]) != item]
    if len(additions) != 1:
        raise ValueError(f"expected exactly one Meilisearch mutation document, got {additions!r}")
    return additions[0]


def meili_verify_search(runtime, mutation):
    hits = response_items(require_json(runtime / "meili_search_capture.json"))
    if mutation["sku"] not in {item.get("sku") for item in hits}:
        raise ValueError("Meilisearch search capture did not surface the mutation document")


def write_meilisearch_evidence(expected_path, runtime_path, output_path):
    runtime = pathlib.Path(runtime_path)
    evidence = require_json(expected_path)
    indexes = response_items(require_json(runtime / "meili_indexes_capture.json"))
    before = sorted(
        response_items(require_json(runtime / "meili_configured_before_page0_capture.json"))
        + response_items(require_json(runtime / "meili_configured_before_page1_capture.json")),
        key=lambda item: item["sku"],
    )
    after = sorted(
        response_items(require_json(runtime / "meili_configured_after_capture.json")),
        key=lambda item: item["sku"],
    )
    inferred = sorted(
        response_items(require_json(runtime / "meili_inferred_capture.json")),
        key=lambda item: item["book_id"],
    )
    mutation = mutation_from_documents(before, after)
    meili_verify_search(runtime, mutation)
    expected_primary_keys = meili_primary_keys(indexes)
    version = require_json(runtime / "meili_version_capture.json")
    before_page_zero = require_json(runtime / "meili_configured_before_page0_capture.json")
    before_page_one = require_json(runtime / "meili_configured_before_page1_capture.json")
    stats_before = require_json(runtime / "meili_stats_before_capture.json")
    stats_after = require_json(runtime / "meili_stats_after_capture.json")
    ambiguous_task = meili_task(runtime, "seed_ambiguous")
    mutation_task = meili_task(runtime, "mutation")
    dump_task = meili_task(runtime, "dump")
    snapshot_task = meili_task(runtime, "snapshot")

    evidence["source"]["version"] = version
    evidence["indexes"]["configured"]["primaryKey"] = expected_primary_keys["configured_pk"]
    evidence["indexes"]["inferred"]["primaryKey"] = expected_primary_keys["inferred_pk"]
    evidence["indexes"]["ambiguous"]["primaryKey"] = expected_primary_keys["ambiguous_pk"]
    evidence["expectedPrimaryKeys"] = expected_primary_keys
    evidence["documents"].update(
        {
            "beforeMutation": before,
            "mutation": mutation,
            "afterMutation": after,
            "inferred": inferred,
            "stableIds": sorted(item["sku"] for item in before),
            "countBefore": len(before),
            "countAfter": len(after),
            "hashBefore": canonical_hash(before),
            "hashAfter": canonical_hash(after),
            "databaseSizeBefore": stats_before["databaseSize"],
            "databaseSizeAfter": stats_after["databaseSize"],
            "fieldDistributionBefore": field_distribution(before),
            "fieldDistributionAfter": field_distribution(after),
        }
    )
    evidence["settings"] = normalized_settings(
        require_json(runtime / "meili_settings_capture.json"),
        evidence["settings"],
    )
    evidence["synonyms"] = evidence["settings"]["synonyms"]
    evidence["tasks"]["ambiguous"] = {
        "uid": ambiguous_task["uid"],
        "status": ambiguous_task["status"],
        "failureCode": ambiguous_task["failureCode"],
    }
    evidence["tasks"]["mutation"] = {
        "uid": mutation_task["uid"],
        "status": mutation_task["status"],
        "type": mutation_task["type"],
    }
    evidence["tasks"]["dump"] = {
        "uid": dump_task["uid"],
        "status": dump_task["status"],
        "type": dump_task["type"],
    }
    evidence["tasks"]["snapshot"] = {
        "uid": snapshot_task["uid"],
        "status": snapshot_task["status"],
        "type": snapshot_task["type"],
    }
    evidence["pagination"]["total"] = before_page_zero["total"]
    evidence["pagination"]["pageCounts"] = [
        len(response_items(before_page_zero)),
        len(response_items(before_page_one)),
    ]
    write_json(output_path, evidence)


def normalized_collection(schema, documents):
    fields = [normalized_field(field) for field in schema["fields"]]
    return {
        "name": schema["name"],
        "documentCount": schema["num_documents"],
        "default_sorting_field": schema.get("default_sorting_field", ""),
        "enable_nested_fields": schema.get("enable_nested_fields", False),
        "token_separators": schema.get("token_separators", []),
        "symbols_to_index": schema.get("symbols_to_index", []),
        "synonym_sets": schema.get("synonym_sets", []),
        "curation_sets": schema.get("curation_sets", []),
        "fields": fields,
        "documents": sorted(
            (normalized_document(document, fields) for document in documents),
            key=lambda item: item["id"],
        ),
    }


def write_typesense_evidence(expected_path, runtime_path, output_path):
    evidence = require_json(expected_path)
    runtime = pathlib.Path(runtime_path)
    documents_by_collection = {
        "fj_ts_migration_products": read_jsonl(runtime / "typesense_capture_products_export.jsonl"),
        "fj_ts_migration_categories": read_jsonl(runtime / "typesense_capture_categories_export.jsonl"),
    }
    collections = []
    for schema_path in sorted(runtime.glob("typesense_capture_*_schema.json")):
        schema = require_json(schema_path)
        collections.append(
            normalized_collection(schema, documents_by_collection[schema["name"]])
        )
    evidence["source"]["collections"] = sorted(
        collections,
        key=lambda collection: collection["name"],
    )
    evidence["source"]["aliases"] = [require_json(runtime / "typesense_capture_alias.json")]
    evidence["source"]["synonym_sets"] = [require_json(runtime / "typesense_capture_synonym_set.json")]
    evidence["source"]["curation_sets"] = [require_json(runtime / "typesense_capture_curation_set.json")]
    evidence["source"]["provider_evidence"]["health"] = require_json(
        runtime / "typesense_health_capture.json"
    )
    evidence["source"]["provider_evidence"]["debug"] = require_json(
        runtime / "typesense_debug_capture.json"
    )
    unrelated_synonym_set = require_json(runtime / "typesense_capture_unrelated_synonym_set.json")
    evidence["source"]["provider_evidence"]["global_resource_visibility"] = {
        "unrelated_synonym_set": unrelated_synonym_set["name"],
        "visible_to_capture_key": True,
        "returned_synonym_set_names": sorted(
            [
                evidence["source"]["synonym_sets"][0]["name"],
                unrelated_synonym_set["name"],
            ]
        ),
    }
    write_json(output_path, evidence)


def main():
    if len(sys.argv) != 6:
        raise SystemExit("expected meili expected/output, typesense expected/output, and runtime dir")
    meili_expected, meili_output, typesense_expected, typesense_output, runtime_dir = sys.argv[1:]
    write_meilisearch_evidence(meili_expected, runtime_dir, meili_output)
    write_typesense_evidence(typesense_expected, runtime_dir, typesense_output)


if __name__ == "__main__":
    main()
