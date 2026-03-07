from fastapi import APIRouter, Query, WebSocket, WebSocketDisconnect

from app.api.deps import get_current_user_from_raw_token
from app.core.database import SessionLocal
from app.realtime.manager import chat_manager
from app.schemas.chat import MessageOut
from app.services.chat_service import can_access_chat, create_message

router = APIRouter(tags=["Realtime"])


@router.websocket("/chats/{chat_id}/ws")
async def chat_socket(
    websocket: WebSocket,
    chat_id: int,
    token: str = Query(...),
) -> None:
    db = SessionLocal()
    try:
        user = get_current_user_from_raw_token(token, db)
        if not can_access_chat(db, chat_id=chat_id, user_id=user.id):
            await websocket.close(code=4403, reason="Access denied")
            return
    except Exception:
        await websocket.close(code=4401, reason="Invalid token")
        return
    finally:
        db.close()

    await chat_manager.connect(chat_id, websocket)
    await websocket.send_json({"type": "ready", "chat_id": chat_id, "user_id": user.id})

    try:
        while True:
            incoming = await websocket.receive_json()
            event_type = incoming.get("type")

            if event_type == "ping":
                await websocket.send_json({"type": "pong"})
                continue

            if event_type != "message":
                await websocket.send_json({"type": "error", "message": "Unknown event type"})
                continue

            content = str(incoming.get("content", "")).strip()
            if not content:
                await websocket.send_json({"type": "error", "message": "Message content is empty"})
                continue

            db = SessionLocal()
            try:
                message = create_message(db, chat_id=chat_id, sender_id=user.id, content=content)
            except ValueError as exc:
                await websocket.send_json({"type": "error", "message": str(exc)})
                continue
            finally:
                db.close()

            payload = MessageOut.model_validate(message).model_dump(mode="json")
            await chat_manager.broadcast(chat_id, {"type": "message", "chat_id": chat_id, "message": payload})
    except WebSocketDisconnect:
        chat_manager.disconnect(chat_id, websocket)
    except Exception:
        chat_manager.disconnect(chat_id, websocket)
