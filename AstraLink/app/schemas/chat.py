from datetime import datetime

from pydantic import BaseModel, Field

from app.models.chat import ChatType, MemberRole, MessageDeliveryStatus


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
    last_message_preview: str | None = None
    last_message_at: datetime | None = None
    unread_count: int = 0

    model_config = {"from_attributes": True}


class ChatMemberAdd(BaseModel):
    user_id: int
    role: MemberRole = MemberRole.MEMBER


class MessageCreate(BaseModel):
    content: str = Field(min_length=1, max_length=10000)
    reply_to_message_id: int | None = None
    forward_from_message_id: int | None = None


class MessageOut(BaseModel):
    id: int
    chat_id: int
    sender_id: int
    content: str
    created_at: datetime
    edited_at: datetime | None
    status: MessageDeliveryStatus = MessageDeliveryStatus.SENT
    reply_to_message_id: int | None = None
    forwarded_from_message_id: int | None = None
    is_pinned: bool = False

    model_config = {"from_attributes": True}


class ReactionCreate(BaseModel):
    emoji: str = Field(min_length=1, max_length=12)


class MessageCursorOut(BaseModel):
    items: list[MessageOut]
    next_before_id: int | None = None


class MessageUpdate(BaseModel):
    content: str = Field(min_length=1, max_length=10000)
