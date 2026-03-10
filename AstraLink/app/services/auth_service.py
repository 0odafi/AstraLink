import hashlib
import re
import secrets
from datetime import UTC, datetime, timedelta

from sqlalchemy import and_, delete, or_, select
from sqlalchemy.orm import Session

from app.core.config import get_settings
from app.core.security import (
    create_access_token,
    generate_refresh_token,
    hash_password,
    hash_refresh_token,
    verify_password,
)
from app.models.user import PhoneLoginCode, RefreshToken, User
from app.schemas.auth import (
    PhoneCodeResponse,
    PhoneCodeVerifyRequest,
    RegisterRequest,
    TokenResponse,
)
from app.schemas.user import UserPublic
from app.services.user_service import (
    USERNAME_RULES_MESSAGE,
    is_probable_phone,
    normalize_phone,
    normalize_username,
    validate_username,
)
from app.services.sms_service import send_login_code



def _now_like(reference: datetime | None = None) -> datetime:
    now = datetime.now(UTC)
    if reference is not None and reference.tzinfo is None:
        return now.replace(tzinfo=None)
    return now


def _code_hash(phone: str, code: str) -> str:
    return hashlib.sha256(f"{phone}:{code}".encode("utf-8")).hexdigest()


def _synthetic_email(seed: str) -> str:
    token = secrets.token_hex(4)
    safe_seed = re.sub(r"[^a-z0-9]+", "", normalize_username(seed))
    if not safe_seed:
        safe_seed = f"user{secrets.token_hex(2)}"
    return f"{safe_seed}.{token}@phone.astralink.local"


def _cleanup_phone_codes(db: Session, now: datetime) -> None:
    db.execute(
        delete(PhoneLoginCode).where(
            or_(
                PhoneLoginCode.expires_at <= now,
                PhoneLoginCode.is_consumed.is_(True),
            )
        )
    )


def _resolve_login_code() -> str:
    settings = get_settings()
    test_code = (settings.auth_test_code or "").strip()
    if test_code:
        return test_code

    length = max(4, min(settings.login_code_length, 8))
    low = 10 ** (length - 1)
    span = 9 * low
    return f"{secrets.randbelow(span) + low}"


def request_phone_login_code(db: Session, phone: str) -> PhoneCodeResponse:
    settings = get_settings()
    normalized_phone = normalize_phone(phone)
    now = _now_like()
    _cleanup_phone_codes(db, now)

    expire_seconds = max(60, settings.login_code_expire_seconds)
    code = _resolve_login_code()
    raw_code_token = generate_refresh_token()
    db.add(
        PhoneLoginCode(
            phone=normalized_phone,
            code_token_hash=hash_refresh_token(raw_code_token),
            code_hash=_code_hash(normalized_phone, code),
            expires_at=now + timedelta(seconds=expire_seconds),
        )
    )

    registered_user = db.scalar(select(User).where(User.phone == normalized_phone))
    try:
        send_login_code(phone=normalized_phone, code=code)
    except ValueError:
        db.rollback()
        raise

    db.commit()
    return PhoneCodeResponse(
        phone=normalized_phone,
        code_token=raw_code_token,
        expires_in_seconds=expire_seconds,
        is_registered=registered_user is not None,
    )


def verify_phone_login_code(db: Session, payload: PhoneCodeVerifyRequest) -> tuple[User, bool]:
    normalized_phone = normalize_phone(payload.phone)
    token_hash = hash_refresh_token(payload.code_token)
    now = _now_like()
    _cleanup_phone_codes(db, now)

    code_session = db.scalar(
        select(PhoneLoginCode).where(
            and_(
                PhoneLoginCode.phone == normalized_phone,
                PhoneLoginCode.code_token_hash == token_hash,
            )
        )
    )
    if not code_session:
        raise ValueError("Verification session not found. Request a new code.")
    now = _now_like(code_session.expires_at)
    if code_session.expires_at <= now:
        raise ValueError("Code expired. Request a new code.")
    if code_session.is_consumed:
        raise ValueError("Code already used. Request a new one.")
    settings = get_settings()
    max_attempts = max(1, settings.login_code_max_attempts)
    if code_session.attempts >= max_attempts:
        raise ValueError("Too many attempts. Request a new code.")

    received_code = payload.code.strip()
    if _code_hash(normalized_phone, received_code) != code_session.code_hash:
        code_session.attempts += 1
        db.add(code_session)
        db.commit()
        raise ValueError("Invalid code")

    code_session.is_consumed = True
    code_session.consumed_at = now
    db.add(code_session)

    user = db.scalar(select(User).where(User.phone == normalized_phone))
    created = False
    if user is None:
        first_name = (payload.first_name or "").strip()
        last_name = (payload.last_name or "").strip()
        user = User(
            username=None,
            phone=normalized_phone,
            first_name=first_name,
            last_name=last_name,
            email=_synthetic_email(normalized_phone),
            password_hash=hash_password(generate_refresh_token()),
        )
        db.add(user)
        created = True
    else:
        # Fill profile defaults for legacy users if missing.
        if not user.first_name and payload.first_name:
            user.first_name = payload.first_name.strip()
        if not user.last_name and payload.last_name:
            user.last_name = payload.last_name.strip()
        if not user.phone:
            user.phone = normalized_phone
        db.add(user)

    db.commit()
    db.refresh(user)
    return user, created


def register_user(db: Session, payload: RegisterRequest) -> User:
    normalized_username = normalize_username(payload.username)
    if not validate_username(normalized_username):
        raise ValueError(USERNAME_RULES_MESSAGE)

    existing = db.scalar(
        select(User).where(or_(User.username == normalized_username, User.email == payload.email))
    )
    if existing:
        raise ValueError("Username or email already exists")

    user = User(
        username=normalized_username,
        email=payload.email,
        password_hash=hash_password(payload.password),
    )
    db.add(user)
    db.commit()
    db.refresh(user)
    return user


def authenticate_user(db: Session, login: str, password: str) -> User | None:
    normalized_login = normalize_username(login)
    criteria = [User.username == normalized_login, User.email == login]
    if is_probable_phone(login):
        try:
            criteria.append(User.phone == normalize_phone(login))
        except ValueError:
            pass

    user = db.scalar(select(User).where(or_(*criteria)))
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


def build_token_response(
    db: Session,
    user: User,
    *,
    needs_profile_setup: bool = False,
) -> TokenResponse:
    access_token = create_access_token(str(user.id))
    refresh_token = _issue_refresh_token(db, user_id=user.id)
    user.last_seen_at = _now_like(user.last_seen_at)
    db.add(user)
    db.commit()
    return TokenResponse(
        access_token=access_token,
        refresh_token=refresh_token,
        needs_profile_setup=needs_profile_setup,
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
