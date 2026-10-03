"""Explicit, reviewable migration step for a hosted database (never run by requests).

    uv run python scripts/migrate_hosted.py            # dry run: identify + status
    uv run python scripts/migrate_hosted.py --apply    # then upgrade to head

Reads DATABASE_MIGRATION_URL (the direct, unpooled endpoint), falling back to
DATABASE_URL. Prints host, database and role but never the password.
"""

import argparse
import os
import sys
from pathlib import Path

from alembic import command
from alembic.config import Config
from alembic.script import ScriptDirectory
from sqlalchemy import create_engine, make_url, pool, text

BACKEND_DIR = Path(__file__).resolve().parents[1]
LOCAL_HOSTS = {"localhost", "127.0.0.1", "::1"}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--apply", action="store_true", help="run `alembic upgrade head`")
    parser.add_argument("--allow-local", action="store_true", help="permit a localhost target")
    args = parser.parse_args()

    raw = os.environ.get("DATABASE_MIGRATION_URL") or os.environ.get("DATABASE_URL")
    if not raw:
        print("Set DATABASE_MIGRATION_URL (or DATABASE_URL).", file=sys.stderr)
        return 2
    url = make_url(raw)
    if (url.host or "") in LOCAL_HOSTS and not args.allow_local:
        print("Target is localhost; pass --allow-local if that is intended.", file=sys.stderr)
        return 2
    if "-pooler" in (url.host or ""):
        print("Target is a pooled endpoint; migrations need the direct URL.", file=sys.stderr)
        return 2
    if (url.host or "") not in LOCAL_HOSTS and url.query.get("sslmode") not in (
        "require",
        "verify-ca",
        "verify-full",
    ):
        print("Remote target must set sslmode=require.", file=sys.stderr)
        return 2

    print(f"target   host={url.host} database={url.database} role={url.username}")
    config = Config(str(BACKEND_DIR / "alembic.ini"))
    config.set_main_option("script_location", str(BACKEND_DIR / "migrations"))
    head = ScriptDirectory.from_config(config).get_current_head()

    engine = create_engine(url, poolclass=pool.NullPool)
    with engine.connect() as conn:
        version = conn.execute(text("SELECT version()")).scalar_one()
        print(f"server   {version.split(',')[0]}")
        has_table = conn.execute(text("SELECT to_regclass('public.alembic_version')")).scalar()
        current = (
            conn.execute(text("SELECT version_num FROM alembic_version")).scalar()
            if has_table
            else None
        )
    print(f"current  {current or '(no migrations applied)'}")
    print(f"head     {head}")
    if not args.apply:
        print("dry run only; re-run with --apply to upgrade.")
        return 0

    config.attributes["database_url"] = url.render_as_string(hide_password=False)
    command.upgrade(config, "head")
    with engine.connect() as conn:
        after = conn.execute(text("SELECT version_num FROM alembic_version")).scalar()
    print(f"after    {after}")
    if after != head:
        print("Database is not at head after upgrade.", file=sys.stderr)
        return 1
    print("ok: database is at head.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
