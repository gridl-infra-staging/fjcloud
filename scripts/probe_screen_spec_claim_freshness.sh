#!/usr/bin/env bash
# Shadow-mode classifier for screen-spec claim freshness and repo-local doc links.

set -uo pipefail

usage() {
    echo "usage: probe_screen_spec_claim_freshness.sh [--repo-root <directory>]" >&2
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

case "$#" in
    0)
        ;;
    2)
        if [ "${1:-}" != "--repo-root" ] || [ -z "${2:-}" ]; then
            usage
            exit 2
        fi
        REPO_ROOT="$2"
        ;;
    *)
        usage
        exit 2
        ;;
esac

# bash 3.2 — the macOS system bash this repo runs on — mis-parses backticks inside a
# heredoc nested in $( ). The python below uses backticks to strip markdown code
# fences, so write its output to a temp file instead of a command substitution.
classification_out="$(mktemp)"
python3 - "$REPO_ROOT" <<'PY' > "$classification_out"
from __future__ import annotations

import os
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import unquote, urlparse


TAB_ROOT = Path("web/src/routes/console/indexes/[name]/tabs")
INDEX_DETAIL_ROOT = Path("web/src/routes/console/indexes/[name]")
SPEC_SKIP = {"README.md", "_template.md", "coverage.md"}
MARKDOWN_ROOT_FILES = ("LAUNCH.md", "ROADMAP.md", "PROJECT_OVERVIEW.md", "README.md")
PATH_EXTENSIONS = {
    ".md",
    ".rs",
    ".ts",
    ".tsx",
    ".svelte",
    ".js",
    ".mjs",
    ".json",
    ".txt",
    ".log",
    ".sh",
    ".py",
    ".yml",
    ".yaml",
}
LOCAL_PATH_PREFIXES = (
    "docs/",
    "infra/",
    "migrations/",
    "ops/",
    "scripts/",
    "tests/",
    "web/",
    ".github/",
)


@dataclass(frozen=True)
class ClaimDiagnostic:
    source: str
    class_name: str
    result: str
    target: str
    tokens: tuple[str, ...]
    reason: str


@dataclass(frozen=True)
class LinkDiagnostic:
    source: str
    raw_target: str
    resolved_target: str
    class_name: str


def fail(message: str) -> None:
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(2)


def is_relative_to(path: Path, parent: Path) -> bool:
    try:
        path.relative_to(parent)
        return True
    except ValueError:
        return False


def safe_rel(path: Path, repo_root: Path) -> str:
    try:
        return path.resolve().relative_to(repo_root.resolve()).as_posix()
    except ValueError:
        return path.as_posix()


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="replace")


def strip_line_suffix(value: str) -> str:
    return re.sub(r":[0-9]+(?:-[0-9]+)?(?:,[0-9]+(?:-[0-9]+)?)*$", "", value)


def token_candidates(raw: str) -> tuple[str, ...]:
    cleaned = raw.strip().strip("`").strip()
    if not cleaned:
        return ()
    parts = re.split(r"\s*(?:\||/|,|\band\b|\bor\b)\s*", cleaned)
    tokens = []
    for part in parts:
        token = part.strip().strip("`'\" ")
        if not token:
            continue
        if re.fullmatch(r"[A-Za-z0-9_?+./ -]+", token):
            tokens.append(token)
    return tuple(tokens)


def evidence_clause(line: str) -> str | None:
    marker = "Evidence:"
    if marker not in line:
        return None
    return line.split(marker, 1)[1].strip()


def is_path_like(value: str) -> bool:
    value = strip_line_suffix(value.strip().strip("`"))
    if not value or value.startswith(("http://", "https://", "flapjack_dev/")):
        return False
    if not value.startswith(LOCAL_PATH_PREFIXES):
        return False
    if value.endswith("/"):
        return "/" in value
    suffix = Path(value).suffix
    return "/" in value and suffix in PATH_EXTENSIONS


def backtick_values(text: str) -> list[str]:
    return [match.group(1) for match in re.finditer(r"`([^`]+)`", text)]


def bare_owner_path(value: str) -> Path | None:
    value = strip_line_suffix(value.strip().strip("`"))
    if value == "+page.server.ts":
        return INDEX_DETAIL_ROOT / value
    if re.fullmatch(r"[A-Za-z0-9_.-]+Tab\.svelte", value):
        return TAB_ROOT / value
    if re.fullmatch(r"[A-Za-z0-9_.-]+Tab\.test\.ts", value):
        return TAB_ROOT / value
    if re.fullmatch(r"[A-Za-z0-9_.-]+\.server\.ts", value):
        return INDEX_DETAIL_ROOT / value
    return None


def resolve_claim_target(repo_root: Path, value: str) -> Path | None:
    value = strip_line_suffix(value.strip().strip("`"))
    bare = bare_owner_path(value)
    if bare is not None:
        candidate = (repo_root / bare).resolve()
        return candidate if is_relative_to(candidate, repo_root.resolve()) else None
    if is_path_like(value):
        candidate = (repo_root / value).resolve()
        return candidate if is_relative_to(candidate, repo_root.resolve()) else None
    return None


def claim_target_escapes_repo(repo_root: Path, value: str) -> bool:
    value = strip_line_suffix(value.strip().strip("`"))
    bare = bare_owner_path(value)
    if bare is not None:
        candidate = (repo_root / bare).resolve()
    elif is_path_like(value):
        candidate = (repo_root / value).resolve()
    else:
        return False
    return not is_relative_to(candidate, repo_root.resolve())


def path_exists_for_claim(path: Path) -> bool:
    return path.exists()


def text_for_target(path: Path) -> str:
    if path.is_file():
        return read_text(path)
    if path.is_dir():
        names = []
        for child in path.iterdir():
            names.append(child.name)
        return "\n".join(sorted(names))
    return ""


def contains_token(text: str, token: str) -> bool:
    return token.casefold() in text.casefold()


def absence_tokens(clause: str, previous_line: str) -> tuple[str, ...]:
    tokens: list[str] = []
    combined = f"{clause} {previous_line}"
    match = re.search(
        r"no matches? for (?P<body>.+?)(?:\s+in\s+`[^`]+`|\);|;|$)",
        combined,
        flags=re.I,
    )
    if match:
        body = match.group("body")
        raw_tokens = backtick_values(body) or [body]
        for raw in raw_tokens:
            tokens.extend(token_candidates(raw))
    for filename in re.findall(
        r"\bno\s+([A-Za-z0-9_.-]+)\.spec\.ts\s+file\b",
        combined,
        flags=re.I,
    ):
        tokens.append(filename)
    if re.search(r"\bno `?setInterval`?\b|never auto-polls", combined, re.I):
        tokens.append("setInterval")
    return tuple(dict.fromkeys(tokens))


def target_values_for_claim(clause: str) -> list[str]:
    values = []
    for value in backtick_values(clause):
        if is_path_like(value) or bare_owner_path(value) is not None:
            values.append(value)
    return values


def dead_claim_diagnostics(
    source: str,
    missing_targets: list[tuple[str, Path]],
    repo_root: Path,
) -> list[ClaimDiagnostic]:
    return [
        ClaimDiagnostic(
            source,
            "dead-path",
            "dead_claim_path",
            raw,
            (),
            f"missing target {safe_rel(path, repo_root)}",
        )
        for raw, path in missing_targets
    ]


def absence_claim_diagnostics(
    source: str,
    local_targets: list[tuple[str, Path]],
    tokens: tuple[str, ...],
) -> list[ClaimDiagnostic]:
    diagnostics = []
    for raw, path in local_targets:
        target_text = text_for_target(path)
        for token in tokens:
            present = contains_token(target_text, token)
            diagnostics.append(
                ClaimDiagnostic(
                    source,
                    "recheckable-absence",
                    "contradicted" if present else "holds",
                    raw,
                    (token,),
                    "unexpected token present" if present else "absence predicate still holds",
                )
            )
    return diagnostics


def presence_tokens(clause: str) -> tuple[str, ...]:
    values = re.findall(r"\(\s*`([^`]+)`\s*\)", clause)
    if len(values) != 1:
        return ()
    value = values[0]
    if is_path_like(value) or bare_owner_path(value) is not None:
        return ()
    return token_candidates(value)


def presence_claim_diagnostics(
    source: str,
    local_targets: list[tuple[str, Path]],
    tokens: tuple[str, ...],
) -> list[ClaimDiagnostic]:
    if not tokens:
        return [
            ClaimDiagnostic(
                source,
                "recheckable-presence",
                "holds",
                raw,
                (),
                "target exists",
            )
            for raw, _path in local_targets
        ]

    diagnostics = []
    for raw, path in local_targets:
        target_text = text_for_target(path)
        for token in tokens:
            present = contains_token(target_text, token)
            diagnostics.append(
                ClaimDiagnostic(
                    source,
                    "recheckable-presence",
                    "holds" if present else "contradicted",
                    raw,
                    (token,),
                    "expected token present" if present else "expected token absent",
                )
            )
    return diagnostics


def classify_claim(repo_root: Path, rel_path: Path, line_no: int, line: str, previous_line: str) -> list[ClaimDiagnostic]:
    clause = evidence_clause(line)
    if clause is None:
        return []
    source = f"{rel_path.as_posix()}:{line_no}"
    targets_raw = target_values_for_claim(clause)
    escaped_targets = [raw for raw in targets_raw if claim_target_escapes_repo(repo_root, raw)]
    if escaped_targets:
        return [
            ClaimDiagnostic(
                source,
                "dead-path",
                "dead_claim_path",
                raw,
                (),
                "target escapes repo root",
            )
            for raw in escaped_targets
        ]
    targets = [(raw, resolve_claim_target(repo_root, raw)) for raw in targets_raw]
    local_targets = [(raw, path) for raw, path in targets if path is not None]
    missing_targets = [(raw, path) for raw, path in local_targets if not path_exists_for_claim(path)]

    absence = bool(re.search(r"\bno matches?\b|\bno [A-Za-z0-9_.-]+\.spec\.ts file\b|\bno `?setInterval`?\b|never auto-polls", clause + " " + previous_line, re.I))
    if missing_targets:
        return dead_claim_diagnostics(source, missing_targets, repo_root)
    if not local_targets:
        return [
            ClaimDiagnostic(
                source,
                "prose",
                "unparsed",
                "-",
                (),
                "no deterministic repo-local claim target",
            )
        ]

    if absence:
        tokens = absence_tokens(clause, previous_line)
        if not tokens and re.search(r"\bno `?setInterval`?\b|never auto-polls", previous_line, re.I):
            tokens = ("setInterval",)
        if not tokens:
            return [
                ClaimDiagnostic(source, "prose", "unparsed", "-", (), "absence claim has no explicit token")
            ]
        return absence_claim_diagnostics(source, local_targets, tokens)

    tokens = presence_tokens(clause) if len(local_targets) == 1 else ()
    return presence_claim_diagnostics(source, local_targets, tokens)


def legacy_direct_claims(repo_root: Path, rel_path: Path, lines: list[str]) -> list[ClaimDiagnostic]:
    if rel_path.name != "events.md":
        return []
    diagnostics: list[ClaimDiagnostic] = []
    for index, line in enumerate(lines, start=1):
        if not re.search(r"\bno `?setInterval`?\b|never auto-polls", line, re.I):
            continue
        raw = "web/src/routes/console/indexes/[name]/tabs/EventsTab.svelte"
        target = repo_root / raw
        if not target.exists():
            diagnostics.append(
                ClaimDiagnostic(
                    f"{rel_path.as_posix()}:{index}",
                    "dead-path",
                    "dead_claim_path",
                    raw,
                    (),
                    f"missing target {raw}",
                )
            )
            continue
        present = "setInterval" in read_text(target)
        diagnostics.append(
            ClaimDiagnostic(
                f"{rel_path.as_posix()}:{index}",
                "recheckable-absence",
                "contradicted" if present else "holds",
                raw,
                ("setInterval",),
                "legacy direct citation auto-poll control",
            )
        )
    return diagnostics


def markdown_sources(repo_root: Path) -> list[Path]:
    paths: list[Path] = []
    docs = repo_root / "docs"
    if docs.is_dir():
        paths.extend(sorted(docs.rglob("*.md")))
    for rel in MARKDOWN_ROOT_FILES:
        path = repo_root / rel
        if path.is_file():
            paths.append(path)
    return paths


def markdown_link_targets(line: str) -> list[str]:
    link_pattern = re.compile(
        r"""(?<!!)\[[^\]]*\]\(\s*((?:<[^>]*>|\S+?)(?:\s+(?:"[^"]*"|'[^']*'|\([^)]*\)))?)\s*\)"""
    )
    return [match.group(1).strip() for match in link_pattern.finditer(line)]


def markdown_link_destination(raw_target: str) -> str | None:
    match = re.fullmatch(
        r"""(?P<destination><[^>]*>|\S+)(?:\s+(?:"[^"]*"|'[^']*'|\([^)]*\)))?""",
        raw_target.strip(),
    )
    if match is None:
        return None
    destination = match.group("destination")
    if destination.startswith("<") and destination.endswith(">"):
        return destination[1:-1]
    return destination


def classify_link(repo_root: Path, md_path: Path, line_no: int, raw_target: str) -> LinkDiagnostic | None:
    raw = markdown_link_destination(raw_target)
    if raw is None:
        return None
    parsed = urlparse(raw)
    if parsed.scheme in {"http", "https", "mailto"} or raw.startswith("#") or not raw:
        return None
    no_fragment = raw.split("#", 1)[0]
    if not no_fragment:
        return None
    no_fragment = unquote(no_fragment)
    candidate = Path(no_fragment)
    if candidate.is_absolute():
        return None
    resolved = (md_path.parent / candidate).resolve()
    if not is_relative_to(resolved, repo_root.resolve()):
        return None
    rel = safe_rel(resolved, repo_root)
    if resolved.exists():
        class_name = "clean"
    elif rel.startswith("docs/runbooks/evidence/"):
        class_name = "missing_evidence"
    else:
        class_name = "moved_pointer"
    return LinkDiagnostic(
        f"{safe_rel(md_path, repo_root)}:{line_no}",
        raw_target,
        rel,
        class_name,
    )


def collect_claim_diagnostics(
    repo_root: Path,
    spec_files: list[Path],
) -> tuple[int, list[ClaimDiagnostic]]:
    evidence_lines = 0
    claim_diagnostics: list[ClaimDiagnostic] = []
    for spec_path in spec_files:
        rel_path = spec_path.relative_to(repo_root)
        lines = read_text(spec_path).splitlines()
        previous = ""
        for line_no, line in enumerate(lines, start=1):
            if "Evidence:" in line:
                evidence_lines += 1
                claim_diagnostics.extend(
                    classify_claim(repo_root, rel_path, line_no, line, previous)
                )
            previous = line
        claim_diagnostics.extend(legacy_direct_claims(repo_root, rel_path, lines))
    return evidence_lines, claim_diagnostics


def collect_link_diagnostics(
    repo_root: Path,
    markdown_paths: list[Path],
) -> list[LinkDiagnostic]:
    links: list[LinkDiagnostic] = []
    for md_path in markdown_paths:
        for line_no, line in enumerate(read_text(md_path).splitlines(), start=1):
            for raw_target in markdown_link_targets(line):
                diagnostic = classify_link(repo_root, md_path, line_no, raw_target)
                if diagnostic is not None:
                    links.append(diagnostic)
    return links


def print_claim_diagnostics(claim_diagnostics: list[ClaimDiagnostic]) -> None:
    for diagnostic in claim_diagnostics:
        token_text = "|".join(diagnostic.tokens) if diagnostic.tokens else "-"
        prefix = "WARN" if diagnostic.result in {"contradicted", "dead_claim_path", "unparsed"} else "CLAIM"
        print(
            f"{prefix}: {diagnostic.source} class={diagnostic.class_name} "
            f"result={diagnostic.result} target={diagnostic.target} "
            f"tokens={token_text} reason={diagnostic.reason}"
        )


def print_link_diagnostics(links: list[LinkDiagnostic]) -> None:
    for diagnostic in links:
        prefix = "LINK" if diagnostic.class_name == "clean" else "WARN"
        print(
            f"{prefix}: {diagnostic.source} class={diagnostic.class_name} "
            f"raw_target={diagnostic.raw_target} resolved_target={diagnostic.resolved_target}"
        )


def print_summary(
    evidence_lines: int,
    claim_diagnostics: list[ClaimDiagnostic],
    links: list[LinkDiagnostic],
    markdown_file_count: int,
) -> None:
    recheckable = [d for d in claim_diagnostics if d.class_name.startswith("recheckable-")]
    contradictions = [d for d in claim_diagnostics if d.result == "contradicted"]
    dead_claim_paths = [d for d in claim_diagnostics if d.result == "dead_claim_path"]
    unparsed = [d for d in claim_diagnostics if d.result == "unparsed"]
    holds = [d for d in claim_diagnostics if d.result == "holds"]
    clean_links = [d for d in links if d.class_name == "clean"]
    missing_evidence = [d for d in links if d.class_name == "missing_evidence"]
    moved_pointers = [d for d in links if d.class_name == "moved_pointer"]

    print("markdown_roots=docs/**/*.md,LAUNCH.md,ROADMAP.md,PROJECT_OVERVIEW.md,README.md")
    print(f"markdown_files_scanned={markdown_file_count}")
    print(f"screen_spec_evidence_lines={evidence_lines}")
    print(f"screen_spec_recheckable_lines={len({d.source for d in recheckable})}")
    print(f"screen_spec_atomic_predicates={len(recheckable)}")
    print(f"screen_spec_holds={len(holds)}")
    print(f"screen_spec_contradictions={len(contradictions)}")
    print(f"screen_spec_unparsed_lines={len({d.source for d in unparsed})}")
    print(f"screen_spec_dead_claim_paths={len(dead_claim_paths)}")
    print(f"links_total={len(links)}")
    print(f"links_clean={len(clean_links)}")
    print(f"links_dead={len(moved_pointers) + len(missing_evidence)}")
    print(f"ordinary_dead_links={len(moved_pointers)}")
    print(f"missing_evidence_links={len(missing_evidence)}")
    print("OK: screen-spec freshness probe completed in shadow mode")


def main() -> int:
    repo_root = Path(sys.argv[1]).resolve()
    if not repo_root.is_dir() or not os.access(repo_root, os.R_OK | os.X_OK):
        fail("repo root is not a readable directory")
    specs_dir = repo_root / "docs" / "screen_specs"
    if not specs_dir.is_dir():
        fail("docs/screen_specs is not present")

    spec_files = [path for path in sorted(specs_dir.glob("*.md")) if path.name not in SPEC_SKIP]
    if not spec_files:
        fail("screen-spec corpus is empty")

    evidence_lines, claim_diagnostics = collect_claim_diagnostics(repo_root, spec_files)
    if evidence_lines == 0:
        fail("screen-spec evidence corpus is empty")
    recheckable = [d for d in claim_diagnostics if d.class_name.startswith("recheckable-")]
    if not recheckable:
        fail("zero parsed recheckable screen-spec claims")

    markdown_paths = markdown_sources(repo_root)
    links = collect_link_diagnostics(repo_root, markdown_paths)
    print_claim_diagnostics(claim_diagnostics)
    print_link_diagnostics(links)
    print_summary(evidence_lines, claim_diagnostics, links, len(markdown_paths))

    dead_claim_paths = [d for d in claim_diagnostics if d.result == "dead_claim_path"]
    if dead_claim_paths:
        fail("screen-spec claim target resolution failed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
PY
status=$?
classification="$(cat "$classification_out")"
rm -f "$classification_out"
printf '%s\n' "$classification"
exit "$status"
