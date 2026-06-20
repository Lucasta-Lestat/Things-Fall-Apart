"""DEPRECATED shim — kept so existing docs/commands keep working.

The Male Elf slicer has been generalized into scripts/extract_body_parts.py, which
is driven by scripts/body_slice_config.json (one entry per race, with optional
green-cutline auto-derivation). Male Elf's config pins every cut coordinate
explicitly, so this still produces byte-identical output to the original script.

Run the generalized tool directly instead:
    python extract_body_parts.py "Male Elf"      # this race
    python extract_body_parts.py                 # every configured race
"""
from extract_body_parts import load_config, process_race


def main() -> None:
    process_race("Male Elf", load_config()["Male Elf"])


if __name__ == "__main__":
    main()
