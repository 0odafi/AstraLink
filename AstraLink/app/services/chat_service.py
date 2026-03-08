from collections import defaultdict
from datetime import UTC, datetime

from sqlalchemy import and_, desc, func, or_, select
from sqlalchemy.orm import Session

from app.core.config import get_settings
from app.models.chat import (
    Chat,
    ChatMember,
    ChatType,
    MediaFile,
    MemberRole,
    Message,
    MessageAttachment,
    MessageDelivery,
    MessageDeliveryStatus,
    MessageLink,
    MessageReaction,
    PinnedMessage,
)
from app.models.user import User
from app.schemas.chat import ChatCreate, MessageAttachmentOut, MessageOut, MessageReactionSummary


def create_chat(db: Session, owner_id: int, payload: ChatCreate) -> Chat:
    if payload.type.value == "private" and len(payload.member_ids) != 1:
        raise ValueError("Private chats must include exactly one target user ID")

    chat = Chat(
        title=payload.title,
        description=payload.description,
        type=payload.type,
        is_public=payload.is_public,
        owner_id=owner_id,
    )
    db.add(chat)
    db.flush()

    db.add(ChatMember(chat_id=chat.id, user_id=owner_id, role=MemberRole.OWNER))
    unique_members = {member_id for member_id in payload.member_ids if member_id != owner_id}
    for member_id in unique_members:
        if not db.scalar(select(User).where(User.id == member_id)):
            continue
        db.add(ChatMember(chat_id=chat.id, user_id=member_id, role=MemberRole.MEMBER))

    db.commit()
    db.refresh(chat)
    return chat


def get_user_chats(db: Session, user_id: int) -> list[Chat]:
    statement = (
        select(Chat)
        .join(ChatMember, ChatMember.chat_id == Chat.id)
        .where(ChatMember.user_id == user_id)
    )
    chats = list(db.scalars(statement).all())
    for chat in chats:
        last_message = db.scalar(
            select(Message).where(Message.chat_id == chat.id).order_by(Message.id.desc()).limit(1)
        )
        last_preview = last_message.content if last_message else None
        if isinstance(last_preview, str) and len(last_preview) > 140:
            last_preview = f"{last_preview[:140]}..."

        unread_count = db.scalar(
            select(func.count(Message.id))
            .select_from(Message)
            .outerjoin(
                MessageDelivery,
                and_(
                    MessageDelivery.message_id == Message.id,
                    MessageDelivery.user_id == user_id,
                ),
            )
            .where(
                and_(
                    Message.chat_id == chat.id,
                    Message.sender_id != user_id,
                    or_(
                        MessageDelivery.id.is_(None),
                        MessageDelivery.status != MessageDeliveryStatus.READ,
                    ),
                )
            )
        )

        setattr(chat, "last_message_preview", last_preview)
        setattr(chat, "last_message_at", last_message.created_at if last_message else None)
        setattr(chat, "unread_count", int(unread_count or 0))
        setattr(chat, "_sort_ts", last_message.created_at if last_message else chat.created_at)

    chats.sort(key=lambda chat: getattr(chat, "_sort_ts", chat.created_at), reverse=True)
    return chats


def get_chat_for_member(db: Session, chat_id: int, user_id: int) -> Chat:
    chat = db.scalar(
        select(Chat)
        .join(ChatMember, ChatMember.chat_id == Chat.id)
        .where(and_(Chat.id == chat_id, ChatMember.user_id == user_id))
    )
    if not chat:
        raise ValueError("Chat not found or access denied")
    return chat


def _get_membership(db: Session, chat_id: int, user_id: int) -> ChatMember | None:
    return db.scalar(select(ChatMember).where(and_(ChatMember.chat_id == chat_id, ChatMember.user_id == user_id)))


def _require_member(db: Session, chat_id: int, user_id: int) -> ChatMember:
    membership = _get_membership(db, chat_id=chat_id, user_id=user_id)
    if not membership:
        raise ValueError("You are not a member of this chat")
    return membership


def _require_admin_or_owner(db: Session, chat_id: int, user_id: int) -> ChatMember:
    membership = _require_member(db, chat_id=chat_id, user_id=user_id)
    if membership.role not in {MemberRole.OWNER, MemberRole.ADMIN}:
        raise ValueError("Only owner/admin can perform this action")
    return membership


def _media_url(storage_name: str) -> str:
    settings = get_settings()
    base = settings.media_url_path.rstrip("/")
    if not base:
        base = "/media"
    if not base.startswith("/"):
        base = f"/{base}"
    return f"{base}/{storage_name}"


def add_member(db: Session, chat_id: int, requester_id: int, user_id: int, role: MemberRole) -> ChatMember:
    _require_admin_or_owner(db, chat_id=chat_id, user_id=requester_id)

    target_user = db.scalar(select(User).where(User.id == user_id))
    if not target_user:
        raise ValueError("Target user does not exist")

    existing = db.scalar(select(ChatMember).where(and_(ChatMember.chat_id == chat_id, ChatMember.user_id == user_id)))
    if existing:
        return existing

    member = ChatMember(chat_id=chat_id, user_id=user_id, role=role)
    db.add(member)
    db.commit()
    db.refresh(member)
    return member


def create_message(
    db: Session,
    chat_id: int,
    sender_id: int,
    content: str,
    reply_to_message_id: int | None = None,
    forward_from_message_id: int | None = None,
    attachment_ids: list[int] | None = None,
) -> Message:
    _require_member(db, chat_id=chat_id, user_id=sender_id)
    clean_content = content.strip()
    ordered_attachment_ids = list(dict.fromkeys(attachment_ids or []))
    if not clean_content and not ordered_attachment_ids:
        raise ValueError("Message must contain text or attachment")

    if reply_to_message_id is not None:
        reply_message = db.scalar(select(Message).where(Message.id == reply_to_message_id))
        if not reply_message or reply_message.chat_id != chat_id:
            raise ValueError("Reply target message not found in this chat")

    if forward_from_message_id is not None:
        source_message = db.scalar(select(Message).where(Message.id == forward_from_message_id))
        if not source_message:
            raise ValueError("Forward source message not found")
        _require_member(db, chat_id=source_message.chat_id, user_id=sender_id)

    message = Message(chat_id=chat_id, sender_id=sender_id, content=clean_content)
    db.add(message)
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
                MessageAttachment(
                    message_id=message.id,
                    media_file_id=media.id,
                    sort_order=idx,
                )
            )

    if reply_to_message_id is not None or forward_from_message_id is not None:
        db.add(
            MessageLink(
                message_id=message.id,
                reply_to_message_id=reply_to_message_id,
                forwarded_from_message_id=forward_from_message_id,
            )
        )

    member_ids = list(db.scalars(select(ChatMember.user_id).where(ChatMember.chat_id == chat_id)).all())
    for member_id in member_ids:
        status = MessageDeliveryStatus.READ if member_id == sender_id else MessageDeliveryStatus.DELIVERED
        db.add(
            MessageDelivery(
                message_id=message.id,
                user_id=member_id,
                status=status,
            )
        )

    db.commit()
    db.refresh(message)
    return message


def _mark_messages_read(db: Session, messages: list[Message], user_id: int) -> None:
    if not messages:
        return

    message_ids = [m.id for m in messages if m.sender_id != user_id]
    if not message_ids:
        return

    existing = list(
        db.scalars(
            select(MessageDelivery).where(
                and_(
                    MessageDelivery.user_id == user_id,
                    MessageDelivery.message_id.in_(message_ids),
                )
            )
        ).all()
    )
    existing_map = {row.message_id: row for row in existing}
    now = datetime.now(UTC)

    changed = False
    for message_id in message_ids:
        delivery = existing_map.get(message_id)
        if delivery is None:
            db.add(
                MessageDelivery(
                    message_id=message_id,
                    user_id=user_id,
                    status=MessageDeliveryStatus.READ,
                    updated_at=now,
                )
            )
            changed = True
            continue

        if delivery.status != MessageDeliveryStatus.READ:
            delivery.status = MessageDeliveryStatus.READ
            delivery.updated_at = now
            changed = True

    if changed:
        db.commit()


def _delivery_rank(status: MessageDeliveryStatus) -> int:
    if status == MessageDeliveryStatus.SENT:
        return 0
    if status == MessageDeliveryStatus.DELIVERED:
        return 1
    return 2


def _aggregate_sender_status(peer_statuses: list[MessageDeliveryStatus]) -> MessageDeliveryStatus:
    if not peer_statuses:
        return MessageDeliveryStatus.READ
    if all(value == MessageDeliveryStatus.READ for value in peer_statuses):
        return MessageDeliveryStatus.READ
    if all(value in {MessageDeliveryStatus.DELIVERED, MessageDeliveryStatus.READ} for value in peer_statuses):
        return MessageDeliveryStatus.DELIVERED
    return MessageDeliveryStatus.SENT


def serialize_messages(db: Session, messages: list[Message], user_id: int) -> list[MessageOut]:
    if not messages:
        return []

    message_ids = [m.id for m in messages]
    links = list(db.scalars(select(MessageLink).where(MessageLink.message_id.in_(message_ids))).all())
    links_map = {link.message_id: link for link in links}

    all_deliveries = list(
        db.scalars(select(MessageDelivery).where(MessageDelivery.message_id.in_(message_ids))).all()
    )
    deliveries_by_message: dict[int, list[MessageDelivery]] = defaultdict(list)
    viewer_deliveries: dict[int, MessageDelivery] = {}
    for delivery in all_deliveries:
        deliveries_by_message[delivery.message_id].append(delivery)
        if delivery.user_id == user_id:
            viewer_deliveries[delivery.message_id] = delivery

    pinned_message_ids = set(
        db.scalars(select(PinnedMessage.message_id).where(PinnedMessage.message_id.in_(message_ids))).all()
    )
    all_reactions = list(
        db.scalars(select(MessageReaction).where(MessageReaction.message_id.in_(message_ids))).all()
    )
    reactions_by_message: dict[int, dict[str, set[int]]] = defaultdict(lambda: defaultdict(set))
    for reaction in all_reactions:
        reactions_by_message[reaction.message_id][reaction.emoji].add(reaction.user_id)

    attachment_links = list(
        db.scalars(
            select(MessageAttachment)
            .where(MessageAttachment.message_id.in_(message_ids))
            .order_by(MessageAttachment.message_id.asc(), MessageAttachment.sort_order.asc(), MessageAttachment.id.asc())
        ).all()
    )
    media_ids = [row.media_file_id for row in attachment_links]
    media_map = {
        media.id: media
        for media in db.scalars(select(MediaFile).where(MediaFile.id.in_(media_ids))).all()
    }
    attachments_by_message: dict[int, list[MessageAttachmentOut]] = defaultdict(list)
    for row in attachment_links:
        media = media_map.get(row.media_file_id)
        if media is None:
            continue
        mime = media.mime_type or "application/octet-stream"
        attachments_by_message[row.message_id].append(
            MessageAttachmentOut(
                id=media.id,
                file_name=media.original_name,
                mime_type=mime,
                size_bytes=media.size_bytes,
                url=_media_url(media.storage_name),
                is_image=mime.startswith("image/"),
            )
        )

    result: list[MessageOut] = []
    for message in messages:
        link = links_map.get(message.id)
        if message.sender_id == user_id:
            peer_statuses = [
                row.status for row in deliveries_by_message.get(message.id, []) if row.user_id != user_id
            ]
            status = _aggregate_sender_status(peer_statuses)
        else:
            delivery = viewer_deliveries.get(message.id)
            status = delivery.status if delivery else MessageDeliveryStatus.SENT

        result.append(
            MessageOut(
                id=message.id,
                chat_id=message.chat_id,
                sender_id=message.sender_id,
                content=message.content,
                created_at=message.created_at,
                edited_at=message.edited_at,
                status=status,
                reply_to_message_id=link.reply_to_message_id if link else None,
                forwarded_from_message_id=link.forwarded_from_message_id if link else None,
                is_pinned=message.id in pinned_message_ids,
                reactions=[
                    MessageReactionSummary(
                        emoji=emoji,
                        count=len(user_ids),
                        reacted_by_me=user_id in user_ids,
                    )
                    for emoji, user_ids in sorted(reactions_by_message[message.id].items())
                ],
                attachments=attachments_by_message.get(message.id, []),
            )
        )
    return result


def list_messages(db: Session, chat_id: int, user_id: int, limit: int = 100) -> list[Message]:
    rows, _ = list_messages_cursor(db, chat_id=chat_id, user_id=user_id, limit=limit, before_id=None)
    return rows


def list_messages_cursor(
    db: Session,
    chat_id: int,
    user_id: int,
    limit: int = 100,
    before_id: int | None = None,
) -> tuple[list[Message], int | None]:
    _ = get_chat_for_member(db, chat_id=chat_id, user_id=user_id)
    statement = select(Message).where(Message.chat_id == chat_id)
    if before_id is not None:
        statement = statement.where(Message.id < before_id)
    statement = statement.order_by(desc(Message.id)).limit(limit + 1)

    rows_desc = list(db.scalars(statement).all())
    has_more = len(rows_desc) > limit
    if has_more:
        rows_desc = rows_desc[:limit]
        next_before_id = rows_desc[-1].id
    else:
        next_before_id = None

    rows_desc.reverse()
    _mark_messages_read(db, rows_desc, user_id=user_id)
    return rows_desc, next_before_id


def update_message_content(db: Session, message_id: int, user_id: int, content: str) -> Message:
    message = db.scalar(select(Message).where(Message.id == message_id))
    if not message:
        raise ValueError("Message not found")

    _require_member(db, chat_id=message.chat_id, user_id=user_id)
    if message.sender_id != user_id:
        raise ValueError("Only sender can edit message")

    message.content = content
    message.edited_at = datetime.now(UTC)
    db.commit()
    db.refresh(message)
    return message


def delete_message(db: Session, message_id: int, user_id: int) -> int | None:
    message = db.scalar(select(Message).where(Message.id == message_id))
    if not message:
        return None

    membership = _require_member(db, chat_id=message.chat_id, user_id=user_id)
    if message.sender_id != user_id and membership.role not in {MemberRole.OWNER, MemberRole.ADMIN}:
        raise ValueError("Only sender or admin/owner can delete message")

    chat_id = message.chat_id
    db.delete(message)
    db.commit()
    return chat_id


def pin_message(db: Session, chat_id: int, message_id: int, user_id: int) -> PinnedMessage:
    _require_admin_or_owner(db, chat_id=chat_id, user_id=user_id)

    message = db.scalar(select(Message).where(Message.id == message_id))
    if not message or message.chat_id != chat_id:
        raise ValueError("Message not found in this chat")

    existing = db.scalar(
        select(PinnedMessage).where(
            and_(
                PinnedMessage.chat_id == chat_id,
                PinnedMessage.message_id == message_id,
            )
        )
    )
    if existing:
        return existing

    pin = PinnedMessage(chat_id=chat_id, message_id=message_id, pinned_by_id=user_id)
    db.add(pin)
    db.commit()
    db.refresh(pin)
    return pin


def unpin_message(db: Session, chat_id: int, message_id: int, user_id: int) -> bool:
    _require_admin_or_owner(db, chat_id=chat_id, user_id=user_id)
    pin = db.scalar(
        select(PinnedMessage).where(
            and_(
                PinnedMessage.chat_id == chat_id,
                PinnedMessage.message_id == message_id,
            )
        )
    )
    if not pin:
        return False
    db.delete(pin)
    db.commit()
    return True


def react_to_message(db: Session, message_id: int, user_id: int, emoji: str) -> MessageReaction:
    message = db.scalar(select(Message).where(Message.id == message_id))
    if not message:
        raise ValueError("Message not found")

    _ = _require_member(db, chat_id=message.chat_id, user_id=user_id)

    existing = db.scalar(
        select(MessageReaction).where(
            and_(
                MessageReaction.message_id == message_id,
                MessageReaction.user_id == user_id,
                MessageReaction.emoji == emoji,
            )
        )
    )
    if existing:
        return existing

    reaction = MessageReaction(message_id=message_id, user_id=user_id, emoji=emoji)
    db.add(reaction)
    db.commit()
    db.refresh(reaction)
    return reaction


def remove_message_reaction(db: Session, message_id: int, user_id: int, emoji: str) -> bool:
    reaction = db.scalar(
        select(MessageReaction).where(
            and_(
                MessageReaction.message_id == message_id,
                MessageReaction.user_id == user_id,
                MessageReaction.emoji == emoji,
            )
        )
    )
    if not reaction:
        return False
    db.delete(reaction)
    db.commit()
    return True


def update_message_delivery_status(
    db: Session,
    message_id: int,
    user_id: int,
    status: MessageDeliveryStatus,
    chat_id: int | None = None,
) -> tuple[Message, MessageDeliveryStatus, MessageDeliveryStatus, bool]:
    message = db.scalar(select(Message).where(Message.id == message_id))
    if not message:
        raise ValueError("Message not found")
    if chat_id is not None and message.chat_id != chat_id:
        raise ValueError("Message is not in this chat")

    _ = _require_member(db, chat_id=message.chat_id, user_id=user_id)
    if message.sender_id == user_id:
        sender_peer_statuses = [
            row.status
            for row in db.scalars(select(MessageDelivery).where(MessageDelivery.message_id == message_id)).all()
            if row.user_id != user_id
        ]
        sender_status = _aggregate_sender_status(sender_peer_statuses)
        return message, MessageDeliveryStatus.READ, sender_status, False

    delivery = db.scalar(
        select(MessageDelivery).where(
            and_(
                MessageDelivery.message_id == message_id,
                MessageDelivery.user_id == user_id,
            )
        )
    )
    now = datetime.now(UTC)
    if delivery is None:
        delivery = MessageDelivery(
            message_id=message_id,
            user_id=user_id,
            status=status,
            updated_at=now,
        )
        db.add(delivery)
        changed = True
    else:
        if _delivery_rank(status) > _delivery_rank(delivery.status):
            delivery.status = status
            delivery.updated_at = now
            changed = True
        else:
            changed = False

    if changed:
        db.commit()
        db.refresh(delivery)
    else:
        db.flush()

    sender_peer_statuses = [
        row.status
        for row in db.scalars(select(MessageDelivery).where(MessageDelivery.message_id == message_id)).all()
        if row.user_id != message.sender_id
    ]
    sender_status = _aggregate_sender_status(sender_peer_statuses)
    return message, delivery.status, sender_status, changed


def can_access_chat(db: Session, chat_id: int, user_id: int) -> bool:
    membership = db.scalar(select(ChatMember).where(and_(ChatMember.chat_id == chat_id, ChatMember.user_id == user_id)))
    if membership:
        return True

    public_chat = db.scalar(
        select(Chat).where(
            and_(
                Chat.id == chat_id,
                or_(Chat.is_public.is_(True), Chat.type == ChatType.CHANNEL),
            )
        )
    )
    return bool(public_chat)


def chat_member_ids(db: Session, chat_id: int) -> set[int]:
    return set(db.scalars(select(ChatMember.user_id).where(ChatMember.chat_id == chat_id)).all())
