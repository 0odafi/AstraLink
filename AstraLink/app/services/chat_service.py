from sqlalchemy import and_, desc, or_, select
from sqlalchemy.orm import Session

from app.models.chat import Chat, ChatMember, ChatType, MemberRole, Message, MessageReaction
from app.models.user import User
from app.schemas.chat import ChatCreate


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
        .order_by(Chat.created_at.desc())
    )
    return list(db.scalars(statement).all())


def get_chat_for_member(db: Session, chat_id: int, user_id: int) -> Chat:
    chat = db.scalar(
        select(Chat)
        .join(ChatMember, ChatMember.chat_id == Chat.id)
        .where(and_(Chat.id == chat_id, ChatMember.user_id == user_id))
    )
    if not chat:
        raise ValueError("Chat not found or access denied")
    return chat


def add_member(db: Session, chat_id: int, requester_id: int, user_id: int, role: MemberRole) -> ChatMember:
    requester = db.scalar(
        select(ChatMember).where(and_(ChatMember.chat_id == chat_id, ChatMember.user_id == requester_id))
    )
    if not requester or requester.role not in {MemberRole.OWNER, MemberRole.ADMIN}:
        raise ValueError("Only owner/admin can add members")

    target_user = db.scalar(select(User).where(User.id == user_id))
    if not target_user:
        raise ValueError("Target user does not exist")

    existing = db.scalar(
        select(ChatMember).where(and_(ChatMember.chat_id == chat_id, ChatMember.user_id == user_id))
    )
    if existing:
        return existing

    member = ChatMember(chat_id=chat_id, user_id=user_id, role=role)
    db.add(member)
    db.commit()
    db.refresh(member)
    return member


def create_message(db: Session, chat_id: int, sender_id: int, content: str) -> Message:
    membership = db.scalar(
        select(ChatMember).where(and_(ChatMember.chat_id == chat_id, ChatMember.user_id == sender_id))
    )
    if not membership:
        raise ValueError("You are not a member of this chat")

    message = Message(chat_id=chat_id, sender_id=sender_id, content=content)
    db.add(message)
    db.commit()
    db.refresh(message)
    return message


def list_messages(db: Session, chat_id: int, user_id: int, limit: int = 100) -> list[Message]:
    _ = get_chat_for_member(db, chat_id=chat_id, user_id=user_id)
    statement = (
        select(Message)
        .where(Message.chat_id == chat_id)
        .order_by(desc(Message.created_at))
        .limit(limit)
    )
    rows = list(db.scalars(statement).all())
    rows.reverse()
    return rows


def react_to_message(db: Session, message_id: int, user_id: int, emoji: str) -> MessageReaction:
    message = db.scalar(select(Message).where(Message.id == message_id))
    if not message:
        raise ValueError("Message not found")

    membership = db.scalar(
        select(ChatMember).where(and_(ChatMember.chat_id == message.chat_id, ChatMember.user_id == user_id))
    )
    if not membership:
        raise ValueError("Not allowed to react in this chat")

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


def can_access_chat(db: Session, chat_id: int, user_id: int) -> bool:
    membership = db.scalar(
        select(ChatMember).where(and_(ChatMember.chat_id == chat_id, ChatMember.user_id == user_id))
    )
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
