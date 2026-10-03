from fastapi.testclient import TestClient

from app.main import create_app
from tests.conftest import make_settings


def client(**overrides: str) -> TestClient:
    return TestClient(create_app(make_settings(**overrides)))


def test_healthz_returns_ok_without_a_database() -> None:
    response = client().get("/healthz")

    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


def test_readyz_is_503_when_the_database_is_unreachable() -> None:
    response = client().get("/readyz")

    assert response.status_code == 503
    assert response.json() == {"status": "not_ready"}


def test_production_hides_api_docs() -> None:
    c = client(
        environment="production",
        database_url="postgresql+psycopg://nobody:none@127.0.0.1:1/none?sslmode=require",
    )

    assert c.get("/docs").status_code == 404
    assert c.get("/openapi.json").status_code == 404
    assert c.get("/healthz").status_code == 200


def test_every_response_carries_a_request_id() -> None:
    c = client()

    generated = c.get("/healthz").headers["X-Request-ID"]
    kept = c.get("/healthz", headers={"X-Request-ID": "trace-123"}).headers["X-Request-ID"]
    replaced = c.get("/healthz", headers={"X-Request-ID": "bad id\n<script>"}).headers[
        "X-Request-ID"
    ]

    assert len(generated) == 32
    assert kept == "trace-123"
    assert replaced != "bad id\n<script>" and len(replaced) == 32


def test_errors_use_the_envelope_with_request_id() -> None:
    response = client().get("/nope", headers={"X-Request-ID": "r-1"})

    assert response.status_code == 404
    assert response.json() == {
        "error": {"code": "NOT_FOUND", "message": "Not found.", "details": {}, "retryable": False},
        "request_id": "r-1",
    }


def test_missing_bearer_token_is_401_auth_required() -> None:
    response = client().get("/api/v1/me")

    assert response.status_code == 401
    assert response.json()["error"]["code"] == "AUTH_REQUIRED"
    assert response.headers["X-Request-ID"]
