from __future__ import annotations

from dataclasses import dataclass
from datetime import UTC, datetime

from sqlalchemy import and_, asc, or_, select
from sqlalchemy.orm import Session

from app.models.chat import (
    ChatType,
    MediaFile,
    Message,
    ScheduledMessage,
    ScheduledMessageAttachment,
    ScheduledMessageMode,
    ScheduledMessageStatus,
)
from app.models.user import User
from app.schemas.chat import MessageAttachmentOut, ScheduledMessageCreate, ScheduledMessageOut
from app.services.chat_service import (
    _media_url,
    chat_member_ids,
    create_message,
    get_chat_for_member,
    private_chat_peer_id,
    serialize_messages,
)
from app.services.user_service import ensure_private_messaging_allowed


@dataclass(frozen=True)
class ScheduledDispatchResult:
    scheduled_message_id: int
    sender_id: int
    chat_id: int
    member_ids: set[int]
    serialized_message: dict


def _utc_now() -> datetime:
    return datetime.now(UTC)


def _normalize_scheduled_at(value: datetime | None) -> datetime | None:
    if value is None:
        return None
    if value.tzinfo is None:
        return value.replace(tzinfo=UTC)
    return value.astimezone(UTC)


def _user_online_now(user: User | None) -> bool:
    if user is None or user.last_seen_at is None:
        return False
    last_seen = user.last_seen_at
    if last_seen.tzinfo is None:
        last_seen = last_seen.replace(tzinfo=UTC)
    return (_utc_now() - last_seen).total_seconds() <= 90


def _serialize_media_rows(media_rows: list[MediaFile]) -> list[MessageAttachmentOut]:
    output: list[MessageAttachmentOut] = []
    for media in media_rows:
        output.append(
            MessageAttachmentOut(
                id=media.id,
                file_name=media.original_name,
                mime_type=media.mime_type,
                media_kind=media.media_kind,
                size_bytes=media.size_bytes,
                url=_media_url(media.storage_name) or "",
                is_image=media.media_kind.value == "image",
                is_audio=media.media_kind.value in {"audio", "voice"},
                is_video=media.media_kind.value == "video",
                is_voice=media.media_kind.value == "voice",
                width=media.width,
                height=media.height,
                duration_seconds=media.duration_seconds,
                thumbnail_url=_media_url(media.thumbnail_storage_name),
            )
        )
    return output


def serialize_scheduled_messages(
    db: Session,
    rows: list[ScheduledMessage],
) -> list[ScheduledMessageOut]:
    if not rows:
        return []

    scheduled_ids = [row.id for row in rows]
    attachment_links = list(
        db.scalars(
            select(ScheduledMessageAttachment)
            .where(ScheduledMessageAttachment.scheduled_message_id.in_(scheduled_ids))
            .order_by(
                ScheduledMessageAttachment.scheduled_message_id.asc(),
                ScheduledMessageAttachment.sort_order.asc(),
                ScheduledMessageAttachment.id.asc(),
            )
        ).all()
    )
    media_ids = [row.media_file_id for row in attachment_links]
    media_map = {
        media.id: media
        for media in db.scalars(select(MediaFile).where(MediaFile.id.in_(media_ids))).all()
    }
    attachments_by_scheduled_id: dict[int, list[MediaFile]] = {}
    for link in attachment_links:
        media = media_map.get(link.media_file_id)
        if media is None:
            continue
        attachments_by_scheduled_id.setdefault(link.scheduled_message_id, []).append(media)

    return [
        ScheduledMessageOut(
            id=row.id,
            chat_id=row.chat_id,
            sender_id=row.sender_id,
            target_user_id=row.target_user_id,
            content=row.content,
            mode=row.mode,
            status=row.status,
            send_at=row.send_at,
            reply_to_message_id=row.reply_to_message_id,
            attachments=_serialize_media_rows(attachments_by_scheduled_id.get(row.id, [])),
            error_message=row.error_message,
            created_at=row.created_at,
            updated_at=row.updated_at,
            dispatched_at=row.dispatched_at,
            canceled_at=row.canceled_at,
            dispatched_message_id=row.dispatched_message_id,
        )
        for row in rows
    ]


def create_scheduled_message(
    db: Session,
    *,
    chat_id: int,
    sender_id: int,
    payload: ScheduledMessageCreate,
) -> ScheduledMessage:
    chat = get_chat_for_member(db, chat_id=chat_id, user_id=sender_id)
    clean_content = payload.content.strip()
    ordered_attachment_ids = list(dict.fromkeys(payload.attachment_ids))
    if not clean_content and not ordered_attachment_ids:
        raise ValueError("Scheduled message must contain text or attachment")

    normalized_send_at = _normalize_scheduled_at(payload.send_at)
    target_user_id: int | None = None
    if payload.mode == ScheduledMessageMode.AT_TIME:
        if normalized_send_at is None:
            raise ValueError("send_at is required for scheduled messages")
        if normalized_send_at <= _utc_now():
            raise ValueError("Choose a future time for scheduled delivery")
    else:
        if chat.type != ChatType.PRIVATE:
            raise ValueError("Send when online is available only in private chats")
        target_user_id = private_chat_peer_id(db, chat_id=chat_id, user_id=sender_id)
        if target_user_id is None:
            raise ValueError("Target user not found for this private chat")
        ensure_private_messaging_allowed(
            db,
            requester_id=sender_id,
            target_user_id=target_user_id,
        )

    if payload.reply_to_message_id is not None:
        reply_message = db.scalar(select(Message).where(Message.id == payload.reply_to_message_id))
        if reply_message is None or reply_message.chat_id != chat_id:
            raise ValueError("Reply target message not found in this chat")

    scheduled = ScheduledMessage(
        chat_id=chat_id,
        sender_id=sender_id,
        target_user_id=target_user_id,
        content=clean_content,
        mode=payload.mode,
        send_at=normalized_send_at,
        reply_to_message_id=payload.reply_to_message_id,
        status=ScheduledMessageStatus.PENDING,
        error_message=None,
    )
    db.add(scheduled)
    db.flush()

    if ordered_attachment_ids:
        media_rows = list(
            db.scalars(select(MediaFile).where(MediaFile.id.in_(ordered_attachment_ids))).all()
        )
        media_by_id = {row.id: row for row in media_rows}
        missing_ids = [media_id for media_id in ordered_attachment_ids if media_id not in media_by_id]
        if missing_ids:
            raise ValueError("Attachment not found")

        for idx, media_id in enumerate(ordered_attachment_ids):
            media = media_by_id[media_id]
            if media.uploader_id != sender_id:
                raise ValueError("Attachment belongs to another user")
            if media.chat_id != chat_id:
                raise ValueError("Attachment was uploaded for another chat")
            if media.is_committed:
                raise ValueError("Attachment is already used")

            media.is_committed = True
            db.add(
                ScheduledMessageAttachment(
                    scheduled_message_id=scheduled.id,
                    media_file_id=media.id,
                    sort_order=idx,
                )
            )

    db.commit()
    db.refresh(scheduled)
    return scheduled


def list_scheduled_messages(
    db: Session,
    *,
    chat_id: int,
    sender_id: int,
    include_dispatched: bool = False,
) -> list[ScheduledMessage]:
    _ = get_chat_for_member(db, chat_id=chat_id, user_id=sender_id)
    statement = (
        select(ScheduledMessage)
        .where(
            ScheduledMessage.chat_id == chat_id,
            ScheduledMessage.sender_id == sender_id,
        )
        .order_by(
            asc(ScheduledMessage.send_at.is_(None)),
            asc(ScheduledMessage.send_at),
            asc(ScheduledMessage.created_at),
            asc(ScheduledMessage.id),
        )
    )
    if not include_dispatched:
        statement = statement.where(
            ScheduledMessage.status.in_(
                [
                    ScheduledMessageStatus.PENDING,
                    ScheduledMessageStatus.FAILED,
                ]
            )
        )
    return list(db.scalars(statement).all())


def cancel_scheduled_message(
    db: Session,
    *,
    scheduled_message_id: int,
    sender_id: int,
    chat_id: int | None = None,
) -> ScheduledMessage:
    row = db.scalar(select(ScheduledMessage).where(ScheduledMessage.id == scheduled_message_id))
    if row is None:
        raise ValueError("Scheduled message not found")
    if chat_id is not None and row.chat_id != chat_id:
        raise ValueError("Scheduled message not found")
    _ = get_chat_for_member(db, chat_id=row.chat_id, user_id=sender_id)
    if row.sender_id != sender_id:
        raise ValueError("Only the sender can cancel a scheduled message")
    if row.status not in {ScheduledMessageStatus.PENDING, ScheduledMessageStatus.FAILED}:
        raise ValueError("Scheduled message can no longer be canceled")

    attachment_ids = list(
        db.scalars(
            select(ScheduledMessageAttachment.media_file_id).where(
                ScheduledMessageAttachment.scheduled_message_id == row.id
            )
        ).all()
    )
    if attachment_ids:
        for media in db.scalars(select(MediaFile).where(MediaFile.id.in_(attachment_ids))).all():
            media.is_committed = False

    row.status = ScheduledMessageStatus.CANCELED
    row.canceled_at = _utc_now()
    row.error_message = None
    db.add(row)
    db.commit()
    db.refresh(row)
    return row


def dispatch_due_scheduled_messages(
    db: Session,
    *,
    limit: int = 50,
) -> list[ScheduledDispatchResult]:
    now = _utc_now()
    candidates = list(
        db.scalars(
            select(ScheduledMessage)
            .where(ScheduledMessage.status == ScheduledMessageStatus.PENDING)
            .order_by(
                asc(ScheduledMessage.send_at.is_(None)),
                asc(ScheduledMessage.send_at),
                asc(ScheduledMessage.created_at),
                asc(ScheduledMessage.id),
            )
            .limit(limit * 3)
        ).all()
    )

    dispatched: list[ScheduledDispatchResult] = []
    for row in candidates:
        if len(dispatched) >= limit:
            break
        if not _is_due(db, row, now=now):
            continue
        result = _dispatch_single(db, row, now=now)
        if result is not None:
            dispatched.append(result)
    return dispatched


def _is_due(db: Session, row: ScheduledMessage, *, now: datetime) -> bool:
    if row.status != ScheduledMessageStatus.PENDING:
        return False
    if row.mode == ScheduledMessageMode.AT_TIME:
        if row.send_at is None:
            return False
        send_at = row.send_at if row.send_at.tzinfo else row.send_at.replace(tzinfo=UTC)
        return send_at <= now
    if row.target_user_id is None:
        return False
    target_user = db.scalar(select(User).where(User.id == row.target_user_id))
    return _user_online_now(target_user)


def _dispatch_single(
    db: Session,
    row: ScheduledMessage,
    *,
    now: datetime,
) -> ScheduledDispatchResult | None:
    attachment_ids = list(
        db.scalars(
            select(ScheduledMessageAttachment.media_file_id)
            .where(ScheduledMessageAttachment.scheduled_message_id == row.id)
            .order_by(ScheduledMessageAttachment.sort_order.asc(), ScheduledMessageAttachment.id.asc())
        ).all()
    )

    try:
        message = create_message(
            db,
            chat_id=row.chat_id,
            sender_id=row.sender_id,
            content=row.content,
            reply_to_message_id=row.reply_to_message_id,
            attachment_ids=attachment_ids,
            allow_committed_attachment_ids=set(attachment_ids),
            auto_commit=False,
        )
        row.status = ScheduledMessageStatus.DISPATCHED
        row.dispatched_at = now
        row.dispatched_message_id = message.id
        row.error_message = None
        db.add(row)
        serialized = serialize_messages(db, [message], user_id=row.sender_id)[0]
        db.commit()
        return ScheduledDispatchResult(
            scheduled_message_id=row.id,
            sender_id=row.sender_id,
            chat_id=row.chat_id,
            member_ids=chat_member_ids(db, row.chat_id),
            serialized_message=serialized.model_dump(mode="json"),
        )
    except Exception as exc:
        db.rollback()
        failed_row = db.scalar(select(ScheduledMessage).where(ScheduledMessage.id == row.id))
        if failed_row is None:
            return None
        failed_row.status = ScheduledMessageStatus.FAILED
        failed_row.error_message = str(exc)[:300]
        db.add(failed_row)
        db.commit()
        return None
