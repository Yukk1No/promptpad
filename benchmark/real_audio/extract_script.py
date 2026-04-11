#!/usr/bin/env python3
"""Extract clean speech text from the JFK wikisource wikitext."""
import re
from pathlib import Path

HERE = Path(__file__).parent
SRC = HERE / "jfk_raw.wiki"
OUT = HERE / "jfk_script.txt"

text = SRC.read_text()

# Speech body: lines 16..70 in the raw wiki. Easier to bound by markers.
start = text.find("Vice President Johnson")
end = text.find("{{PD-USGov}}")
body = text[start:end]

# Strip wiki markup:
#  [[Bible...|text]]  -> text
#  [[Link|text]]      -> text
#  [[Link]]           -> Link
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
