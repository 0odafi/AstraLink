from urllib.parse import quote_plus

from sqlalchemy import inspect

from app.core.database import engine

TEST_AUTH_CODE = "12345"


def _auth_headers(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


def _recv_by_type(websocket, expected_type: str, max_events: int = 10):
    for _ in range(max_events):
        payload = websocket.receive_json()
        if payload.get("type") == expected_type:
            return payload
    raise AssertionError(f"Event '{expected_type}' was not received in {max_events} frames")


def _auth_by_phone(client, phone: str, first_name: str, last_name: str):
    request_code = client.post("/api/auth/request-code", json={"phone": phone})
    assert request_code.status_code == 200, request_code.text
    request_payload = request_code.json()
    assert request_payload["phone"].startswith("+")
    assert request_payload["code_token"]
    assert "dev_code" not in request_payload

    verify_code = client.post(
        "/api/auth/verify-code",
        json={
            "phone": request_payload["phone"],
            "code_token": request_payload["code_token"],
            "code": TEST_AUTH_CODE,
            "first_name": first_name,
            "last_name": last_name,
        },
    )
    assert verify_code.status_code == 200, verify_code.text
    payload = verify_code.json()
    assert payload["access_token"]
    assert payload["refresh_token"]
    assert payload["user"]["phone"] == request_payload["phone"]
    return payload


def test_phone_auth_profile_and_lookup_flow(client):
    alice = _auth_by_phone(client, "+7 900 111 22 33", "Alice", "Stone")
    bob = _auth_by_phone(client, "+7 900 111 22 44", "Bob", "Miller")

    alice_headers = _auth_headers(alice["access_token"])
    bob_headers = _auth_headers(bob["access_token"])

    me = client.get("/api/users/me", headers=alice_headers)
    assert me.status_code == 200, me.text
    assert me.json()["first_name"] == "Alice"
    assert me.json()["phone"] == "+79001112233"

    patched = client.patch(
        "/api/users/me",
        headers=alice_headers,
        json={"username": "alice_stone", "bio": "hello"},
    )
    assert patched.status_code == 200, patched.text
    assert patched.json()["username"] == "alice_stone"
    assert patched.json()["bio"] == "hello"

    lookup = client.get("/api/users/lookup", headers=bob_headers, params={"q": "alice_stone"})
    assert lookup.status_code == 200, lookup.text
    assert lookup.json()["id"] == alice["user"]["id"]

    by_id = client.get(f"/api/users/{alice['user']['id']}", headers=bob_headers)
    assert by_id.status_code == 200, by_id.text
    assert by_id.json()["username"] == "alice_stone"


def test_private_chat_and_messages_flow(client):
    alice = _auth_by_phone(client, "+7 900 222 22 33", "Alice", "Two")
    bob = _auth_by_phone(client, "+7 900 222 22 44", "Bob", "Two")

    alice_headers = _auth_headers(alice["access_token"])
    bob_headers = _auth_headers(bob["access_token"])

    open_chat = client.post(
        f"/api/chats/private?query={quote_plus(bob['user']['username'])}",
        headers=alice_headers,
    )
    assert open_chat.status_code == 200, open_chat.text
    chat_id = open_chat.json()["id"]
    assert open_chat.json()["type"] == "private"

    send_message = client.post(
        f"/api/chats/{chat_id}/messages",
        headers=alice_headers,
        json={"content": "Hello Bob"},
    )
    assert send_message.status_code == 201, send_message.text
    message_id = send_message.json()["id"]
    assert send_message.json()["content"] == "Hello Bob"

    bob_messages = client.get(f"/api/chats/{chat_id}/messages", headers=bob_headers)
    assert bob_messages.status_code == 200, bob_messages.text
    assert any(message["id"] == message_id for message in bob_messages.json())

    send_reply = client.post(
        f"/api/chats/{chat_id}/messages",
        headers=bob_headers,
        json={"content": "Hello Alice"},
    )
    assert send_reply.status_code == 201, send_reply.text

    alice_chats = client.get("/api/chats", headers=alice_headers)
    assert alice_chats.status_code == 200, alice_chats.text
    chat_row = next((row for row in alice_chats.json() if row["id"] == chat_id), None)
    assert chat_row is not None
    assert chat_row["title"] == "Bob Two"
    assert chat_row["last_message_preview"] in {"Hello Bob", "Hello Alice"}
    assert chat_row["unread_count"] == 1


def test_search_users_by_phone_and_username(client):
    alice = _auth_by_phone(client, "+7 900 333 22 33", "Alice", "Search")
    bob = _auth_by_phone(client, "+7 900 333 22 44", "Bob", "Search")

    _ = alice
    bob_headers = _auth_headers(bob["access_token"])

    search_username = client.get("/api/users/search", headers=bob_headers, params={"q": "alice"})
    assert search_username.status_code == 200, search_username.text
    assert any("alice" in user["username"] for user in search_username.json())

    search_phone = client.get("/api/users/search", headers=bob_headers, params={"q": "9003332233"})
    assert search_phone.status_code == 200, search_phone.text
    assert any(user["phone"] == "+79003332233" for user in search_phone.json())


def test_realtime_message_status_flow(client):
    alice = _auth_by_phone(client, "+7 900 444 22 33", "Alice", "Ws")
    bob = _auth_by_phone(client, "+7 900 444 22 44", "Bob", "Ws")

    alice_headers = _auth_headers(alice["access_token"])

    open_chat = client.post(
        f"/api/chats/private?query={quote_plus(bob['user']['username'])}",
        headers=alice_headers,
    )
    assert open_chat.status_code == 200, open_chat.text
    chat_id = open_chat.json()["id"]

    sent = client.post(
        f"/api/chats/{chat_id}/messages",
        headers=alice_headers,
        json={"content": "Status check"},
    )
    assert sent.status_code == 201, sent.text
    message_id = sent.json()["id"]

    with (
        client.websocket_connect(f"/api/realtime/me/ws?token={alice['access_token']}") as alice_ws,
        client.websocket_connect(f"/api/realtime/me/ws?token={bob['access_token']}") as bob_ws,
    ):
        assert alice_ws.receive_json()["type"] == "ready"
        assert bob_ws.receive_json()["type"] == "ready"

        bob_ws.send_json(
            {
                "type": "ack",
                "chat_id": chat_id,
                "message_id": message_id,
                "status": "read",
            }
        )

        status_event = _recv_by_type(alice_ws, "message_status")
        assert status_event["chat_id"] == chat_id
        assert status_event["message_id"] == message_id
        assert status_event["status"] == "read"


def test_chat_state_and_message_search_flow(client):
    alice = _auth_by_phone(client, "+7 900 666 22 33", "Alice", "State")
    bob = _auth_by_phone(client, "+7 900 666 22 44", "Bob", "State")

    alice_headers = _auth_headers(alice["access_token"])

    open_chat = client.post(
        f"/api/chats/private?query={quote_plus(bob['user']['username'])}",
        headers=alice_headers,
    )
    assert open_chat.status_code == 200, open_chat.text
    chat_id = open_chat.json()["id"]

    sent = client.post(
        f"/api/chats/{chat_id}/messages",
        headers=alice_headers,
        json={"content": "Phase two searchable text"},
    )
    assert sent.status_code == 201, sent.text

    mark_pinned = client.patch(
        f"/api/chats/{chat_id}/state",
        headers=alice_headers,
        json={"is_pinned": True},
    )
    assert mark_pinned.status_code == 200, mark_pinned.text
    assert mark_pinned.json()["is_pinned"] is True

    pinned = client.get("/api/chats", headers=alice_headers, params={"pinned_only": "true"})
    assert pinned.status_code == 200, pinned.text
    assert any(row["id"] == chat_id and row["is_pinned"] is True for row in pinned.json())

    archive = client.patch(
        f"/api/chats/{chat_id}/state",
        headers=alice_headers,
        json={"is_archived": True},
    )
    assert archive.status_code == 200, archive.text
    assert archive.json()["is_archived"] is True

    archived = client.get("/api/chats", headers=alice_headers, params={"archived_only": "true"})
    assert archived.status_code == 200, archived.text
    assert any(row["id"] == chat_id and row["is_archived"] is True for row in archived.json())

    search = client.get(
        "/api/chats/messages/search",
        headers=alice_headers,
        params={"q": "searchable", "limit": 20},
    )
    assert search.status_code == 200, search.text
    assert any(row["chat_id"] == chat_id for row in search.json())


def test_refresh_and_release_endpoint(client):
    user = _auth_by_phone(client, "+7 900 555 22 33", "Refresh", "Case")
    first_refresh = user["refresh_token"]

    rotated = client.post("/api/auth/refresh", json={"refresh_token": first_refresh})
    assert rotated.status_code == 200, rotated.text
    payload = rotated.json()
    assert payload["refresh_token"] != first_refresh

    stale = client.post("/api/auth/refresh", json={"refresh_token": first_refresh})
    assert stale.status_code == 401

    release = client.get("/api/releases/latest/windows")
    assert release.status_code == 200, release.text
    assert release.json()["platform"] == "windows"
    assert "volds.ru" in release.json()["download_url"]


def test_database_is_versioned_after_startup(client):
    _ = client.get("/health")
    assert "alembic_version" in set(inspect(engine).get_table_names())
