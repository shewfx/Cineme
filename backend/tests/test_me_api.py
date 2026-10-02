"""POST /me/bootstrap, GET /me and PATCH /me against real PostgreSQL."""

import threading
import uuid
from typing import Any

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import text
from sqlalchemy.engine import Engine
from sqlalchemy.orm import Session

from app.users import service
from tests.conftest import FakeIdentityProvider, Signer

pytestmark = pytest.mark.integration


def auth(signer: Signer, user: uuid.UUID) -> dict[str, str]:
    return {"Authorization": f"Bearer {signer.token(user)}"}


def patch(
    client: TestClient,
    signer: Signer,
    user: uuid.UUID,
    body: dict[str, Any],
    key: str | None = None,
) -> Any:
    headers = auth(signer, user) | {"Idempotency-Key": key or str(uuid.uuid4())}
    return client.patch("/api/v1/me", json=body, headers=headers)


def count(engine: Engine, table: str) -> int:
    with engine.connect() as conn:
        return int(conn.execute(text(f"SELECT count(*) FROM cineme.{table}")).scalar_one())  # noqa: S608


def updated_at(engine: Engine, user: uuid.UUID) -> Any:
    with engine.connect() as conn:
        return conn.execute(
            text("SELECT updated_at FROM cineme.users WHERE id=:id"), {"id": user}
        ).scalar()


# --- bootstrap -----------------------------------------------------------------


def test_bootstrap_creates_then_reuses_without_resetting(
    client: TestClient, signer: Signer, provider: FakeIdentityProvider, engine: Engine
) -> None:
    a = uuid.uuid4()
    first = client.post("/api/v1/me/bootstrap", headers=auth(signer, a))
    assert first.status_code == 201
    body = first.json()
    assert body["created"] is True
    assert body["profile"]["id"] == str(a)
    assert body["profile"]["timezone"] == "UTC"
    assert body["profile"]["preferences"] == {
        "version": 1,
        "genre_preferences": {},
        "blocked_genre_ids": [],
        "default_max_runtime_minutes": None,
        "ai_context_enabled": False,
    }

    assert patch(client, signer, a, {"display_name": "Shew"}).status_code == 200
    again = client.post("/api/v1/me/bootstrap", headers=auth(signer, a))
    assert again.status_code == 200
    assert again.json()["created"] is False
    assert again.json()["profile"]["display_name"] == "Shew", "retry never resets"
    assert provider.calls == [a], "existing profiles skip the provider check"
    assert (count(engine, "users"), count(engine, "user_preferences")) == (1, 1)


def test_unverified_email_is_403_and_creates_nothing(
    client: TestClient, signer: Signer, provider: FakeIdentityProvider, engine: Engine
) -> None:
    a = uuid.uuid4()
    provider.unconfirmed.add(a)
    response = client.post("/api/v1/me/bootstrap", headers=auth(signer, a))
    assert response.status_code == 403
    assert response.json()["error"]["code"] == "EMAIL_NOT_VERIFIED"
    assert count(engine, "users") == 0


def test_provider_outage_is_retryable_503_and_creates_nothing(
    client: TestClient, signer: Signer, provider: FakeIdentityProvider, engine: Engine
) -> None:
    provider.down = True
    response = client.post("/api/v1/me/bootstrap", headers=auth(signer, uuid.uuid4()))
    assert response.status_code == 503
    assert response.json()["error"]["retryable"] is True
    assert count(engine, "users") == 0


def test_concurrent_first_bootstraps_converge(engine: Engine) -> None:
    a = uuid.uuid4()
    results: list[bool] = []
    errors: list[BaseException] = []
    barrier = threading.Barrier(8)

    def run() -> None:
        try:
            barrier.wait()
            with Session(engine) as session:
                results.append(service.bootstrap(session, a)[1])
        except BaseException as e:  # surfaced below
            errors.append(e)

    threads = [threading.Thread(target=run) for _ in range(8)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()

    assert errors == []
    assert sorted(results) == [False] * 7 + [True]
    assert (count(engine, "users"), count(engine, "user_preferences")) == (1, 1)


# --- GET /me -------------------------------------------------------------------


def test_get_me_before_bootstrap_is_409_and_inserts_nothing(
    client: TestClient, signer: Signer, engine: Engine
) -> None:
    response = client.get("/api/v1/me", headers=auth(signer, uuid.uuid4()))
    assert response.status_code == 409
    assert response.json()["error"]["code"] == "PROFILE_NOT_INITIALIZED"
    assert count(engine, "users") == 0


def test_get_me_is_read_only(client: TestClient, signer: Signer, engine: Engine) -> None:
    a = uuid.uuid4()
    client.post("/api/v1/me/bootstrap", headers=auth(signer, a))
    before = updated_at(engine, a)
    for _ in range(3):
        assert client.get("/api/v1/me", headers=auth(signer, a)).status_code == 200
    assert updated_at(engine, a) == before
    assert count(engine, "users") == 1


# --- identity and isolation ----------------------------------------------------


@pytest.mark.parametrize(
    "header",
    [None, "Bearer", "Basic abc", "Bearer not-a-jwt"],
)
def test_requests_without_a_valid_token_fail(client: TestClient, header: str | None) -> None:
    headers = {"Authorization": header} if header else {}
    for method, path in [("GET", "/api/v1/me"), ("POST", "/api/v1/me/bootstrap")]:
        response = client.request(method, path, headers=headers)
        assert response.status_code == 401
        assert response.json()["error"]["code"] in {"AUTH_REQUIRED", "TOKEN_INVALID"}


def test_expired_and_forged_tokens_are_rejected(client: TestClient, signer: Signer) -> None:
    a = uuid.uuid4()
    client.post("/api/v1/me/bootstrap", headers=auth(signer, a))
    expired = signer.token(a, exp=1_000_000_000, iat=999_999_000)
    forged = Signer().token(a)
    for token in (expired, forged):
        response = client.get("/api/v1/me", headers={"Authorization": f"Bearer {token}"})
        assert response.status_code == 401
        assert response.json()["error"]["code"] == "TOKEN_INVALID"


def test_users_only_see_and_change_their_own_profile(
    client: TestClient, signer: Signer, engine: Engine
) -> None:
    a, b = uuid.uuid4(), uuid.uuid4()
    for user in (a, b):
        client.post("/api/v1/me/bootstrap", headers=auth(signer, user))
    patch(client, signer, a, {"display_name": "Alice", "timezone": "Asia/Kolkata"})

    me_b = client.get("/api/v1/me", headers=auth(signer, b)).json()
    assert me_b["id"] == str(b)
    assert me_b["display_name"] is None and me_b["timezone"] == "UTC"

    # B cannot target A: identity comes only from the token.
    response = patch(client, signer, b, {"display_name": "Mallory", "id": str(a)})
    assert response.status_code == 422
    patch(client, signer, b, {"display_name": "Bob"})
    me_a = client.get("/api/v1/me", headers=auth(signer, a)).json()
    assert me_a["display_name"] == "Alice"
    assert me_a["timezone"] == "Asia/Kolkata"
    assert client.get("/api/v1/me", headers=auth(signer, b)).json()["display_name"] == "Bob"


# --- PATCH /me and idempotency -------------------------------------------------


@pytest.fixture
def user(client: TestClient, signer: Signer) -> uuid.UUID:
    u = uuid.uuid4()
    assert client.post("/api/v1/me/bootstrap", headers=auth(signer, u)).status_code == 201
    return u


def test_patch_updates_supplied_fields_only(
    client: TestClient, signer: Signer, user: uuid.UUID
) -> None:
    assert (
        patch(client, signer, user, {"display_name": "  Shew  "}).json()["display_name"] == "Shew"
    )
    response = patch(client, signer, user, {"timezone": "Europe/London"})
    assert response.status_code == 200
    assert response.json()["display_name"] == "Shew"
    assert response.json()["timezone"] == "Europe/London"
    cleared = patch(client, signer, user, {"display_name": None}).json()
    assert cleared["display_name"] is None and cleared["timezone"] == "Europe/London"


@pytest.mark.parametrize(
    "body",
    [
        {},
        {"timezone": "Mars/Olympus"},
        {"timezone": None},
        {"display_name": "   "},
        {"display_name": "x" * 81},
        {"user_id": "anything"},
        {"preferences": {"version": 9}},
    ],
)
def test_patch_validation_is_422(
    client: TestClient, signer: Signer, user: uuid.UUID, body: dict[str, Any]
) -> None:
    response = patch(client, signer, user, body)
    assert response.status_code == 422
    assert response.json()["error"]["code"] == "VALIDATION_ERROR"


def test_patch_without_profile_is_409(client: TestClient, signer: Signer) -> None:
    response = patch(client, signer, uuid.uuid4(), {"display_name": "x"})
    assert response.status_code == 409
    assert response.json()["error"]["code"] == "PROFILE_NOT_INITIALIZED"


@pytest.mark.parametrize("key", [None, "", "not-a-uuid"])
def test_patch_requires_a_uuid_idempotency_key(
    client: TestClient, signer: Signer, user: uuid.UUID, key: str | None
) -> None:
    headers = auth(signer, user)
    if key is not None:
        headers["Idempotency-Key"] = key
    response = client.patch("/api/v1/me", json={"display_name": "x"}, headers=headers)
    assert response.status_code == 400
    assert response.json()["error"]["code"] == "IDEMPOTENCY_KEY_REQUIRED"


def test_same_key_same_body_replays_without_reapplying(
    client: TestClient, signer: Signer, user: uuid.UUID, engine: Engine
) -> None:
    key = str(uuid.uuid4())
    first = patch(client, signer, user, {"display_name": "One"}, key)
    stamp = updated_at(engine, user)
    # Someone changes the name with a new key in between.
    patch(client, signer, user, {"display_name": "Two"})
    replay = patch(client, signer, user, {"display_name": "One"}, key)

    assert replay.status_code == 200
    assert replay.json() == first.json(), "the stored response is replayed"
    me = client.get("/api/v1/me", headers=auth(signer, user)).json()
    assert me["display_name"] == "Two", "a replay does not apply the change again"
    assert updated_at(engine, user) > stamp
    assert count(engine, "idempotency_records") == 2


def test_same_key_different_body_is_409(
    client: TestClient, signer: Signer, user: uuid.UUID
) -> None:
    key = str(uuid.uuid4())
    patch(client, signer, user, {"display_name": "One"}, key)
    response = patch(client, signer, user, {"display_name": "Other"}, key)
    assert response.status_code == 409
    assert response.json()["error"]["code"] == "IDEMPOTENCY_CONFLICT"


def test_keys_are_scoped_per_user(client: TestClient, signer: Signer, user: uuid.UUID) -> None:
    other = uuid.uuid4()
    client.post("/api/v1/me/bootstrap", headers=auth(signer, other))
    key = str(uuid.uuid4())
    assert patch(client, signer, user, {"display_name": "A"}, key).status_code == 200
    second = patch(client, signer, other, {"display_name": "B"}, key)
    assert second.status_code == 200
    assert second.json()["display_name"] == "B"


def test_failed_request_is_not_cached(
    client: TestClient,
    signer: Signer,
    user: uuid.UUID,
    engine: Engine,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    key = str(uuid.uuid4())
    original = service.apply_patch

    def explode(*args: Any) -> None:
        original(*args)
        raise RuntimeError("database went away mid-request")

    monkeypatch.setattr(service, "apply_patch", explode)
    failed = patch(client, signer, user, {"display_name": "Lost"}, key)
    assert failed.status_code == 500
    assert failed.json()["error"]["code"] == "INTERNAL_ERROR"
    assert count(engine, "idempotency_records") == 0
    assert client.get("/api/v1/me", headers=auth(signer, user)).json()["display_name"] is None

    monkeypatch.setattr(service, "apply_patch", original)
    retried = patch(client, signer, user, {"display_name": "Lost"}, key)
    assert retried.status_code == 200
    assert retried.json()["display_name"] == "Lost"


def test_concurrent_retries_apply_once(
    client: TestClient, signer: Signer, user: uuid.UUID, engine: Engine
) -> None:
    key = str(uuid.uuid4())
    responses: list[Any] = []
    barrier = threading.Barrier(5)

    def run() -> None:
        barrier.wait()
        responses.append(patch(client, signer, user, {"display_name": "Once"}, key))

    threads = [threading.Thread(target=run) for _ in range(5)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()

    assert [r.status_code for r in responses] == [200] * 5
    # JSONB may reorder keys; compare parsed JSON, not bytes.
    assert all(r.json() == responses[0].json() for r in responses)
    assert count(engine, "idempotency_records") == 1
