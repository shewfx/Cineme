"""Fail if a built Flutter web bundle contains anything that must stay server-side.

    python infra/check_web_bundle.py frontend/build/web

Everything compiled into the bundle is public. The publishable Supabase key
(`sb_publishable_...`) is allowed; secrets, database URLs and any JWT-shaped
token (a TMDB read token, or a legacy/service-role Supabase key) are not.
"""

import re
import sys
from pathlib import Path

FORBIDDEN = {
    "Supabase secret key": re.compile(rb"sb_secret_[A-Za-z0-9_-]{8,}"),
    "service_role reference": re.compile(rb"service_role"),
    "database URL with credentials": re.compile(
        rb"postgres(?:ql)?(?:\+\w+)?://[^\s:/@\"']+:[^\s@\"']+@"
    ),
    "JWT-shaped token": re.compile(rb"eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}"),
    "backend-only setting name": re.compile(rb"TMDB_READ_ACCESS_TOKEN|DATABASE_(?:MIGRATION_)?URL"),
}
SKIP_SUFFIXES = {".wasm", ".png", ".ttf", ".otf", ".symbols"}


def main(root: Path) -> int:
    if not root.is_dir():
        print(f"not a directory: {root}", file=sys.stderr)
        return 2
    problems: list[str] = []
    scanned = 0
    for path in sorted(root.rglob("*")):
        if not path.is_file() or path.suffix in SKIP_SUFFIXES:
            continue
        scanned += 1
        data = path.read_bytes()
        problems += [
            f"{path.relative_to(root)}: {label}"
            for label, pattern in FORBIDDEN.items()
            if pattern.search(data)
        ]
    print(f"scanned {scanned} files under {root}")
    if problems:
        print("\n".join(problems), file=sys.stderr)
        return 1
    print("ok: no server-side secrets found")
    return 0


if __name__ == "__main__":
    sys.exit(main(Path(sys.argv[1] if len(sys.argv) > 1 else "frontend/build/web")))