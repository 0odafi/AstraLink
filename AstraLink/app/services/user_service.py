import re

from sqlalchemy import and_, or_, select
from sqlalchemy.orm import Session

from app.models.user import Follow, User

UID_RE = re.compile(r"^[a-z0-9_]{5,32}$")


def normalize_uid(value: str) -> str:
    return value.strip().lower()


def validate_uid(value: str) -> bool:
    return bool(UID_RE.fullmatch(value))


def search_users(db: Session, query: str, limit: int = 20) -> list[User]:
    pattern = f"%{query.lower()}%"
    statement = (
        select(User)
        .where(
            or_(
                User.uid.ilike(pattern),
                User.username.ilike(pattern),
                User.email.ilike(pattern),
            )
        )
        .order_by(User.username.asc())
        .limit(limit)
    )
    return list(db.scalars(statement).all())


def find_user_by_uid(db: Session, uid: str) -> User | None:
    normalized = normalize_uid(uid)
    return db.scalar(select(User).where(User.uid == normalized))


def ensure_uid_available(db: Session, uid: str, current_user_id: int | None = None) -> None:
    existing = db.scalar(select(User).where(User.uid == uid))
    if existing and existing.id != current_user_id:
        raise ValueError("UID is already taken")


def follow_user(db: Session, follower_id: int, following_id: int) -> Follow:
    if follower_id == following_id:
        raise ValueError("You cannot follow yourself")

    existing = db.scalar(
        select(Follow).where(
            and_(Follow.follower_id == follower_id, Follow.following_id == following_id)
        )
    )
    if existing:
        return existing

    target = db.scalar(select(User).where(User.id == following_id))
    if not target:
        raise ValueError("Target user does not exist")

    relation = Follow(follower_id=follower_id, following_id=following_id)
    db.add(relation)
    db.commit()
    db.refresh(relation)
    return relation


def unfollow_user(db: Session, follower_id: int, following_id: int) -> bool:
    existing = db.scalar(
        select(Follow).where(
            and_(Follow.follower_id == follower_id, Follow.following_id == following_id)
        )
    )
    if not existing:
        return False
    db.delete(existing)
    db.commit()
    return True


def list_followers(db: Session, user_id: int) -> list[User]:
    statement = (
        select(User)
        .join(Follow, Follow.follower_id == User.id)
        .where(Follow.following_id == user_id)
        .order_by(User.username.asc())
    )
    return list(db.scalars(statement).all())


def list_following(db: Session, user_id: int) -> list[User]:
    statement = (
        select(User)
        .join(Follow, Follow.following_id == User.id)
        .where(Follow.follower_id == user_id)
        .order_by(User.username.asc())
    )
    return list(db.scalars(statement).all())
