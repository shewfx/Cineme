"""Vercel entrypoint: Vercel looks for a FastAPI instance named `app`.

The application itself is still `app.main.build_app` (settings are validated
here, at cold start, so a misconfigured deployment fails loudly). Local
development keeps using `uvicorn app.main:build_app --factory`."""

from app.main import build_app

app = build_app()
