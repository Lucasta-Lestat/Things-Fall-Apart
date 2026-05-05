"""Rewrite icon paths in TopDownCharacters.json.

For every non-protagonist character (and skipping `jacana` whose icon is
res://Icons/jacana_icon.png and already correct), set the `icon` field to
res://Icons/{id}_icon.png. For the 5 entries with no `icon` field at all,
insert one. Preserve the file's existing tab-indented formatting by editing
the text directly rather than re-emitting JSON.
"""
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CHARACTERS_JSON = ROOT / "data" / "TopDownCharacters.json"
ICONS_DIR = ROOT / "Icons"

SKIP = {"protagonist", "jacana"}


def main():
    text = CHARACTERS_JSON.read_text(encoding="utf-8")
    data = json.loads(text)
    chars = data["characters"]

    lines = text.splitlines(keepends=True)
    # Find each character block by id, then either replace its icon line or
    # insert one after its `name` line.
    changed = 0
    inserted = 0
    for c in chars:
        cid = c["id"]
        if cid in SKIP:
            continue
        new_path = f"res://Icons/{cid}_icon.png"
        # Locate the block in the source text. We grep for the literal id
        # surrounded by quotes to avoid matching substring ids.
        id_line_re = re.compile(rf'"id":\s*"{re.escape(cid)}"')
        block_start = None
        for i, ln in enumerate(lines):
            if id_line_re.search(ln):
                block_start = i
                break
        if block_start is None:
            print(f"WARN: id {cid} not found in source")
            continue
        # The block ends just before the next CHARACTER's `"id":` line (a
        # top-level id at the same indentation as ours — not a nested item id
        # like "iron_sword" inside an equipment list, which is indented deeper).
        indent_match = re.match(r'(\s*)"id"', lines[block_start])
        char_indent = indent_match.group(1) if indent_match else ""
        next_char_id_re = re.compile(rf'^{re.escape(char_indent)}"id"\s*:')
        block_end = len(lines) - 1
        for j in range(block_start + 1, len(lines)):
            if next_char_id_re.search(lines[j]):
                block_end = j - 1
                break
        if block_end is None:
            print(f"WARN: end of {cid} block not found")
            continue

        # Look for an existing icon line in the block.
        icon_idx = None
        for j in range(block_start, block_end + 1):
            if re.search(r'"icon"\s*:', lines[j]):
                icon_idx = j
                break

        if icon_idx is not None:
            # Replace the value, preserving leading whitespace and trailing
            # comma/whitespace.
            ln = lines[icon_idx]
            new_ln = re.sub(
                r'("icon"\s*:\s*)("[^"]*")',
                lambda m: f'{m.group(1)}"{new_path}"',
                ln,
            )
            if new_ln != ln:
                lines[icon_idx] = new_ln
                changed += 1
        else:
            # No icon field — insert one after the `name` line of the block.
            name_idx = None
            for j in range(block_start, block_end + 1):
                if re.search(r'"name"\s*:', lines[j]):
                    name_idx = j
                    break
            if name_idx is None:
                print(f"WARN: cannot find name line for {cid}, skipping insert")
                continue
            # Match the indentation of the name line.
            indent_match = re.match(r"\s*", lines[name_idx])
            indent = indent_match.group(0) if indent_match else "\t\t  "
            insert_line = f'{indent}"icon": "{new_path}",\n'
            lines.insert(name_idx + 1, insert_line)
            inserted += 1

    new_text = "".join(lines)
    # Sanity: must still parse.
    json.loads(new_text)
    CHARACTERS_JSON.write_text(new_text, encoding="utf-8")
    print(f"Updated {changed} icon paths; inserted {inserted} new icon fields.")

    # Verify each character's icon file exists.
    missing = []
    re_data = json.loads(new_text)
    for c in re_data["characters"]:
        if c["id"] == "protagonist":
            continue
        p = c.get("icon", "")
        if not p.startswith("res://"):
            continue
        rel = p[len("res://"):]
        f = ROOT / rel
        if not f.exists():
            missing.append((c["id"], p, str(f)))
    if missing:
        print(f"\nMISSING ICON FILES ({len(missing)}):")
        for cid, p, fpath in missing:
            print(f"  {cid} -> {p}  ({fpath})")
    else:
        print(f"\nAll non-protagonist icons resolve to existing files.")


if __name__ == "__main__":
    main()
