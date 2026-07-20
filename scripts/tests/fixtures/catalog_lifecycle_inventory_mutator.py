#!/usr/bin/env python3
import copy
import json
import sys

SOFT_CONTRACTS = {
    "repo": (
        "catalog_writer__infra_api_src_repos_pg_customer_repo_lifecycle__soft_delete__pg_customer_repo_soft_delete",
        "infra/api/src/repos/pg_customer_repo/lifecycle.rs",
        "pg_customer_repo.soft_delete",
    ),
    "account": (
        "catalog_writer__infra_api_src_routes_account__delete_account__customer_repo_soft_delete",
        "infra/api/src/routes/account.rs",
        "customer_repo.soft_delete",
    ),
    "admin": (
        "catalog_writer__infra_api_src_routes_admin_tenants__delete_tenant__customer_repo_soft_delete",
        "infra/api/src/routes/admin/tenants.rs",
        "customer_repo.soft_delete",
    ),
}


def find_writer(payload, label):
    writer_id = SOFT_CONTRACTS[label][0]
    matches = [row for row in payload["writers"] if row["id"] == writer_id]
    if len(matches) != 1:
        raise SystemExit(f"test fixture expected exactly one {writer_id}")
    return matches[0]


def mutate(payload, mutation):
    if mutation.startswith("remove:"):
        removed_id = SOFT_CONTRACTS[mutation.split(":", 1)[1]][0]
        payload["writers"] = [
            row for row in payload["writers"] if row["id"] != removed_id
        ]
    elif mutation.startswith("duplicate:"):
        duplicate = copy.deepcopy(find_writer(payload, mutation.split(":", 1)[1]))
        duplicate["id"] = f'{duplicate["id"]}__duplicate_probe'
        payload["writers"].append(duplicate)
    elif mutation.startswith("wrong_disposition:"):
        find_writer(payload, mutation.split(":", 1)[1])[
            "disposition"
        ] = "block_without_change"
    elif mutation.startswith("wrong_owner:"):
        find_writer(payload, mutation.split(":", 1)[1])[
            "owner_path"
        ] = "infra/api/src/repos/pg_customer_repo/hard_delete.rs"
    elif mutation.startswith("wrong_anchor:"):
        find_writer(payload, mutation.split(":", 1)[1])[
            "source_anchor"
        ] = "customer_repo.hard_delete"
    elif mutation == "extra_matching_soft_delete":
        extra = copy.deepcopy(find_writer(payload, "repo"))
        extra[
            "id"
        ] = "catalog_writer__infra_api_src_repos_pg_customer_repo_lifecycle__soft_delete__duplicate_probe"
        payload["writers"].append(extra)
    else:
        raise SystemExit(f"unknown mutation {mutation}")
    payload["total_writer_count"] = len(payload["writers"])


def main():
    source, target, mutation = sys.argv[1:]
    with open(source, encoding="utf-8") as handle:
        payload = json.load(handle)
    mutate(payload, mutation)
    with open(target, "w", encoding="utf-8") as handle:
        json.dump(payload, handle)


if __name__ == "__main__":
    main()
