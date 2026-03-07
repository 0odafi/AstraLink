from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.api.deps import get_current_user, get_db
from app.models.user import User
from app.schemas.user import FollowActionResult, ProfileUpdate, UserPublic
from app.services.user_service import (
    ensure_uid_available,
    find_user_by_uid,
    follow_user,
    list_followers,
    list_following,
    normalize_uid,
    search_users,
    unfollow_user,
    validate_uid,
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
    if payload.uid is not None:
        normalized_uid = normalize_uid(payload.uid)
        if not validate_uid(normalized_uid):
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="UID must contain only lowercase letters, digits, underscore, 5-32 chars",
            )
        try:
            ensure_uid_available(db, normalized_uid, current_user_id=current_user.id)
        except ValueError as exc:
            raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(exc)) from exc
        current_user.uid = normalized_uid

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


@router.get("/by-uid/{uid}", response_model=UserPublic)
def get_user_by_uid(
    uid: str,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> UserPublic:
    _ = current_user
    normalized_uid = normalize_uid(uid)
    if not validate_uid(normalized_uid):
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Invalid UID format",
        )

    user = find_user_by_uid(db, normalized_uid)
    if not user:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="User not found")
    return UserPublic.model_validate(user)


@router.post("/{user_id}/follow", response_model=FollowActionResult)
def follow(
    user_id: int,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> FollowActionResult:
    try:
        relation = follow_user(db, follower_id=current_user.id, following_id=user_id)
    except ValueError as exc:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(exc)) from exc
    return FollowActionResult(
        follower_id=relation.follower_id,
        following_id=relation.following_id,
        is_following=True,
    )


@router.delete("/{user_id}/follow", response_model=FollowActionResult)
def unfollow(
    user_id: int,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> FollowActionResult:
    existed = unfollow_user(db, follower_id=current_user.id, following_id=user_id)
    return FollowActionResult(
        follower_id=current_user.id,
        following_id=user_id,
        is_following=False,
    )


@router.get("/{user_id}/followers", response_model=list[UserPublic])
def followers(
    user_id: int,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> list[UserPublic]:
    _ = current_user
    user_exists = db.scalar(select(User).where(User.id == user_id))
    if not user_exists:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="User not found")
    users = list_followers(db, user_id=user_id)
    return [UserPublic.model_validate(user) for user in users]


@router.get("/{user_id}/following", response_model=list[UserPublic])
def following(
    user_id: int,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> list[UserPublic]:
    _ = current_user
    user_exists = db.scalar(select(User).where(User.id == user_id))
    if not user_exists:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="User not found")
    users = list_following(db, user_id=user_id)
    return [UserPublic.model_validate(user) for user in users]
