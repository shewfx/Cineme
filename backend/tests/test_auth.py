"""Token verification and the provider get-user check, without network."""

import json
import time
import uuid
from typing import Any

import httpx
import jwt
import pytest
from cryptography.hazmat.primitives.asymmetric import ec

from app.core.auth import Identity, SupabaseIdentityProvider, TokenVerifier, jwks_key_resolver
from app.core.errors import AppError
from tests.conftest import ISSUER, PROJECT, Signer

USER = uuid.uuid4()


def code_of(fn: Any) -> tuple[int, str]:
    with pytest.raises(AppError) as info:
        fn()
    return info.value.status, info.value.code


def test_valid_supabase_shaped_token_yields_identity(signer: Signer) -> None:
    identity = signer.verifier().verify(signer.token(USER))

    assert identity.user_id == USER
    assert identity.email == f"{USER}@example.test"


@pytest.mark.parametrize(
    ("overrides", "why"),
    [
        ({"iss": "https://other.supabase.co/auth/v1"}, "wrong issuer"),
        ({"aud": "anon"}, "wrong audience"),
        ({"exp": int(time.time()) - 31}, "expired beyond leeway"),
        ({"nbf": int(time.time()) + 120}, "not yet valid"),
        ({"sub": "not-a-uuid"}, "sub not uuid"),
        ({"sub": None}, "missing sub"),
        ({"exp": None}, "missing exp"),
        ({"email": None}, "missing email"),
        ({"email": ""}, "empty email"),
        ({"role": "anon"}, "role not authenticated"),
        ({"is_anonymous": True}, "anonymous user"),
    ],
)
def test_invalid_claims_are_401(signer: Signer, overrides: dict[str, Any], why: str) -> None:
    token = signer.token(USER, **overrides)
    assert code_of(lambda: signer.verifier().verify(token)) == (401, "TOKEN_INVALID"), why


def test_small_clock_skew_within_leeway_is_accepted(signer: Signer) -> None:
    token = signer.token(USER, exp=int(time.time()) - 10)
    assert signer.verifier().verify(token).user_id == USER


def test_forged_signature_is_401(signer: Signer) -> None:
    forger = Signer()
    token = forger.token(USER)  # valid claims, wrong key
    assert code_of(lambda: signer.verifier().verify(token)) == (401, "TOKEN_INVALID")


@pytest.mark.parametrize("token", ["", "garbage", "a.b.c"])
def test_malformed_tokens_are_401(signer: Signer, token: str) -> None:
    assert code_of(lambda: signer.verifier().verify(token)) == (401, "TOKEN_INVALID")


def test_token_chosen_algorithms_are_refused(signer: Signer) -> None:
    claims = jwt.decode(signer.token(USER), options={"verify_signature": False})
    hs = jwt.encode(claims, "x" * 32, algorithm="HS256")
    unsigned = jwt.encode(claims, None, algorithm="none")  # type: ignore[arg-type]
    for token in (hs, unsigned):
        assert code_of(lambda t=token: signer.verifier().verify(t)) == (401, "TOKEN_INVALID")


def test_key_service_outage_is_503_not_401(signer: Signer) -> None:
    def down(_token: str) -> Any:
        raise jwt.PyJWKClientConnectionError("timeout")

    verifier = TokenVerifier(ISSUER, down)
    status, code = code_of(lambda: verifier.verify(signer.token(USER)))
    assert (status, code) == (503, "DEPENDENCY_UNAVAILABLE")


def _jwk(s: Signer) -> dict[str, Any]:
    data = json.loads(jwt.algorithms.ECAlgorithm.to_jwk(s.public_key))
    return {**data, "kid": s.kid, "alg": "ES256", "use": "sig"}


def test_jwks_client_refreshes_once_for_a_rotated_key(monkeypatch: pytest.MonkeyPatch) -> None:
    old, new = Signer(kid="old"), Signer(kid="new")
    published = [{"keys": [_jwk(old)]}]
    fetches: list[int] = []

    def fetch(self: jwt.PyJWKClient) -> dict[str, Any]:
        fetches.append(1)
        return published[0]

    monkeypatch.setattr(jwt.PyJWKClient, "fetch_data", fetch)
    verifier = TokenVerifier(ISSUER, jwks_key_resolver(f"{PROJECT}/auth/v1/.well-known/jwks.json"))

    assert verifier.verify(old.token(USER)).user_id == USER
    published[0] = {"keys": [_jwk(old), _jwk(new)]}  # provider rotates
    assert verifier.verify(new.token(USER)).user_id == USER
    assert len(fetches) == 2, "cached set, then one refresh for the unknown kid"

    stranger = Signer(kid="unknown")
    assert code_of(lambda: verifier.verify(stranger.token(USER))) == (401, "TOKEN_INVALID")


# --- provider get-user check -------------------------------------------------


def provider(handler: Any) -> SupabaseIdentityProvider:
    return SupabaseIdentityProvider(
        PROJECT, "sb_publishable_test", httpx.Client(transport=httpx.MockTransport(handler))
    )


IDENTITY = Identity(user_id=USER, email="a@example.test", access_token="tok")


def user_json(**overrides: Any) -> dict[str, Any]:
    return {"id": str(USER), "email_confirmed_at": "2026-10-01T10:00:00Z", **overrides}


def test_confirmed_user_passes_and_sends_token_and_key() -> None:
    seen: list[httpx.Request] = []

    def handler(request: httpx.Request) -> httpx.Response:
        seen.append(request)
        return httpx.Response(200, json=user_json())

    provider(handler).confirm(IDENTITY)
    assert seen[0].url == f"{PROJECT}/auth/v1/user"
    assert seen[0].headers["Authorization"] == "Bearer tok"
    assert seen[0].headers["apikey"] == "sb_publishable_test"


@pytest.mark.parametrize(
    ("response", "expected"),
    [
        (httpx.Response(200, json=user_json(email_confirmed_at=None)), (403, "EMAIL_NOT_VERIFIED")),
        (httpx.Response(200, json=user_json(id=str(uuid.uuid4()))), (401, "TOKEN_INVALID")),
        (
            httpx.Response(200, json=user_json(banned_until="2999-01-01T00:00:00Z")),
            (401, "TOKEN_INVALID"),
        ),
        (
            httpx.Response(200, json=user_json(deleted_at="2026-01-01T00:00:00Z")),
            (401, "TOKEN_INVALID"),
        ),
        (httpx.Response(401, json={}), (401, "TOKEN_INVALID")),
        (httpx.Response(500, text="boom"), (503, "DEPENDENCY_UNAVAILABLE")),
        (httpx.Response(200, text="not json"), (503, "DEPENDENCY_UNAVAILABLE")),
    ],
)
def test_provider_outcomes(response: httpx.Response, expected: tuple[int, str]) -> None:
    assert code_of(lambda: provider(lambda _r: response).confirm(IDENTITY)) == expected


def test_provider_network_failure_is_503() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectTimeout("slow", request=request)

    assert code_of(lambda: provider(handler).confirm(IDENTITY)) == (503, "DEPENDENCY_UNAVAILABLE")


def test_expired_ban_does_not_block() -> None:
    response = httpx.Response(200, json=user_json(banned_until="2000-01-01T00:00:00Z"))
    provider(lambda _r: response).confirm(IDENTITY)


def test_signer_uses_p256() -> None:
    assert isinstance(Signer().private_key.curve, ec.SECP256R1)
