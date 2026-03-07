from datetime import datetime

from pydantic import BaseModel, Field

from app.models.social import PostVisibility


class PostCreate(BaseModel):
    content: str = Field(min_length=1, max_length=10000)
    media_url: str | None = Field(default=None, max_length=500)
    visibility: PostVisibility = PostVisibility.PUBLIC


class PostOut(BaseModel):
    id: int
    author_id: int
    content: str
    media_url: str | None
    visibility: PostVisibility
    created_at: datetime
    updated_at: datetime

    model_config = {"from_attributes": True}


class PostReactionCreate(BaseModel):
    emoji: str = Field(min_length=1, max_length=12)
