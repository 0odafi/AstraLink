from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.api.deps import get_current_user, get_db
from app.models.user import User
from app.schemas.user import ProfileUpdate, UserPublic
from app.services.user_service import (
    ensure_username_available,
    find_user_by_phone_or_username,
    is_probable_phone,
    normalize_phone,
    normalize_username,
    search_users,
    validate_username,
)

router = APIRouter(prefix="/users", tags=["Users"])


@router.get("/me", response_model=UserPublic)
def me(current_user: User = Depends(get_current_user)) -> UserPublic:
    return UserPublic.model_validate(current_user)


@router.patch("/me", response_model=UserPublic)
def update_me(
    payload: ProfileUpdate,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> UserPublic:
    if payload.bio is not None:
        current_user.bio = payload.bio
    if payload.avatar_url is not None:
        current_user.avatar_url = payload.avatar_url
    if payload.first_name is not None:
        current_user.first_name = payload.first_name.strip()
    if payload.last_name is not None:
        current_user.last_name = payload.last_name.strip()

    if payload.username is not None:
        normalized_username = normalize_username(payload.username)
        if not validate_username(normalized_username):
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="Username format: start with letter, letters/digits/underscore, length 5-32",
            )
        try:
            ensure_username_available(db, normalized_username, current_user_id=current_user.id)
        except ValueError as exc:
            raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(exc)) from exc
        current_user.username = normalized_username

    db.add(current_user)
    db.commit()
    db.refresh(current_user)
    return UserPublic.model_validate(current_user)


@router.get("/search", response_model=list[UserPublic])
def search(
    q: str = Query(..., min_length=1, max_length=120),
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> list[UserPublic]:
    _ = current_user
    users = search_users(db, q)
    return [UserPublic.model_validate(user) for user in users]


@router.get("/lookup", response_model=UserPublic)
def lookup_user(
    q: str = Query(..., min_length=3, max_length=120),
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> UserPublic:
    _ = current_user
    user = find_user_by_phone_or_username(db, q)
    if user:
        return UserPublic.model_validate(user)

    if is_probable_phone(q):
        try:
            normalized = normalize_phone(q)
        except ValueError:
            normalized = q
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=f"User with phone {normalized} not found")

    raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="User not found")


@router.get("/{user_id}", response_model=UserPublic)
def get_user_by_id(
    user_id: int,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> UserPublic:
    _ = current_user
    user = db.scalar(select(User).where(User.id == user_id))
    if not user:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="User not found")
    return UserPublic.model_validate(user)
