from datetime import datetime

from pydantic import BaseModel, Field


class UserPublic(BaseModel):
    id: int
    username: str
    email: str
    bio: str
    avatar_url: str | None
    created_at: datetime

    model_config = {"from_attributes": True}


class ProfileUpdate(BaseModel):
    bio: str | None = Field(default=None, max_length=1000)
    avatar_url: str | None = Field(default=None, max_length=500)


class FollowActionResult(BaseModel):
    follower_id: int
    following_id: int
    is_following: bool
