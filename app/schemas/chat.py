from datetime import datetime

from pydantic import BaseModel, Field, model_validator

from app.models.chat import (
    ChatType,
    MediaKind,
    MemberRole,
    MessageDeliveryStatus,
    ScheduledMessageMode,
    ScheduledMessageStatus,
)


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
    is_archived: bool = False
    is_pinned: bool = False
    folder: str | None = None

    model_config = {"from_attributes": True}


class ChatStateUpdate(BaseModel):
    is_archived: bool | None = None
    is_pinned: bool | None = None
    folder: str | None = Field(default=None, max_length=32)


class ChatStateOut(BaseModel):
    chat_id: int
    is_archived: bool
    is_pinned: bool
    folder: str | None


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


class ScheduledMessageCreate(BaseModel):
    content: str = Field(default="", max_length=10000)
    reply_to_message_id: int | None = None
    attachment_ids: list[int] = Field(default_factory=list)
    mode: ScheduledMessageMode = ScheduledMessageMode.AT_TIME
    send_at: datetime | None = None

    @model_validator(mode="after")
    def validate_payload(self):
        has_content = bool(self.content.strip())
        has_attachments = bool(self.attachment_ids)
        if not has_content and not has_attachments:
            raise ValueError("Scheduled message must contain text or attachment")
        if self.mode == ScheduledMessageMode.AT_TIME and self.send_at is None:
            raise ValueError("send_at is required for scheduled messages")
        if self.mode == ScheduledMessageMode.WHEN_ONLINE and self.send_at is not None:
            self.send_at = None
        return self


class MessageAttachmentOut(BaseModel):
    id: int
    file_name: str
    mime_type: str
    media_kind: MediaKind = MediaKind.FILE
    size_bytes: int
    url: str
    is_image: bool = False
    is_audio: bool = False
    is_video: bool = False
    is_voice: bool = False
    width: int | None = None
    height: int | None = None
    duration_seconds: int | None = None
    thumbnail_url: str | None = None


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


class MessageSearchOut(BaseModel):
    chat_id: int
    message_id: int
    chat_title: str
    sender_id: int
    content: str
    created_at: datetime


class MessageUpdate(BaseModel):
    content: str = Field(min_length=1, max_length=10000)


class ScheduledMessageOut(BaseModel):
    id: int
    chat_id: int
    sender_id: int
    target_user_id: int | None = None
    content: str
    mode: ScheduledMessageMode
    status: ScheduledMessageStatus
    send_at: datetime | None = None
    reply_to_message_id: int | None = None
    attachments: list[MessageAttachmentOut] = Field(default_factory=list)
    error_message: str | None = None
    created_at: datetime
    updated_at: datetime
    dispatched_at: datetime | None = None
    canceled_at: datetime | None = None
    dispatched_message_id: int | None = None


class MediaUploadOut(BaseModel):
    id: int
    file_name: str
    mime_type: str
    media_kind: MediaKind = MediaKind.FILE
    size_bytes: int
    url: str
    is_image: bool = False
    is_audio: bool = False
    is_video: bool = False
    is_voice: bool = False
    width: int | None = None
    height: int | None = None
    duration_seconds: int | None = None
    thumbnail_url: str | None = None
