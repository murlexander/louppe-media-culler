#!/usr/bin/env python3
"""Check literal L10n calls, including nested Swift interpolation, against English.

Dynamic L10n.label identities are covered by catalog/token and model tests.
This reads source only; it never changes catalogs or stored identifiers.
Raw or multiline Swift literals fail explicitly until the scanner supports them.
"""
import json
import pathlib
import re
import subprocess


def read_swift_string(source: str, position: int) -> tuple[str, int]:
    if source.startswith('"""', position):
        raise ValueError("multiline L10n literal needs scanner support")
    assert source[position] == '"'
    position += 1
    output = ""
    slot = 0
    while position < len(source):
        character = source[position]
        if character == '"':
            return output, position + 1
        if character == "\\":
            position += 1
            if source[position] == "(":
                depth = 1
                position += 1
                # Skip the expression, including nested strings and calls.
                while depth:
                    if source[position] == '"':
                        _, position = read_swift_string(source, position)
                        continue
                    if source[position] == "(":
                        depth += 1
                    if source[position] == ")":
                        depth -= 1
                    position += 1
                output += "{" + str(slot) + "}"
                slot += 1
                continue
            output += {"n": "\n", "t": "\t", "r": "\r"}.get(source[position], source[position])
        else:
            output += character
        position += 1
    raise ValueError("unterminated L10n literal")


def main() -> int:
    root = pathlib.Path(__file__).resolve().parents[1] / "Sources/Louppe"
    catalog = set(json.loads(subprocess.check_output([
        "/usr/bin/plutil", "-convert", "json", "-o", "-",
        str(root / "Resources/en.lproj/Localizable.strings"),
    ], text=True)))
    missing = []
    count = 0
    for path in sorted(root.rglob("*.swift")):
        source = path.read_text()
        for match in re.finditer(r'L10n\.(?:text|label)\(\s*(#*")', source):
            line = source[:match.start()].count("\n") + 1
            try:
                if match.group(1).startswith("#"):
                    raise ValueError("raw L10n literal needs scanner support")
                key, _ = read_swift_string(source, match.end() - 1)
            except (ValueError, IndexError) as error:
                missing.append((path.relative_to(root), line, str(error)))
                continue
            count += 1
            if key not in catalog:
                missing.append((path.relative_to(root), line, key))
    print(f"Checked {count} literal L10n callsites; missing/unsupported: {len(missing)}")
    for path, line, key in missing:
        print(f"{path}:{line}: {key}")
    return int(bool(missing))


if __name__ == "__main__":
    raise SystemExit(main())
