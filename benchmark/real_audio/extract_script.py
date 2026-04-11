#!/usr/bin/env python3
"""Extract clean speech text from a wikisource wikitext."""
import re
import sys
from pathlib import Path

HERE = Path(__file__).parent

# Speech body markers per stem: (start_needle, end_needle)
MARKERS = {
    "jfk": ("Vice President Johnson", "{{PD-USGov}}"),
    "fdr": ("Mr. {{w|Henry A. Wallace", "{{PD-USGov}}"),
}

stem = sys.argv[1] if len(sys.argv) > 1 else "jfk"
if stem not in MARKERS:
    print(f"Unknown stem {stem}; known: {list(MARKERS)}", file=sys.stderr)
    sys.exit(1)

SRC = HERE / f"{stem}_raw.wiki"
OUT = HERE / f"{stem}_script.txt"

text = SRC.read_text()
start_needle, end_needle = MARKERS[stem]
start = text.find(start_needle)
end = text.find(end_needle)
if start < 0 or end < 0:
    print(f"Markers not found in {SRC}: start={start} end={end}",
          file=sys.stderr)
    sys.exit(1)
body = text[start:end]

# Strip wiki markup:
#  {{w|Link|Display}}  -> Display  (wikipedia template with display override)
#  {{w|Link}}          -> Link
#  [[Bible...|text]]   -> text
#  [[Link|text]]       -> text
#  [[Link]]            -> Link
body = re.sub(r"\{\{w\|[^}|]*\|([^}]*)\}\}", r"\1", body)
body = re.sub(r"\{\{w\|([^}]*)\}\}", r"\1", body)
body = re.sub(r"\[\[[^\]|]*\|([^\]]*)\]\]", r"\1", body)
body = re.sub(r"\[\[([^\]]*)\]\]", r"\1", body)

# Remove quote markers that wikisource uses around linked Bible quotes.
body = body.replace('"', '')

# Collapse any leftover triple+ newlines, trim.
body = re.sub(r"\n{2,}", "\n\n", body).strip()

OUT.write_text(body)
words = body.split()
print(f"Wrote {OUT.name}: {len(words)} words, {len(body)} chars")
print()
print("--- First 80 words ---")
print(" ".join(words[:80]))
