from datetime import datetime

from pydantic import BaseModel, Field, model_validator

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
    content: str = Field(default="", max_length=10000)
    reply_to_message_id: int | None = None
    forward_from_message_id: int | None = None
    attachment_ids: list[int] = Field(default_factory=list)

    @model_validator(mode="after")
    def validate_payload(self):
        has_content = bool(self.content.strip())
        has_attachments = bool(self.attachment_ids)
        if not has_content and not has_attachments:
            raise ValueError("Message must contain text or attachment")
        return self


class MessageAttachmentOut(BaseModel):
    id: int
    file_name: str
    mime_type: str
    size_bytes: int
    url: str
    is_image: bool = False


class MessageReactionSummary(BaseModel):
    emoji: str
    count: int
    reacted_by_me: bool = False


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
    reactions: list[MessageReactionSummary] = Field(default_factory=list)
    attachments: list[MessageAttachmentOut] = Field(default_factory=list)

    model_config = {"from_attributes": True}


class ReactionCreate(BaseModel):
    emoji: str = Field(min_length=1, max_length=12)


class MessageCursorOut(BaseModel):
    items: list[MessageOut]
    next_before_id: int | None = None


class MessageUpdate(BaseModel):
    content: str = Field(min_length=1, max_length=10000)


class MediaUploadOut(BaseModel):
    id: int
    file_name: str
    mime_type: str
    size_bytes: int
    url: str
    is_image: bool = False
