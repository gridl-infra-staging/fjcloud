#!/usr/bin/env python3
import re
import sys
from html.parser import HTMLParser
from pathlib import Path


IGNORED_TAGS = {"script", "style", "noscript"}

class VisibleTextParser(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self._ignored_depth = 0
        self._parts = []

    def handle_starttag(self, tag, attrs):
        if tag.lower() in IGNORED_TAGS:
            self._ignored_depth += 1

    def handle_endtag(self, tag):
        if tag.lower() in IGNORED_TAGS and self._ignored_depth:
            self._ignored_depth -= 1

    def handle_data(self, data):
        if not self._ignored_depth:
            self._parts.append(data)
    def text(self):
        return normalize_text("\n".join(self._parts))

def normalize_text(text):
    lines = []
    for line in text.replace("\xa0", " ").splitlines():
        normalized = re.sub(r"\s+", " ", line).strip()
        if normalized:
            lines.append(normalized)
    return "\n".join(lines) + "\n"

def extract_visible_text(html):
    parser = VisibleTextParser()
    parser.feed(html)
    parser.close()
    return parser.text()

def write_visible_text(input_path, output_path):
    html = Path(input_path).read_text(encoding="utf-8", errors="replace")
    Path(output_path).write_text(extract_visible_text(html), encoding="utf-8")

def main(argv):
    if len(argv) != 3:
        print("usage: extract_pricing_evidence_text.py <input-html> <output-text>", file=sys.stderr)
        return 2
    write_visible_text(argv[1], argv[2])
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
