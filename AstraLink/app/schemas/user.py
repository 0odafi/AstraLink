from datetime import datetime

from pydantic import BaseModel, Field


class UserPublic(BaseModel):
    id: int
    username: str | None
    phone: str | None
    first_name: str
    last_name: str
    bio: str
    avatar_url: str | None
    created_at: datetime

    model_config = {"from_attributes": True}


class ProfileUpdate(BaseModel):
    bio: str | None = Field(default=None, max_length=1000)
    avatar_url: str | None = Field(default=None, max_length=500)
    username: str | None = Field(default=None, max_length=32)
    first_name: str | None = Field(default=None, min_length=1, max_length=80)
    last_name: str | None = Field(default=None, min_length=1, max_length=80)


class UsernameCheckOut(BaseModel):
    username: str
    available: bool
