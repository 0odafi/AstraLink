from fastapi import APIRouter, Depends, Query, status
from sqlalchemy.orm import Session

from app.api.deps import get_current_user, get_db
from app.models.user import User
from app.schemas.social import PostCreate, PostOut, PostReactionCreate
from app.services.social_service import (
    create_post,
    react_to_post,
    remove_post_reaction,
    user_feed,
    user_posts,
)

router = APIRouter(prefix="/social", tags=["Social"])


@router.post("/posts", response_model=PostOut, status_code=status.HTTP_201_CREATED)
def create_post_endpoint(
    payload: PostCreate,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> PostOut:
    post = create_post(db, author_id=current_user.id, payload=payload)
    return PostOut.model_validate(post)


@router.get("/feed", response_model=list[PostOut])
def feed(
    limit: int = Query(default=50, ge=1, le=200),
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> list[PostOut]:
    posts = user_feed(db, user_id=current_user.id, limit=limit)
    return [PostOut.model_validate(post) for post in posts]


@router.get("/users/{user_id}/posts", response_model=list[PostOut])
def posts_by_user(
    user_id: int,
    limit: int = Query(default=50, ge=1, le=200),
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> list[PostOut]:
    posts = user_posts(db, viewer_id=current_user.id, author_id=user_id, limit=limit)
    return [PostOut.model_validate(post) for post in posts]


@router.post("/posts/{post_id}/reactions", status_code=status.HTTP_201_CREATED)
def add_reaction(
    post_id: int,
    payload: PostReactionCreate,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> dict:
    reaction = react_to_post(db, post_id=post_id, user_id=current_user.id, emoji=payload.emoji)
    return {"id": reaction.id, "post_id": reaction.post_id, "user_id": reaction.user_id, "emoji": reaction.emoji}


@router.delete("/posts/{post_id}/reactions")
def remove_reaction(
    post_id: int,
    emoji: str = Query(..., min_length=1, max_length=12),
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> dict:
    removed = remove_post_reaction(db, post_id=post_id, user_id=current_user.id, emoji=emoji)
    return {"post_id": post_id, "emoji": emoji, "removed": removed}
