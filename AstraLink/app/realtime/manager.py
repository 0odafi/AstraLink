from collections import defaultdict

from fastapi import WebSocket


class ChatConnectionManager:
    def __init__(self) -> None:
        self._connections: dict[int, dict[WebSocket, int]] = defaultdict(dict)

    async def connect(self, chat_id: int, websocket: WebSocket, user_id: int) -> bool:
        sockets = self._connections[chat_id]
        had_user = user_id in sockets.values()
        await websocket.accept()
        sockets[websocket] = user_id
        return not had_user

    def disconnect(self, chat_id: int, websocket: WebSocket) -> tuple[int | None, bool]:
        sockets = self._connections.get(chat_id)
        if not sockets:
            return None, False

        user_id = sockets.pop(websocket, None)
        if user_id is None:
            return None, False

        is_last_for_user = user_id not in sockets.values()
        if not sockets:
            del self._connections[chat_id]
        return user_id, is_last_for_user

    async def broadcast(
        self,
        chat_id: int,
        payload: dict,
        *,
        exclude: WebSocket | None = None,
    ) -> None:
        dead_connections: list[WebSocket] = []
        sockets = self._connections.get(chat_id, {})
        for socket in sockets:
            if exclude is not None and socket == exclude:
                continue
            try:
                await socket.send_json(payload)
            except Exception:
                dead_connections.append(socket)

        for socket in dead_connections:
            self.disconnect(chat_id, socket)


chat_manager = ChatConnectionManager()
