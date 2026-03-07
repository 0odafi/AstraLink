from sqlalchemy import and_, desc, or_, select
from sqlalchemy.orm import Session

from app.models.social import Post, PostReaction, PostVisibility
from app.models.user import Follow
from app.schemas.social import PostCreate


def create_post(db: Session, author_id: int, payload: PostCreate) -> Post:
    post = Post(
        author_id=author_id,
        content=payload.content,
        media_url=payload.media_url,
        visibility=payload.visibility,
    )
    db.add(post)
    db.commit()
    db.refresh(post)
    return post


def user_feed(db: Session, user_id: int, limit: int = 50) -> list[Post]:
    following_subquery = select(Follow.following_id).where(Follow.follower_id == user_id)

    statement = (
        select(Post)
        .where(
            or_(
                Post.author_id == user_id,
                and_(Post.visibility == PostVisibility.PUBLIC),
                and_(
                    Post.visibility == PostVisibility.FOLLOWERS,
                    Post.author_id.in_(following_subquery),
                ),
            )
        )
        .order_by(desc(Post.created_at))
        .limit(limit)
    )
    return list(db.scalars(statement).all())


def user_posts(db: Session, viewer_id: int, author_id: int, limit: int = 50) -> list[Post]:
    if viewer_id == author_id:
        statement = select(Post).where(Post.author_id == author_id).order_by(desc(Post.created_at)).limit(limit)
        return list(db.scalars(statement).all())

    follows_author = db.scalar(
        select(Follow).where(and_(Follow.follower_id == viewer_id, Follow.following_id == author_id))
    )

    if follows_author:
        statement = (
            select(Post)
            .where(
                and_(
                    Post.author_id == author_id,
                    Post.visibility.in_([PostVisibility.PUBLIC, PostVisibility.FOLLOWERS]),
                )
            )
            .order_by(desc(Post.created_at))
            .limit(limit)
        )
        return list(db.scalars(statement).all())

    statement = (
        select(Post)
        .where(and_(Post.author_id == author_id, Post.visibility == PostVisibility.PUBLIC))
        .order_by(desc(Post.created_at))
        .limit(limit)
    )
    return list(db.scalars(statement).all())


def react_to_post(db: Session, post_id: int, user_id: int, emoji: str) -> PostReaction:
    post = db.scalar(select(Post).where(Post.id == post_id))
    if not post:
        raise ValueError("Post not found")

    existing = db.scalar(
        select(PostReaction).where(
            and_(
                PostReaction.post_id == post_id,
                PostReaction.user_id == user_id,
                PostReaction.emoji == emoji,
            )
        )
    )
    if existing:
        return existing

    reaction = PostReaction(post_id=post_id, user_id=user_id, emoji=emoji)
    db.add(reaction)
    db.commit()
    db.refresh(reaction)
    return reaction


def remove_post_reaction(db: Session, post_id: int, user_id: int, emoji: str) -> bool:
    reaction = db.scalar(
        select(PostReaction).where(
            and_(
                PostReaction.post_id == post_id,
                PostReaction.user_id == user_id,
                PostReaction.emoji == emoji,
            )
        )
    )
    if not reaction:
        return False
    db.delete(reaction)
    db.commit()
    return True
