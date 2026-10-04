import pytest
from fastapi.testclient import TestClient

from app.main import create_app
from tests.conftest import make_settings


@pytest.mark.parametrize(
    "origin",
    ["http://localhost:53127", "http://127.0.0.1:62418"],
)
def test_flutter_web_preflight_allows_local_dynamic_origins(origin: str) -> None:
    client = TestClient(create_app(make_settings()))

    response = client.options(
        "/api/v1/me/bootstrap",
        headers={
            "Origin": origin,
            "Access-Control-Request-Method": "POST",
            "Access-Control-Request-Headers": "authorization,content-type,idempotency-key",
        },
    )

    assert response.status_code == 200
    assert response.headers["access-control-allow-origin"] == origin
    assert "access-control-allow-credentials" not in response.headers
    assert {"GET", "POST", "PATCH", "DELETE", "OPTIONS"} <= set(
        response.headers["access-control-allow-methods"].split(", ")
    )
    assert {
        "authorization",
        "content-type",
        "idempotency-key",
    } <= set(response.headers["access-control-allow-headers"].lower().split(", "))


def test_local_cors_rejects_non_local_origins() -> None:
    client = TestClient(create_app(make_settings()))

    response = client.options(
        "/api/v1/me/bootstrap",
        headers={
            "Origin": "https://attacker.example",
            "Access-Control-Request-Method": "POST",
        },
    )

    assert response.status_code == 400
    assert "access-control-allow-origin" not in response.headers


def test_production_does_not_enable_cross_origin_requests() -> None:
    settings = make_settings(
        environment="production",
        database_url="postgresql+psycopg://nobody:none@127.0.0.1:1/none?sslmode=require",
    )
    client = TestClient(create_app(settings))

    response = client.get("/healthz", headers={"Origin": "https://cineme-theta.vercel.app"})

    assert response.status_code == 200
    assert "access-control-allow-origin" not in response.headers
