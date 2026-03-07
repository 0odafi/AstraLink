from datetime import datetime

from pydantic import BaseModel, Field

from app.models.chat import ChatType, MemberRole


class ChatCreate(BaseModel):
    title: str = Field(min_length=1, max_length=120)
    description: str = Field(default="", max_length=2000)
    type: ChatType = ChatType.GROUP
    is_public: bool = False
    member_ids: list[int] = Field(default_factory=list)


class ChatOut(BaseModel):
    id: int
    title: str
    description: str
    type: ChatType
    is_public: bool
    owner_id: int
    created_at: datetime

    model_config = {"from_attributes": True}


class ChatMemberAdd(BaseModel):
    user_id: int
    role: MemberRole = MemberRole.MEMBER


class MessageCreate(BaseModel):
    content: str = Field(min_length=1, max_length=10000)


class MessageOut(BaseModel):
    id: int
    chat_id: int
    sender_id: int
    content: str
    created_at: datetime
    edited_at: datetime | None

    model_config = {"from_attributes": True}


class ReactionCreate(BaseModel):
    emoji: str = Field(min_length=1, max_length=12)
