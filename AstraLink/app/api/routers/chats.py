from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy.orm import Session

from app.api.deps import get_current_user, get_db
from app.models.user import User
from app.realtime.manager import chat_manager
from app.schemas.chat import (
    ChatCreate,
    ChatMemberAdd,
    ChatOut,
    MessageCreate,
    MessageCursorOut,
    MessageOut,
    MessageUpdate,
    ReactionCreate,
)
from app.services.chat_service import (
    add_member,
    create_chat,
    create_message,
    delete_message,
    get_user_chats,
    list_messages,
    list_messages_cursor,
    pin_message,
    react_to_message,
    remove_message_reaction,
    serialize_messages,
    unpin_message,
    update_message_content,
)

router = APIRouter(prefix="/chats", tags=["Chats"])


@router.post("", response_model=ChatOut, status_code=status.HTTP_201_CREATED)
def create_chat_endpoint(
    payload: ChatCreate,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> ChatOut:
    try:
        chat = create_chat(db, owner_id=current_user.id, payload=payload)
    except ValueError as exc:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(exc)) from exc
    return ChatOut.model_validate(chat)


@router.get("", response_model=list[ChatOut])
def list_chats(
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> list[ChatOut]:
    chats = get_user_chats(db, user_id=current_user.id)
    return [ChatOut.model_validate(chat) for chat in chats]


@router.post("/{chat_id}/members", status_code=status.HTTP_201_CREATED)
def add_chat_member(
    chat_id: int,
    payload: ChatMemberAdd,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> dict:
    try:
        member = add_member(
            db,
            chat_id=chat_id,
            requester_id=current_user.id,
            user_id=payload.user_id,
            role=payload.role,
        )
    except ValueError as exc:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(exc)) from exc
    return {"chat_id": member.chat_id, "user_id": member.user_id, "role": member.role}


@router.get("/{chat_id}/messages", response_model=list[MessageOut])
def get_messages(
    chat_id: int,
    limit: int = Query(default=100, ge=1, le=500),
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> list[MessageOut]:
    try:
        messages = list_messages(db, chat_id=chat_id, user_id=current_user.id, limit=limit)
    except ValueError as exc:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail=str(exc)) from exc
    return serialize_messages(db, messages, user_id=current_user.id)


@router.get("/{chat_id}/messages/cursor", response_model=MessageCursorOut)
def get_messages_cursor(
    chat_id: int,
    limit: int = Query(default=50, ge=1, le=200),
    before_id: int | None = Query(default=None, ge=1),
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> MessageCursorOut:
    try:
        messages, next_before_id = list_messages_cursor(
            db,
            chat_id=chat_id,
            user_id=current_user.id,
            limit=limit,
            before_id=before_id,
        )
    except ValueError as exc:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail=str(exc)) from exc
    return MessageCursorOut(items=serialize_messages(db, messages, user_id=current_user.id), next_before_id=next_before_id)


@router.post("/{chat_id}/messages", response_model=MessageOut, status_code=status.HTTP_201_CREATED)
async def post_message(
    chat_id: int,
    payload: MessageCreate,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> MessageOut:
    try:
        message = create_message(
            db,
            chat_id=chat_id,
            sender_id=current_user.id,
            content=payload.content,
            reply_to_message_id=payload.reply_to_message_id,
            forward_from_message_id=payload.forward_from_message_id,
        )
    except ValueError as exc:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(exc)) from exc

    serialized = serialize_messages(db, [message], user_id=current_user.id)[0]
    await chat_manager.broadcast(
        chat_id,
        {
            "type": "message",
            "chat_id": chat_id,
            "message": serialized.model_dump(mode="json"),
        },
    )
    return serialized


@router.patch("/messages/{message_id}", response_model=MessageOut)
async def patch_message(
    message_id: int,
    payload: MessageUpdate,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> MessageOut:
    try:
        message = update_message_content(db, message_id=message_id, user_id=current_user.id, content=payload.content)
    except ValueError as exc:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(exc)) from exc

    serialized = serialize_messages(db, [message], user_id=current_user.id)[0]
    await chat_manager.broadcast(
        message.chat_id,
        {
            "type": "message_updated",
            "chat_id": message.chat_id,
            "message": serialized.model_dump(mode="json"),
        },
    )
    return serialized


@router.delete("/messages/{message_id}")
async def remove_message(
    message_id: int,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> dict:
    try:
        removed_chat_id = delete_message(db, message_id=message_id, user_id=current_user.id)
    except ValueError as exc:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail=str(exc)) from exc

    if removed_chat_id is None:
        return {"message_id": message_id, "removed": False}

    await chat_manager.broadcast(
        removed_chat_id,
        {
            "type": "message_deleted",
            "chat_id": removed_chat_id,
            "message_id": message_id,
        },
    )
    return {"message_id": message_id, "chat_id": removed_chat_id, "removed": True}


@router.post("/{chat_id}/messages/{message_id}/pin")
async def pin_chat_message(
    chat_id: int,
    message_id: int,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> dict:
    try:
        pin = pin_message(db, chat_id=chat_id, message_id=message_id, user_id=current_user.id)
    except ValueError as exc:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(exc)) from exc

    await chat_manager.broadcast(
        chat_id,
        {
            "type": "message_pinned",
            "chat_id": chat_id,
            "message_id": message_id,
            "pinned_at": pin.pinned_at.isoformat(),
        },
    )
    return {"chat_id": chat_id, "message_id": message_id, "pinned": True}


@router.delete("/{chat_id}/messages/{message_id}/pin")
async def unpin_chat_message(
    chat_id: int,
    message_id: int,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> dict:
    try:
        removed = unpin_message(db, chat_id=chat_id, message_id=message_id, user_id=current_user.id)
    except ValueError as exc:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(exc)) from exc
    if removed:
        await chat_manager.broadcast(
            chat_id,
            {
                "type": "message_unpinned",
                "chat_id": chat_id,
                "message_id": message_id,
            },
        )
    return {"chat_id": chat_id, "message_id": message_id, "pinned": False, "removed": removed}


@router.post("/messages/{message_id}/reactions", status_code=status.HTTP_201_CREATED)
def add_message_reaction(
    message_id: int,
    payload: ReactionCreate,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> dict:
    try:
        reaction = react_to_message(db, message_id=message_id, user_id=current_user.id, emoji=payload.emoji)
    except ValueError as exc:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(exc)) from exc
    return {"id": reaction.id, "message_id": reaction.message_id, "user_id": reaction.user_id, "emoji": reaction.emoji}


@router.delete("/messages/{message_id}/reactions")
def delete_message_reaction(
    message_id: int,
    emoji: str = Query(..., min_length=1, max_length=12),
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> dict:
    removed = remove_message_reaction(db, message_id=message_id, user_id=current_user.id, emoji=emoji)
    return {"message_id": message_id, "emoji": emoji, "removed": removed}
