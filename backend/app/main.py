import logging

from fastapi import FastAPI

from app.core.settings import Settings, load_settings


def create_app(settings: Settings) -> FastAPI:
    logging.basicConfig(level=settings.log_level)
    docs_enabled = settings.environment != "production"
    app = FastAPI(
        title="Cinemé API",
        docs_url="/docs" if docs_enabled else None,
        redoc_url=None,
        openapi_url="/openapi.json" if docs_enabled else None,
    )

    @app.get("/healthz")
    def healthz() -> dict[str, str]:
        return {"status": "ok"}

    return app


app = create_app(load_settings())
