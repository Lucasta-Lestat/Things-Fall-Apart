"""Validate Dialogues.json after collapsing whitespace inside string values
(mirrors Godot's apparent leniency about raw newlines in strings)."""
import json
import re
import sys
from pathlib import Path

path = Path(__file__).resolve().parent.parent / "data" / "Dialogues.json"
text = path.read_text(encoding="utf-8")

# Match a JSON string literal (handles escaped quotes and backslashes),
# then collapse all runs of whitespace inside it to single spaces.
STRING_RE = re.compile(r'"(?:\\.|[^"\\])*"', flags=re.DOTALL)


def collapse(m):
    s = m.group(0)
    return re.sub(r"\s+", " ", s)


cleaned = STRING_RE.sub(collapse, text)
try:
    d = json.loads(cleaned)
except json.JSONDecodeError as e:
    print(f"PARSE FAILED: {e}", file=sys.stderr)
    sys.exit(1)
downtime_keys = sorted(k for k in d if k.startswith("downtime_"))
print(f"OK — {len(d)} top-level dialogues parsed.")
print(f"Downtime dialogues ({len(downtime_keys)}): {downtime_keys}")
