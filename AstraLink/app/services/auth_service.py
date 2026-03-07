from datetime import UTC, datetime, timedelta

from sqlalchemy import and_, or_, select
from sqlalchemy.orm import Session

from app.core.config import get_settings
from app.core.security import (
    create_access_token,
    generate_refresh_token,
    hash_password,
    hash_refresh_token,
    verify_password,
)
from app.models.user import RefreshToken, User
from app.schemas.auth import RegisterRequest, TokenResponse
from app.schemas.user import UserPublic


def _now_like(reference: datetime | None = None) -> datetime:
    now = datetime.now(UTC)
    if reference is not None and reference.tzinfo is None:
        return now.replace(tzinfo=None)
    return now


def register_user(db: Session, payload: RegisterRequest) -> User:
    existing = db.scalar(
        select(User).where(or_(User.username == payload.username, User.email == payload.email))
    )
    if existing:
        raise ValueError("Username or email already exists")

    user = User(
        username=payload.username,
        email=payload.email,
        password_hash=hash_password(payload.password),
    )
    db.add(user)
    db.commit()
    db.refresh(user)
    return user


def authenticate_user(db: Session, login: str, password: str) -> User | None:
    user = db.scalar(select(User).where(or_(User.username == login, User.email == login)))
    if not user:
        return None
    if not verify_password(password, user.password_hash):
        return None
    return user


def _issue_refresh_token(db: Session, user_id: int) -> str:
    settings = get_settings()
    raw_token = generate_refresh_token()
    hashed_token = hash_refresh_token(raw_token)
    now = _now_like()
    expires_at = now + timedelta(days=settings.refresh_token_expire_days)

    db.add(
        RefreshToken(
            user_id=user_id,
            token_hash=hashed_token,
            expires_at=expires_at,
            last_used_at=now,
        )
    )
    return raw_token


def build_token_response(db: Session, user: User) -> TokenResponse:
    access_token = create_access_token(str(user.id))
    refresh_token = _issue_refresh_token(db, user_id=user.id)
    db.commit()
    return TokenResponse(
        access_token=access_token,
        refresh_token=refresh_token,
        user=UserPublic.model_validate(user),
    )


def rotate_refresh_token(db: Session, refresh_token: str) -> TokenResponse:
    token_hash = hash_refresh_token(refresh_token)
    stored_token = db.scalar(select(RefreshToken).where(RefreshToken.token_hash == token_hash))
    if not stored_token:
        raise ValueError("Invalid refresh token")
    now = _now_like(stored_token.expires_at)
    if stored_token.revoked_at is not None or stored_token.expires_at <= now:
        raise ValueError("Refresh token expired or revoked")

    user = db.scalar(select(User).where(and_(User.id == stored_token.user_id, User.is_active.is_(True))))
    if not user:
        raise ValueError("User not found or inactive")

    stored_token.revoked_at = now
    stored_token.last_used_at = now
    db.add(stored_token)

    access_token = create_access_token(str(user.id))
    new_refresh_token = _issue_refresh_token(db, user_id=user.id)
    db.commit()
    return TokenResponse(
        access_token=access_token,
        refresh_token=new_refresh_token,
        user=UserPublic.model_validate(user),
    )


def revoke_refresh_token(db: Session, refresh_token: str) -> bool:
    token_hash = hash_refresh_token(refresh_token)
    stored_token = db.scalar(select(RefreshToken).where(RefreshToken.token_hash == token_hash))
    if not stored_token:
        return False
    if stored_token.revoked_at is not None:
        return True

    stored_token.revoked_at = _now_like(stored_token.created_at)
    db.add(stored_token)
    db.commit()
    return True
