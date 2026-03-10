from datetime import UTC, datetime, timedelta
from urllib.parse import quote_plus

from sqlalchemy import inspect

from app.core.database import SessionLocal
from app.core.database import engine
from app.services.scheduled_service import dispatch_due_scheduled_messages

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
        },
    )
    assert verify_code.status_code == 200, verify_code.text
    payload = verify_code.json()
    assert payload["access_token"]
    assert payload["refresh_token"]
    assert payload["user"]["phone"] == request_payload["phone"]
    assert payload["needs_profile_setup"] is True
    return payload


def test_phone_auth_follow_up_login_does_not_require_profile_setup(client):
    phone = "+7 900 100 10 10"
    first = _auth_by_phone(client, phone, "Setup", "Needed")
    headers = _auth_headers(first["access_token"])

    complete_profile = client.patch(
        "/api/users/me",
        headers=headers,
        json={"first_name": "Setup", "last_name": "Needed", "username": "setup_needed"},
    )
    assert complete_profile.status_code == 200, complete_profile.text

    request_code = client.post("/api/auth/request-code", json={"phone": phone})
    assert request_code.status_code == 200, request_code.text
    request_payload = request_code.json()
    assert request_payload["is_registered"] is True

    verify_code = client.post(
        "/api/auth/verify-code",
        json={
            "phone": request_payload["phone"],
            "code_token": request_payload["code_token"],
            "code": TEST_AUTH_CODE,
        },
    )
    assert verify_code.status_code == 200, verify_code.text
    payload = verify_code.json()
    assert payload["user"]["id"] == first["user"]["id"]
    assert payload["needs_profile_setup"] is False


def test_phone_auth_profile_and_lookup_flow(client):
    alice = _auth_by_phone(client, "+7 900 111 22 33", "Alice", "Stone")
    bob = _auth_by_phone(client, "+7 900 111 22 44", "Bob", "Miller")

    alice_headers = _auth_headers(alice["access_token"])
    bob_headers = _auth_headers(bob["access_token"])

    me = client.get("/api/users/me", headers=alice_headers)
    assert me.status_code == 200, me.text
    assert me.json()["first_name"] == ""
    assert me.json()["phone"] == "+79001112233"
    assert me.json()["username"] is None

    patched = client.patch(
        "/api/users/me",
        headers=alice_headers,
        json={"username": "@alice_stone", "first_name": "Alice", "last_name": "Stone", "bio": "hello"},
    )
    assert patched.status_code == 200, patched.text
    assert patched.json()["username"] == "alice_stone"
    assert patched.json()["first_name"] == "Alice"
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

    alice_profile = client.patch(
        "/api/users/me",
        headers=alice_headers,
        json={"first_name": "Alice", "last_name": "Two"},
    )
    assert alice_profile.status_code == 200, alice_profile.text
    bob_profile = client.patch(
        "/api/users/me",
        headers=bob_headers,
        json={"first_name": "Bob", "last_name": "Two", "username": "bob_two"},
    )
    assert bob_profile.status_code == 200, bob_profile.text

    open_chat = client.post(
        "/api/chats/private?query=%2B79002222244",
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

    alice_headers = _auth_headers(alice["access_token"])
    bob_headers = _auth_headers(bob["access_token"])

    set_username = client.patch(
        "/api/users/me",
        headers=alice_headers,
        json={"first_name": "Alice", "last_name": "Search", "username": "alice_search"},
    )
    assert set_username.status_code == 200, set_username.text

    search_username = client.get("/api/users/search", headers=bob_headers, params={"q": "alice"})
    assert search_username.status_code == 200, search_username.text
    assert any(user["username"] == "alice_search" for user in search_username.json())

    search_username_with_at = client.get("/api/users/search", headers=bob_headers, params={"q": "@alice"})
    assert search_username_with_at.status_code == 200, search_username_with_at.text

    search_username_with_link = client.get(
        "/api/users/search",
        headers=bob_headers,
        params={"q": "https://volds.ru/u/alice_search"},
    )
    assert search_username_with_link.status_code == 200, search_username_with_link.text
    assert any(user["username"] == "alice_search" for user in search_username_with_link.json())

    search_phone = client.get("/api/users/search", headers=bob_headers, params={"q": "9003332233"})
    assert search_phone.status_code == 200, search_phone.text
    assert any(user["phone"] == "+79003332233" for user in search_phone.json())


def test_username_check_and_clear_flow(client):
    user = _auth_by_phone(client, "+7 900 350 22 33", "Name", "User")
    headers = _auth_headers(user["access_token"])

    available = client.get("/api/users/username-check", headers=headers, params={"username": "@telegram_like"})
    assert available.status_code == 200, available.text
    assert available.json() == {"username": "telegram_like", "available": True}

    updated = client.patch(
        "/api/users/me",
        headers=headers,
        json={"username": "telegram_like", "first_name": "Name"},
    )
    assert updated.status_code == 200, updated.text
    assert updated.json()["username"] == "telegram_like"

    taken = client.get("/api/users/username-check", headers=headers, params={"username": "telegram_like"})
    assert taken.status_code == 200, taken.text
    assert taken.json()["available"] is True

    second = _auth_by_phone(client, "+7 900 350 22 44", "Second", "User")
    second_headers = _auth_headers(second["access_token"])
    unavailable = client.get("/api/users/username-check", headers=second_headers, params={"username": "telegram_like"})
    assert unavailable.status_code == 200, unavailable.text
    assert unavailable.json()["available"] is False

    cleared = client.patch(
        "/api/users/me",
        headers=headers,
        json={"username": "", "first_name": "Name"},
    )
    assert cleared.status_code == 200, cleared.text
    assert cleared.json()["username"] is None


def test_public_profile_endpoint_and_link_lookup(client):
    owner = _auth_by_phone(client, "+7 900 351 22 33", "Public", "User")
    viewer = _auth_by_phone(client, "+7 900 351 22 44", "Viewer", "User")

    owner_headers = _auth_headers(owner["access_token"])
    viewer_headers = _auth_headers(viewer["access_token"])

    updated = client.patch(
        "/api/users/me",
        headers=owner_headers,
        json={"first_name": "Public", "last_name": "User", "username": "public_user", "bio": "Visible bio"},
    )
    assert updated.status_code == 200, updated.text

    public_profile = client.get("/api/public/users/public_user")
    assert public_profile.status_code == 200, public_profile.text
    payload = public_profile.json()
    assert payload["username"] == "public_user"
    assert payload["bio"] == "Visible bio"
    assert "phone" not in payload

    public_page = client.get("/u/public_user")
    assert public_page.status_code == 200, public_page.text
    assert "@public_user" in public_page.text

    open_by_link = client.post(
        "/api/chats/private?query=https%3A%2F%2Fvolds.ru%2Fu%2Fpublic_user",
        headers=viewer_headers,
    )
    assert open_by_link.status_code == 200, open_by_link.text


def test_realtime_message_status_flow(client):
    alice = _auth_by_phone(client, "+7 900 444 22 33", "Alice", "Ws")
    bob = _auth_by_phone(client, "+7 900 444 22 44", "Bob", "Ws")

    alice_headers = _auth_headers(alice["access_token"])
    bob_headers = _auth_headers(bob["access_token"])

    client.patch("/api/users/me", headers=alice_headers, json={"first_name": "Alice", "last_name": "Ws"})
    client.patch("/api/users/me", headers=bob_headers, json={"first_name": "Bob", "last_name": "Ws", "username": "bob_ws"})

    open_chat = client.post(
        f"/api/chats/private?query={quote_plus('bob_ws')}",
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
    bob_headers = _auth_headers(bob["access_token"])

    client.patch("/api/users/me", headers=alice_headers, json={"first_name": "Alice", "last_name": "State"})
    client.patch("/api/users/me", headers=bob_headers, json={"first_name": "Bob", "last_name": "State", "username": "bob_state"})

    open_chat = client.post(
        f"/api/chats/private?query={quote_plus('bob_state')}",
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


def test_media_upload_and_send_attachment_flow(client):
    alice = _auth_by_phone(client, "+7 900 777 22 33", "Alice", "Media")
    bob = _auth_by_phone(client, "+7 900 777 22 44", "Bob", "Media")

    alice_headers = _auth_headers(alice["access_token"])
    bob_headers = _auth_headers(bob["access_token"])

    client.patch("/api/users/me", headers=alice_headers, json={"first_name": "Alice", "last_name": "Media"})
    client.patch("/api/users/me", headers=bob_headers, json={"first_name": "Bob", "last_name": "Media", "username": "bob_media"})

    open_chat = client.post(
        f"/api/chats/private?query={quote_plus('bob_media')}",
        headers=alice_headers,
    )
    assert open_chat.status_code == 200, open_chat.text
    chat_id = open_chat.json()["id"]

    upload = client.post(
        f"/api/media/upload?chat_id={chat_id}",
        headers=alice_headers,
        files={"file": ("cover.png", b"fake-image-bytes", "image/png")},
    )
    assert upload.status_code == 201, upload.text
    upload_payload = upload.json()
    assert upload_payload["id"] > 0
    assert upload_payload["is_image"] is True
    assert upload_payload["url"].startswith("/media/")

    sent = client.post(
        f"/api/chats/{chat_id}/messages",
        headers=alice_headers,
        json={"content": "", "attachment_ids": [upload_payload["id"]]},
    )
    assert sent.status_code == 201, sent.text
    message = sent.json()
    assert message["content"] == ""
    assert len(message["attachments"]) == 1
    assert message["attachments"][0]["id"] == upload_payload["id"]
    assert message["attachments"][0]["is_image"] is True

    history = client.get(f"/api/chats/{chat_id}/messages", headers=bob_headers)
    assert history.status_code == 200, history.text
    assert any(item["id"] == message["id"] and item["attachments"] for item in history.json())


def test_realtime_replay_after_disconnect(client):
    alice = _auth_by_phone(client, "+7 900 778 22 33", "Alice", "Replay")
    bob = _auth_by_phone(client, "+7 900 778 22 44", "Bob", "Replay")

    alice_headers = _auth_headers(alice["access_token"])
    bob_headers = _auth_headers(bob["access_token"])

    client.patch("/api/users/me", headers=alice_headers, json={"first_name": "Alice", "last_name": "Replay"})
    client.patch("/api/users/me", headers=bob_headers, json={"first_name": "Bob", "last_name": "Replay", "username": "bob_replay"})

    open_chat = client.post(
        f"/api/chats/private?query={quote_plus('bob_replay')}",
        headers=alice_headers,
    )
    assert open_chat.status_code == 200, open_chat.text
    chat_id = open_chat.json()["id"]

    with client.websocket_connect(f"/api/realtime/me/ws?token={alice['access_token']}") as alice_ws:
        ready = alice_ws.receive_json()
        assert ready["type"] == "ready"
        resume_cursor = ready["latest_cursor"]

    sent = client.post(
        f"/api/chats/{chat_id}/messages",
        headers=bob_headers,
        json={"content": "Missed while offline"},
    )
    assert sent.status_code == 201, sent.text

    with client.websocket_connect(
        f"/api/realtime/me/ws?token={alice['access_token']}&cursor={resume_cursor}"
    ) as alice_ws:
        ready = alice_ws.receive_json()
        assert ready["type"] == "ready"
        replay = _recv_by_type(alice_ws, "message")
        assert replay["chat_id"] == chat_id
        assert replay["message"]["content"] == "Missed while offline"
        assert replay["cursor"] > resume_cursor


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


def test_release_manifest_exposes_update_contract(client):
    windows_release = client.get('/api/releases/latest/windows')
    assert windows_release.status_code == 200, windows_release.text
    payload = windows_release.json()
    assert payload['platform'] == 'windows'
    assert payload['channel'] == 'stable'
    assert payload['package_kind'] == 'zip'
    assert payload['install_strategy'] == 'replace_and_restart'
    assert payload['in_app_download_supported'] is True
    assert payload['restart_required'] is True
    assert 'generated_at' in payload

    web_release = client.get('/api/releases/latest/web')
    assert web_release.status_code == 200, web_release.text
    web_payload = web_release.json()
    assert web_payload['package_kind'] == 'bundle'
    assert web_payload['in_app_download_supported'] is False
    assert web_payload['restart_required'] is False



def test_privacy_settings_control_phone_lookup_and_data_storage(client):
    alice = _auth_by_phone(client, '+7 900 889 22 33', 'Alice', 'Privacy')
    bob = _auth_by_phone(client, '+7 900 889 22 44', 'Bob', 'Privacy')

    alice_headers = _auth_headers(alice['access_token'])
    bob_headers = _auth_headers(bob['access_token'])

    current = client.get('/api/users/me/settings', headers=alice_headers)
    assert current.status_code == 200, current.text
    current_payload = current.json()
    assert current_payload['privacy']['phone_visibility'] == 'everyone'
    assert current_payload['privacy']['phone_search_visibility'] == 'everyone'
    assert current_payload['data_storage']['keep_media_days'] == 30
    assert current_payload['blocked_users_count'] == 0

    privacy = client.patch(
        '/api/users/me/settings/privacy',
        headers=alice_headers,
        json={
            'phone_visibility': 'nobody',
            'phone_search_visibility': 'nobody',
            'last_seen_visibility': 'contacts',
            'show_approximate_last_seen': True,
            'allow_group_invites': 'contacts',
        },
    )
    assert privacy.status_code == 200, privacy.text
    privacy_payload = privacy.json()
    assert privacy_payload['phone_visibility'] == 'nobody'
    assert privacy_payload['phone_search_visibility'] == 'nobody'
    assert privacy_payload['last_seen_visibility'] == 'contacts'
    assert privacy_payload['allow_group_invites'] == 'contacts'

    storage = client.patch(
        '/api/users/me/settings/data-storage',
        headers=alice_headers,
        json={
            'keep_media_days': 90,
            'storage_limit_mb': 4096,
            'auto_download_photos': True,
            'auto_download_videos': False,
            'auto_download_music': True,
            'auto_download_files': True,
            'default_auto_delete_seconds': 604800,
        },
    )
    assert storage.status_code == 200, storage.text
    storage_payload = storage.json()
    assert storage_payload['keep_media_days'] == 90
    assert storage_payload['storage_limit_mb'] == 4096
    assert storage_payload['auto_download_videos'] is False
    assert storage_payload['auto_download_files'] is True
    assert storage_payload['default_auto_delete_seconds'] == 604800

    by_phone = client.get('/api/users/lookup', headers=bob_headers, params={'q': '+79008892233'})
    assert by_phone.status_code == 404, by_phone.text

    by_id = client.get(f"/api/users/{alice['user']['id']}", headers=bob_headers)
    assert by_id.status_code == 200, by_id.text
    assert by_id.json()['phone'] is None

    updated_bundle = client.get('/api/users/me/settings', headers=alice_headers)
    assert updated_bundle.status_code == 200, updated_bundle.text
    updated_payload = updated_bundle.json()
    assert updated_payload['privacy']['phone_visibility'] == 'nobody'
    assert updated_payload['data_storage']['keep_media_days'] == 90
    assert updated_payload['data_storage']['default_auto_delete_seconds'] == 604800



def test_blocking_prevents_private_chat_open_and_message_send(client):
    alice = _auth_by_phone(client, '+7 900 888 22 33', 'Alice', 'Block')
    bob = _auth_by_phone(client, '+7 900 888 22 44', 'Bob', 'Block')

    alice_headers = _auth_headers(alice['access_token'])
    bob_headers = _auth_headers(bob['access_token'])

    client.patch(
        '/api/users/me',
        headers=alice_headers,
        json={'first_name': 'Alice', 'last_name': 'Block', 'username': 'alice_block'},
    )
    client.patch(
        '/api/users/me',
        headers=bob_headers,
        json={'first_name': 'Bob', 'last_name': 'Block', 'username': 'bob_block'},
    )

    open_chat = client.post('/api/chats/private?query=alice_block', headers=bob_headers)
    assert open_chat.status_code == 200, open_chat.text
    chat_id = open_chat.json()['id']

    blocked = client.post(f"/api/users/blocks/{bob['user']['id']}", headers=alice_headers)
    assert blocked.status_code == 201, blocked.text
    assert blocked.json()['user']['id'] == bob['user']['id']

    blocked_users = client.get('/api/users/blocks', headers=alice_headers)
    assert blocked_users.status_code == 200, blocked_users.text
    assert any(row['user']['id'] == bob['user']['id'] for row in blocked_users.json())

    retry_open = client.post('/api/chats/private?query=alice_block', headers=bob_headers)
    assert retry_open.status_code == 400, retry_open.text
    assert 'blocked' in retry_open.json()['detail'].lower()

    send_message = client.post(
        f'/api/chats/{chat_id}/messages',
        headers=bob_headers,
        json={'content': 'Can you see this?'},
    )
    assert send_message.status_code == 400, send_message.text
    assert 'blocked' in send_message.json()['detail'].lower()

    remove_block = client.delete(f"/api/users/blocks/{bob['user']['id']}", headers=alice_headers)
    assert remove_block.status_code == 200, remove_block.text
    assert remove_block.json() == {'removed': True}


def test_scheduled_messages_create_list_and_cancel(client):
    alice = _auth_by_phone(client, '+7 900 901 22 33', 'Alice', 'Schedule')
    bob = _auth_by_phone(client, '+7 900 901 22 44', 'Bob', 'Schedule')

    alice_headers = _auth_headers(alice['access_token'])
    bob_headers = _auth_headers(bob['access_token'])

    client.patch(
        '/api/users/me',
        headers=alice_headers,
        json={'first_name': 'Alice', 'last_name': 'Schedule'},
    )
    client.patch(
        '/api/users/me',
        headers=bob_headers,
        json={'first_name': 'Bob', 'last_name': 'Schedule', 'username': 'bob_schedule'},
    )

    open_chat = client.post('/api/chats/private?query=bob_schedule', headers=alice_headers)
    assert open_chat.status_code == 200, open_chat.text
    chat_id = open_chat.json()['id']

    send_at = (datetime.now(UTC) + timedelta(minutes=15)).isoformat()
    scheduled = client.post(
        f'/api/chats/{chat_id}/scheduled-messages',
        headers=alice_headers,
        json={
            'content': 'Ping later',
            'mode': 'at_time',
            'send_at': send_at,
        },
    )
    assert scheduled.status_code == 201, scheduled.text
    payload = scheduled.json()
    assert payload['chat_id'] == chat_id
    assert payload['status'] == 'pending'
    assert payload['mode'] == 'at_time'
    assert payload['content'] == 'Ping later'

    listed = client.get(f'/api/chats/{chat_id}/scheduled-messages', headers=alice_headers)
    assert listed.status_code == 200, listed.text
    rows = listed.json()
    assert len(rows) == 1
    assert rows[0]['id'] == payload['id']

    canceled = client.delete(
        f"/api/chats/{chat_id}/scheduled-messages/{payload['id']}",
        headers=alice_headers,
    )
    assert canceled.status_code == 200, canceled.text
    assert canceled.json()['removed'] is True

    listed_after = client.get(f'/api/chats/{chat_id}/scheduled-messages', headers=alice_headers)
    assert listed_after.status_code == 200, listed_after.text
    assert listed_after.json() == []

    listed_all = client.get(
        f'/api/chats/{chat_id}/scheduled-messages?include_dispatched=true',
        headers=alice_headers,
    )
    assert listed_all.status_code == 200, listed_all.text
    assert listed_all.json()[0]['status'] == 'canceled'


def test_send_when_online_dispatches_as_normal_message(client):
    alice = _auth_by_phone(client, '+7 900 902 22 33', 'Alice', 'Online')
    bob = _auth_by_phone(client, '+7 900 902 22 44', 'Bob', 'Online')

    alice_headers = _auth_headers(alice['access_token'])
    bob_headers = _auth_headers(bob['access_token'])

    client.patch(
        '/api/users/me',
        headers=alice_headers,
        json={'first_name': 'Alice', 'last_name': 'Online'},
    )
    client.patch(
        '/api/users/me',
        headers=bob_headers,
        json={'first_name': 'Bob', 'last_name': 'Online', 'username': 'bob_online'},
    )

    open_chat = client.post('/api/chats/private?query=bob_online', headers=alice_headers)
    assert open_chat.status_code == 200, open_chat.text
    chat_id = open_chat.json()['id']

    scheduled = client.post(
        f'/api/chats/{chat_id}/scheduled-messages',
        headers=alice_headers,
        json={
            'content': 'Deliver when you are online',
            'mode': 'when_online',
        },
    )
    assert scheduled.status_code == 201, scheduled.text
    scheduled_payload = scheduled.json()
    assert scheduled_payload['status'] == 'pending'
    assert scheduled_payload['mode'] == 'when_online'

    with client.websocket_connect(f"/api/realtime/me/ws?token={bob['access_token']}") as bob_ws:
        assert bob_ws.receive_json()['type'] == 'ready'

        db = SessionLocal()
        try:
            dispatched = dispatch_due_scheduled_messages(db, limit=10)
        finally:
            db.close()

    assert len(dispatched) == 1
    assert dispatched[0].scheduled_message_id == scheduled_payload['id']
    assert dispatched[0].serialized_message['content'] == 'Deliver when you are online'

    history = client.get(f'/api/chats/{chat_id}/messages', headers=bob_headers)
    assert history.status_code == 200, history.text
    assert any(item['content'] == 'Deliver when you are online' for item in history.json())

    listed = client.get(
        f'/api/chats/{chat_id}/scheduled-messages?include_dispatched=true',
        headers=alice_headers,
    )
    assert listed.status_code == 200, listed.text
    assert listed.json()[0]['status'] == 'dispatched'
    assert listed.json()[0]['dispatched_message_id'] is not None
