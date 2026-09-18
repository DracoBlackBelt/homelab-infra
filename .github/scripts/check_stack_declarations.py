#!/usr/bin/env python3
"""Keep stacks/ and komodo/stacks.toml in step.

The ResourceSync only deploys what komodo/stacks.toml declares, resolving each
declaration's `file_paths` inside the repo. Ways to end up silently wrong:

  * a stacks/<app>/ directory with no matching [[stack]] -- never deployed;
  * a [[stack]] with no directory, or no file_paths -- dead or empty resource;
  * file_paths pointing at a missing file -- deploy fails.

None of those fail at author time, so they are checked here (and by
`make check-stacks`).
"""

from __future__ import annotations

import sys
import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
STACKS_DIR = ROOT / "stacks"
DECLARATIONS = ROOT / "komodo" / "stacks.toml"


def main() -> int:
    if not DECLARATIONS.is_file():
        print(f"missing {DECLARATIONS.relative_to(ROOT)}", file=sys.stderr)
        return 1

    declared: dict[str, list[str]] = {}
    for block in tomllib.loads(DECLARATIONS.read_text()).get("stack", []):
        name = block.get("name")
        if not name:
            print("a [[stack]] block has no name", file=sys.stderr)
            return 1
        declared[name] = (block.get("config") or {}).get("file_paths") or []

    directories = sorted(p.name for p in STACKS_DIR.iterdir() if p.is_dir())
    problems: list[str] = []

    for name in directories:
        if name not in declared:
            problems.append(
                f'stacks/{name}/ exists but komodo/stacks.toml has no [[stack]] name = "{name}"'
            )

    for name, file_paths in declared.items():
        if name not in directories:
            problems.append(f'[[stack]] "{name}" has no stacks/{name}/ directory')
        if not file_paths:
            problems.append(f'[[stack]] "{name}" declares no file_paths')
        for relative in file_paths:
            if not (ROOT / relative).is_file():
                problems.append(f'[[stack]] "{name}" points at a missing file: {relative}')

    if problems:
        print("stack declaration problems:", file=sys.stderr)
        for problem in problems:
            print(f"  - {problem}", file=sys.stderr)
        return 1

    print(f"ok: {len(declared)} declared stacks match stacks/ and their files exist")
    return 0


if __name__ == "__main__":
    sys.exit(main())
