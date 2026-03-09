import re

from sqlalchemy import or_, select
from sqlalchemy.orm import Session

from app.models.user import User

USERNAME_RE = re.compile(r"^[a-z][a-z0-9_]{4,31}$")
USERNAME_RULES_MESSAGE = (
    "Username format: 5-32 chars, start with a letter, use letters, numbers or underscore"
)


def normalize_username(value: str) -> str:
    return value.strip().lstrip("@").lower()


def validate_username(value: str) -> bool:
    return bool(USERNAME_RE.fullmatch(value))


def normalize_phone(value: str) -> str:
    digits = "".join(char for char in value if char.isdigit())
    if digits.startswith("8") and len(digits) == 11:
        digits = f"7{digits[1:]}"
    if len(digits) == 10:
        digits = f"7{digits}"
    if len(digits) < 10 or len(digits) > 15:
        raise ValueError("Phone number format is invalid")
    return f"+{digits}"


def is_probable_phone(value: str) -> bool:
    digits = "".join(char for char in value if char.isdigit())
    return 10 <= len(digits) <= 15


def _phone_search_pattern(query: str) -> str | None:
    if not is_probable_phone(query):
        return None
    try:
        return f"%{normalize_phone(query).lstrip('+')}%"
    except ValueError:
        return None


def search_users(db: Session, query: str, limit: int = 20) -> list[User]:
    cleaned_query = query.strip()
    if not cleaned_query:
        return []

    normalized_username_query = normalize_username(cleaned_query)
    display_query = cleaned_query.lower().lstrip("@")
    pattern = f"%{display_query}%"
    username_pattern = f"%{normalized_username_query}%"
    phone_pattern = _phone_search_pattern(cleaned_query)
    phone_expression = (
        User.phone.ilike(phone_pattern)
        if phone_pattern is not None
        else User.phone.ilike("%__never_match__%")
    )

    statement = (
        select(User)
        .where(
            or_(
                User.username.ilike(username_pattern),
                User.first_name.ilike(pattern),
                User.last_name.ilike(pattern),
                phone_expression,
            )
        )
        .order_by(User.username.is_(None), User.username.asc(), User.first_name.asc(), User.id.asc())
        .limit(limit)
    )
    return list(db.scalars(statement).all())


def find_user_by_phone_or_username(db: Session, query: str) -> User | None:
    cleaned_query = query.strip()
    if not cleaned_query:
        return None

    if is_probable_phone(cleaned_query):
        try:
            normalized_phone = normalize_phone(cleaned_query)
            by_phone = db.scalar(select(User).where(User.phone == normalized_phone))
            if by_phone:
                return by_phone
        except ValueError:
            pass

    normalized_username = normalize_username(cleaned_query)
    if not normalized_username:
        return None
    return db.scalar(select(User).where(User.username == normalized_username))


def ensure_username_available(db: Session, username: str, current_user_id: int | None = None) -> None:
    existing = db.scalar(select(User).where(User.username == username))
    if existing and existing.id != current_user_id:
        raise ValueError("Username is already taken")
