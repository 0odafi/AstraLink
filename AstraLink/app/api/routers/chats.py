from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy.orm import Session

from app.api.deps import get_current_user, get_db
from app.models.user import User
from app.realtime.manager import chat_manager
from app.schemas.chat import ChatCreate, ChatMemberAdd, ChatOut, MessageCreate, MessageOut, ReactionCreate
from app.services.chat_service import (
    add_member,
    create_chat,
    create_message,
    get_user_chats,
    list_messages,
    react_to_message,
    remove_message_reaction,
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
    return [MessageOut.model_validate(message) for message in messages]


@router.post("/{chat_id}/messages", response_model=MessageOut, status_code=status.HTTP_201_CREATED)
async def post_message(
    chat_id: int,
    payload: MessageCreate,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> MessageOut:
    try:
        message = create_message(db, chat_id=chat_id, sender_id=current_user.id, content=payload.content)
    except ValueError as exc:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(exc)) from exc

    serialized = MessageOut.model_validate(message)
    await chat_manager.broadcast(
        chat_id,
        {
            "type": "message",
            "chat_id": chat_id,
            "message": serialized.model_dump(mode="json"),
        },
    )
    return serialized


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
