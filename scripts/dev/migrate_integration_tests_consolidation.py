#!/usr/bin/env python3

from __future__ import annotations

import re
import subprocess
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
TESTS_DIR = REPO_ROOT / "infra" / "api" / "tests"
INTEGRATION_DIR = TESTS_DIR / "integration"
GENERATED_ROOTS = {
    "auth_admin.rs",
    "billing.rs",
    "indexes.rs",
    "platform.rs",
}

TOP_LEVEL_COMMON_BLOCK = re.compile(
    r"(?m)^#\[path\s*=\s*\"common/mod.rs\"\]\s*\nmod\s+common;\s*\n"
)
TOP_LEVEL_COMMON_SIMPLE = re.compile(r"(?m)^mod\s+common;\s*\n")
TOP_LEVEL_INTEGRATION_HELPERS = re.compile(
    r"(?m)^#\[path\s*=\s*\"common/integration_helpers.rs\"\]\s*\nmod\s+integration_helpers;\s*\n"
)


def rewrite_source(text: str) -> str:
    rewritten = TOP_LEVEL_COMMON_BLOCK.sub("", text, count=1)
    rewritten = TOP_LEVEL_COMMON_SIMPLE.sub("", rewritten, count=1)
    rewritten = TOP_LEVEL_INTEGRATION_HELPERS.sub("", rewritten, count=1)

    rewritten = re.sub(r"(?<!crate::)\bcommon::", "crate::common::", rewritten)
    rewritten = re.sub(
        r"(?<!crate::common::)\bintegration_helpers::",
        "crate::common::integration_helpers::",
        rewritten,
    )
    return rewritten


def move_with_git(src: Path, dst: Path) -> None:
    dst.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["git", "mv", str(src), str(dst)], check=True, cwd=REPO_ROOT)


def migrate() -> None:
    INTEGRATION_DIR.mkdir(parents=True, exist_ok=True)

    top_level_rs = sorted(
        p
        for p in TESTS_DIR.glob("*.rs")
        if p.name not in GENERATED_ROOTS
    )

    for source_file in top_level_rs:
        original = source_file.read_text(encoding="utf-8")
        rewritten = rewrite_source(original)
        if rewritten != original:
            source_file.write_text(rewritten, encoding="utf-8")

    for source_file in top_level_rs:
        destination_file = INTEGRATION_DIR / source_file.name
        move_with_git(source_file, destination_file)

    print(
        f"migrated {len(top_level_rs)} files from {TESTS_DIR} to {INTEGRATION_DIR}"
    )


if __name__ == "__main__":
    migrate()
