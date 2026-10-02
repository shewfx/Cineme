"""Small idempotency ledger for private mutations (API_CONTRACT "Common rules").

Call inside the mutation's transaction *after* locking the user row, so two
requests with one key serialize: the second replays the stored response.
The record is written in the same transaction as the change, so a failed or
rolled-back request leaves nothing cached.
"""

import hashlib
import json
import uuid
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from typing import Any

from sqlalchemy import (
    CheckConstraint,
    DateTime,
    ForeignKey,
    Index,
    SmallInteger,
    String,
    UniqueConstraint,
    delete,
    func,
    select,
)
from sqlalchemy.dialects.postgresql import JSONB, UUID
from sqlalchemy.orm import Mapped, Session, mapped_column

from .db import Base
from .errors import AppError

REPLAY_WINDOW = timedelta(hours=24)


class IdempotencyRecord(Base):
    """`idempotency_records` (DATA_MODEL), brought forward to P2 by ADR 003
    for PATCH /me only. A committed mutation and its response are stored in
    the same transaction, so a failed request is never cached."""

    __tablename__ = "idempotency_records"
    __table_args__ = (
        UniqueConstraint("user_id", "key"),
        CheckConstraint("char_length(request_hash) = 64", name="request_hash_sha256"),
        Index(None, "expires_at"),
    )

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True)
    user_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("cineme.users.id", ondelete="CASCADE")
    )
    key: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True))
    operation: Mapped[str] = mapped_column(String(120))
    request_hash: Mapped[str] = mapped_column(String(64))
    http_status: Mapped[int] = mapped_column(SmallInteger)
    response_body: Mapped[dict[str, Any]] = mapped_column(JSONB)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))


def parse_key(raw: str | None) -> uuid.UUID:
    try:
        return uuid.UUID(raw or "")
    except ValueError as e:
        raise AppError(
            400,
            "IDEMPOTENCY_KEY_REQUIRED",
            "Send a UUID Idempotency-Key header with this request.",
        ) from e


def request_hash(body: dict[str, Any]) -> str:
    canonical = json.dumps(body, sort_keys=True, separators=(",", ":"), default=str)
    return hashlib.sha256(canonical.encode()).hexdigest()


@dataclass(frozen=True)
class Replay:
    status: int
    body: dict[str, Any]


def lookup(
    session: Session, user_id: uuid.UUID, key: uuid.UUID, operation: str, digest: str
) -> Replay | None:
    """Stored response for an identical retry; 409 if the key was used for a
    different request or route. Expired records are discarded."""
    now = datetime.now(UTC)
    record = session.scalar(
        select(IdempotencyRecord).where(
            IdempotencyRecord.user_id == user_id, IdempotencyRecord.key == key
        )
    )
    if record is None:
        return None
    if record.expires_at <= now:
        session.execute(delete(IdempotencyRecord).where(IdempotencyRecord.id == record.id))
        session.flush()
        return None
    if record.operation != operation or record.request_hash != digest:
        raise AppError(
            409,
            "IDEMPOTENCY_CONFLICT",
            "This Idempotency-Key was already used for a different request.",
        )
    return Replay(record.http_status, record.response_body)


def store(
    session: Session,
    user_id: uuid.UUID,
    key: uuid.UUID,
    operation: str,
    digest: str,
    status: int,
    body: dict[str, Any],
) -> None:
    now = datetime.now(UTC)
    session.add(
        IdempotencyRecord(
            id=uuid.uuid4(),
            user_id=user_id,
            key=key,
            operation=operation,
            request_hash=digest,
            http_status=status,
            response_body=body,
            created_at=now,
            expires_at=now + REPLAY_WINDOW,
        )
    )
