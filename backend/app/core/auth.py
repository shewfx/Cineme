"""Thin, library-backed identity checks (ARCHITECTURE "Authentication").

Supabase owns credentials and sessions. FastAPI only verifies the access JWT
with PyJWT against the project's JWKS and, before first bootstrap, asks the
provider to confirm the user. There is no auth bypass: tests construct the app
with their own signing keys and a fake provider, never a disabled check.
"""

import uuid
from collections.abc import Callable
from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Any, Protocol

import httpx
import jwt
from fastapi import Header, Request

from .errors import AppError

ALGORITHMS = ["ES256"]
AUDIENCE = "authenticated"
LEEWAY_SECONDS = 30

# Resolves the verification key for a token (normally via the JWKS endpoint).
KeyResolver = Callable[[str], Any]


@dataclass(frozen=True)
class Identity:
    user_id: uuid.UUID
    email: str
    access_token: str


def _invalid() -> AppError:
    return AppError(401, "TOKEN_INVALID", "Your session is not valid. Sign in again.")


def _unavailable() -> AppError:
    return AppError(
        503,
        "DEPENDENCY_UNAVAILABLE",
        "Sign-in service is unavailable. Try again shortly.",
        retryable=True,
    )


def jwks_key_resolver(jwks_url: str) -> KeyResolver:
    """PyJWT's JWKS client: keys cached five minutes, an unknown `kid` refreshes
    once, 2 s network timeout. The URL comes from settings, never the token."""
    client = jwt.PyJWKClient(jwks_url, cache_keys=True, lifespan=300, timeout=2)
    return lambda token: client.get_signing_key_from_jwt(token).key


class TokenVerifier:
    def __init__(self, issuer: str, resolve_key: KeyResolver) -> None:
        self._issuer = issuer
        self._resolve_key = resolve_key

    def verify(self, token: str) -> Identity:
        try:
            # Header algorithm is checked, not trusted: only ES256 is allowed.
            if jwt.get_unverified_header(token).get("alg") not in ALGORITHMS:
                raise _invalid()
            key = self._resolve_key(token)
        except jwt.PyJWKClientConnectionError as e:
            raise _unavailable() from e
        except (jwt.PyJWKClientError, jwt.InvalidTokenError) as e:
            raise _invalid() from e

        try:
            claims = jwt.decode(
                token,
                key,
                algorithms=ALGORITHMS,
                audience=AUDIENCE,
                issuer=self._issuer,
                leeway=LEEWAY_SECONDS,
                options={"require": ["exp", "iat", "sub", "aud", "iss"]},
            )
        except jwt.InvalidTokenError as e:
            raise _invalid() from e

        email = claims.get("email")
        if (
            claims.get("role") != "authenticated"
            or claims.get("is_anonymous") is True
            or not isinstance(email, str)
            or not email
        ):
            raise _invalid()
        try:
            user_id = uuid.UUID(str(claims["sub"]))
        except ValueError as e:
            raise _invalid() from e
        return Identity(user_id=user_id, email=email, access_token=token)


class IdentityProvider(Protocol):
    def confirm(self, identity: Identity) -> None:
        """Raises AppError unless the provider confirms this verified user."""


class SupabaseIdentityProvider:
    """GET /auth/v1/user with the caller's token, used only before first
    bootstrap and always outside a database transaction."""

    def __init__(self, base_url: str, publishable_key: str, client: httpx.Client) -> None:
        self._url = f"{base_url}/auth/v1/user"
        self._key = publishable_key
        self._client = client

    def confirm(self, identity: Identity) -> None:
        try:
            response = self._client.get(
                self._url,
                headers={
                    "Authorization": f"Bearer {identity.access_token}",
                    "apikey": self._key,
                },
            )
        except httpx.HTTPError as e:
            raise _unavailable() from e
        if response.status_code in (401, 403):
            raise _invalid()
        if response.status_code != 200:
            raise _unavailable()
        try:
            user = response.json()
        except ValueError as e:
            raise _unavailable() from e
        if not isinstance(user, dict) or user.get("id") != str(identity.user_id):
            raise _invalid()
        if user.get("deleted_at") or _banned(user.get("banned_until")):
            raise _invalid()
        if not user.get("email_confirmed_at"):
            raise AppError(
                403,
                "EMAIL_NOT_VERIFIED",
                "Confirm your email address, then try again.",
            )


def _banned(value: object) -> bool:
    if not isinstance(value, str) or not value:
        return False
    try:
        until = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return True  # unparseable ban marker: treat as banned
    return until > datetime.now(UTC)


def current_identity(
    request: Request, authorization: str | None = Header(default=None)
) -> Identity:
    """FastAPI dependency: the only source of the caller's identity."""
    scheme, _, token = (authorization or "").partition(" ")
    if scheme.lower() != "bearer" or not token:
        raise AppError(401, "AUTH_REQUIRED", "Sign in to continue.")
    verifier: TokenVerifier = request.app.state.verifier
    return verifier.verify(token.strip())
