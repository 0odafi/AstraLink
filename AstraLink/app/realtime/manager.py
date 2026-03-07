from collections import defaultdict

from fastapi import WebSocket


class ChatConnectionManager:
    def __init__(self) -> None:
        self._connections: dict[int, set[WebSocket]] = defaultdict(set)

    async def connect(self, chat_id: int, websocket: WebSocket) -> None:
        await websocket.accept()
        self._connections[chat_id].add(websocket)

    def disconnect(self, chat_id: int, websocket: WebSocket) -> None:
        if chat_id in self._connections:
            self._connections[chat_id].discard(websocket)
            if not self._connections[chat_id]:
                del self._connections[chat_id]

    async def broadcast(self, chat_id: int, payload: dict) -> None:
        dead_connections: list[WebSocket] = []
        for socket in self._connections.get(chat_id, set()):
            try:
                await socket.send_json(payload)
            except Exception:
                dead_connections.append(socket)

        for socket in dead_connections:
            self.disconnect(chat_id, socket)


chat_manager = ChatConnectionManager()
