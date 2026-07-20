#!/usr/bin/env python3
"""Remove duplicated table rows from generated DIRMAP.md files.

WHY THIS EXISTS (measured 2026-07-19)
-------------------------------------
`.gitattributes` carried `**/DIRMAP.md merge=union`. Union merge keeps the
differing lines from BOTH sides of a merge. DIRMAP summaries are LLM-authored
prose, so two branches regenerating the same DIRMAP produce different text for
the same row — and union kept every version. `infra/api/src/DIRMAP.md` accrued
the `models` row five times, each with a different summary. Measured damage:
58 files, 557 surplus rows.

Switching the merge driver stops NEW duplication but cannot heal existing
damage, because the damage is already committed content. This script is the
one-time (and repeatable) heal.

THE SUBTLE PART
---------------
A DIRMAP row is NOT a line. Summary cells contain embedded newlines:

    | assertions.sh | Shared assertions for shell test scripts.

    Callers must define:
      pass "<message>". |

A naive line-based dedupe would shred the ~197 uncorrupted files. So rows are
parsed as BLOCKS: a block opens on a line starting with '|' and absorbs every
following line until the next block, an HTML comment (the `[scrai:...]`
markers), or a markdown heading. scripts/tests/dedupe_dirmap_test.sh asserts a
clean file comes back byte-for-byte identical, which is the guard against
exactly that failure.

TIE-BREAK POLICY
----------------
Keep the FIRST occurrence of each row key. The competing summaries are all
equally plausible generated prose with no quality signal to rank them, so the
only thing that matters is that the choice is deterministic and auditable.
Accuracy is restored by regenerating from source (`matt scrai dirmap`), not by
this script — this script's job is strictly to collapse duplicates.
"""

import argparse
import sys

# A row whose first column is one of these is table furniture, not content:
# it must always be preserved and never treated as a duplicate key.
HEADER_KEYS = {"File", "Summary", "Dir", "Directory"}


def _is_block_boundary(line: str) -> bool:
    """True if `line` ends the current row block.

    Row cells may contain blank lines and indented prose, so only these three
    shapes terminate a block: the next table row, an HTML comment (the scrai
    markers wrapping generated regions), or a markdown heading.
    """
    return line.startswith("|") or line.startswith("<!--") or line.startswith("#")


def _row_key(line: str) -> str:
    """Extract the normalized first-column key from a row's opening line."""
    parts = line.split("|")
    if len(parts) < 2:
        return line.strip()
    return parts[1].strip().strip("`").strip()


def dedupe_text(text: str):
    """Return (new_text, removed_row_count) for one DIRMAP body."""
    lines = text.split("\n")
    out = []
    seen = set()
    removed = 0
    i = 0
    n = len(lines)

    while i < n:
        line = lines[i]

        # A markdown heading starts a new table scope. Keys are only duplicates
        # within the same section — two sections may legitimately list the same
        # filename.
        if line.startswith("#"):
            seen.clear()
            out.append(line)
            i += 1
            continue

        if not line.startswith("|"):
            out.append(line)
            i += 1
            continue

        # Collect the full row block: opening line plus its continuations.
        block = [line]
        j = i + 1
        while j < n and not _is_block_boundary(lines[j]):
            block.append(lines[j])
            j += 1

        # Trailing blank lines sit between the table and whatever follows; they
        # are structural, so they survive whether or not the row itself does.
        trailing = []
        while block and block[-1].strip() == "":
            trailing.insert(0, block.pop())

        key = _row_key(line)
        is_separator = bool(key) and set(key) <= set("-: ")

        if is_separator or key in HEADER_KEYS:
            out.extend(block)
            out.extend(trailing)
        elif key in seen:
            removed += 1
            out.extend(trailing)  # drop the row, keep the spacing
        else:
            seen.add(key)
            out.extend(block)
            out.extend(trailing)

        i = j

    return "\n".join(out), removed


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("paths", nargs="+", help="DIRMAP.md files to process")
    parser.add_argument(
        "--check",
        action="store_true",
        help="report duplicates and exit 1 without modifying anything",
    )
    args = parser.parse_args()

    total_removed = 0
    changed_files = 0

    for path in args.paths:
        try:
            with open(path, encoding="utf-8", errors="surrogateescape") as fh:
                original = fh.read()
        except OSError as exc:
            print(f"ERROR: cannot read {path}: {exc}", file=sys.stderr)
            return 2

        new_text, removed = dedupe_text(original)
        if removed == 0:
            continue

        total_removed += removed
        changed_files += 1
        print(f"{path}: {removed} duplicate row(s)")

        if not args.check:
            with open(path, "w", encoding="utf-8", errors="surrogateescape") as fh:
                fh.write(new_text)

    if args.check:
        if total_removed:
            print(f"FAIL: {total_removed} duplicate row(s) across {changed_files} file(s)")
            return 1
        print("OK: no duplicate DIRMAP rows")
        return 0

    print(f"removed {total_removed} duplicate row(s) across {changed_files} file(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
