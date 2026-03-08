def _register(client, username: str, email: str, password: str = "Password123"):
    response = client.post(
        "/api/auth/register",
        json={"username": username, "email": email, "password": password},
    )
    assert response.status_code == 201, response.text
    return response.json()


def _auth_headers(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


def test_auth_profile_chat_social_customization_flow(client):
    alice = _register(client, "alice", "alice@test.dev")
    bob = _register(client, "bob", "bob@test.dev")

    alice_headers = _auth_headers(alice["access_token"])
    bob_headers = _auth_headers(bob["access_token"])

    me = client.get("/api/users/me", headers=alice_headers)
    assert me.status_code == 200
    assert me.json()["username"] == "alice"

    patched = client.patch("/api/users/me", headers=alice_headers, json={"bio": "Founder"})
    assert patched.status_code == 200
    assert patched.json()["bio"] == "Founder"

    created_chat = client.post(
        "/api/chats",
        headers=alice_headers,
        json={
            "title": "Core Team",
            "description": "Launch prep",
            "type": "group",
            "member_ids": [bob["user"]["id"]],
        },
    )
    assert created_chat.status_code == 201, created_chat.text
    chat_id = created_chat.json()["id"]

    sent_message = client.post(
        f"/api/chats/{chat_id}/messages",
        headers=alice_headers,
        json={"content": "Hello from Alice"},
    )
    assert sent_message.status_code == 201
    message_id = sent_message.json()["id"]

    bob_messages = client.get(f"/api/chats/{chat_id}/messages", headers=bob_headers)
    assert bob_messages.status_code == 200
    assert bob_messages.json()[-1]["content"] == "Hello from Alice"

    message_reaction = client.post(
        f"/api/chats/messages/{message_id}/reactions",
        headers=bob_headers,
        json={"emoji": "fire"},
    )
    assert message_reaction.status_code == 201
    assert message_reaction.json()["chat_id"] == chat_id

    alice_messages_after_reaction = client.get(f"/api/chats/{chat_id}/messages", headers=alice_headers)
    assert alice_messages_after_reaction.status_code == 200
    reaction_rows = alice_messages_after_reaction.json()[-1]["reactions"]
    assert any(row["emoji"] == "fire" and row["count"] >= 1 for row in reaction_rows)

    follow = client.post(f"/api/users/{alice['user']['id']}/follow", headers=bob_headers)
    assert follow.status_code == 200
    assert follow.json()["is_following"] is True

    follower_only_post = client.post(
        "/api/social/posts",
        headers=alice_headers,
        json={"content": "For followers only", "visibility": "followers"},
    )
    assert follower_only_post.status_code == 201

    feed = client.get("/api/social/feed", headers=bob_headers)
    assert feed.status_code == 200
    assert any(post["content"] == "For followers only" for post in feed.json())

    settings = client.put(
        "/api/customization/me",
        headers=alice_headers,
        json={"theme": "neon", "accent_color": "#FF4D00"},
    )
    assert settings.status_code == 200
    assert settings.json()["theme"] == "neon"


def test_phase1_message_lifecycle_cursor_and_statuses(client):
    alice = _register(client, "phase1_alice", "phase1_alice@test.dev")
    bob = _register(client, "phase1_bob", "phase1_bob@test.dev")

    alice_headers = _auth_headers(alice["access_token"])
    bob_headers = _auth_headers(bob["access_token"])

    created_chat = client.post(
        "/api/chats",
        headers=alice_headers,
        json={
            "title": "Phase 1 chat",
            "description": "Core messaging model check",
            "type": "group",
            "member_ids": [bob["user"]["id"]],
        },
    )
    assert created_chat.status_code == 201, created_chat.text
    chat_id = created_chat.json()["id"]

    first = client.post(
        f"/api/chats/{chat_id}/messages",
        headers=alice_headers,
        json={"content": "First message"},
    )
    assert first.status_code == 201, first.text
    first_message = first.json()
    first_id = first_message["id"]
    assert first_message["status"] == "delivered"

    bob_chats = client.get("/api/chats", headers=bob_headers)
    assert bob_chats.status_code == 200, bob_chats.text
    bob_chat = next((row for row in bob_chats.json() if row["id"] == chat_id), None)
    assert bob_chat is not None
    assert bob_chat["last_message_preview"] == "First message"
    assert bob_chat["unread_count"] >= 1

    bob_page = client.get(
        f"/api/chats/{chat_id}/messages/cursor",
        headers=bob_headers,
        params={"limit": 1},
    )
    assert bob_page.status_code == 200, bob_page.text
    bob_items = bob_page.json()["items"]
    assert len(bob_items) == 1
    assert bob_items[0]["id"] == first_id
    assert bob_items[0]["status"] == "read"

    alice_after_read = client.get(f"/api/chats/{chat_id}/messages", headers=alice_headers)
    assert alice_after_read.status_code == 200, alice_after_read.text
    assert alice_after_read.json()[-1]["status"] == "read"

    second = client.post(
        f"/api/chats/{chat_id}/messages",
        headers=bob_headers,
        json={"content": "Reply message", "reply_to_message_id": first_id},
    )
    assert second.status_code == 201, second.text
    second_message = second.json()
    second_id = second_message["id"]
    assert second_message["reply_to_message_id"] == first_id

    third = client.post(
        f"/api/chats/{chat_id}/messages",
        headers=alice_headers,
        json={"content": "Forward message", "forward_from_message_id": second_id},
    )
    assert third.status_code == 201, third.text
    third_message = third.json()
    third_id = third_message["id"]
    assert third_message["forwarded_from_message_id"] == second_id

    page_one = client.get(
        f"/api/chats/{chat_id}/messages/cursor",
        headers=alice_headers,
        params={"limit": 2},
    )
    assert page_one.status_code == 200, page_one.text
    page_one_payload = page_one.json()
    page_one_items = page_one_payload["items"]
    assert [row["id"] for row in page_one_items] == [second_id, third_id]
    assert page_one_payload["next_before_id"] == second_id

    page_two = client.get(
        f"/api/chats/{chat_id}/messages/cursor",
        headers=alice_headers,
        params={"limit": 2, "before_id": page_one_payload["next_before_id"]},
    )
    assert page_two.status_code == 200, page_two.text
    page_two_payload = page_two.json()
    assert [row["id"] for row in page_two_payload["items"]] == [first_id]
    assert page_two_payload["next_before_id"] is None

    edited = client.patch(
        f"/api/chats/messages/{second_id}",
        headers=bob_headers,
        json={"content": "Reply message edited"},
    )
    assert edited.status_code == 200, edited.text
    assert edited.json()["content"] == "Reply message edited"
    assert edited.json()["edited_at"] is not None

    pinned = client.post(
        f"/api/chats/{chat_id}/messages/{third_id}/pin",
        headers=alice_headers,
    )
    assert pinned.status_code == 200, pinned.text
    assert pinned.json()["pinned"] is True

    all_messages = client.get(f"/api/chats/{chat_id}/messages", headers=alice_headers)
    assert all_messages.status_code == 200, all_messages.text
    by_id = {row["id"]: row for row in all_messages.json()}

    reaction_added = client.post(
        f"/api/chats/messages/{third_id}/reactions",
        headers=bob_headers,
        json={"emoji": "thumbsup"},
    )
    assert reaction_added.status_code == 201, reaction_added.text

    message_with_reaction = client.get(f"/api/chats/{chat_id}/messages", headers=alice_headers)
    assert message_with_reaction.status_code == 200, message_with_reaction.text
    by_id_with_reaction = {row["id"]: row for row in message_with_reaction.json()}
    assert any(row["emoji"] == "thumbsup" for row in by_id_with_reaction[third_id]["reactions"])

    reaction_removed = client.delete(
        f"/api/chats/messages/{third_id}/reactions",
        headers=bob_headers,
        params={"emoji": "thumbsup"},
    )
    assert reaction_removed.status_code == 200, reaction_removed.text
    assert reaction_removed.json()["removed"] is True
    assert by_id[third_id]["is_pinned"] is True

    deleted = client.delete(f"/api/chats/messages/{second_id}", headers=alice_headers)
    assert deleted.status_code == 200, deleted.text
    assert deleted.json()["removed"] is True
    assert deleted.json()["chat_id"] == chat_id

    after_delete = client.get(f"/api/chats/{chat_id}/messages", headers=alice_headers)
    assert after_delete.status_code == 200, after_delete.text
    remaining_ids = {row["id"] for row in after_delete.json()}
    assert second_id not in remaining_ids


def test_refresh_token_rotation_flow(client):
    user = _register(client, "refresh_alice", "refresh_alice@test.dev")
    first_refresh = user.get("refresh_token")
    assert isinstance(first_refresh, str) and first_refresh

    refreshed = client.post("/api/auth/refresh", json={"refresh_token": first_refresh})
    assert refreshed.status_code == 200, refreshed.text
    refreshed_payload = refreshed.json()
    second_access = refreshed_payload.get("access_token")
    second_refresh = refreshed_payload.get("refresh_token")
    assert isinstance(second_access, str) and second_access
    assert isinstance(second_refresh, str) and second_refresh
    assert second_refresh != first_refresh

    stale = client.post("/api/auth/refresh", json={"refresh_token": first_refresh})
    assert stale.status_code == 401

    me = client.get("/api/users/me", headers=_auth_headers(second_access))
    assert me.status_code == 200
    assert me.json()["username"] == "refresh_alice"


def test_uid_set_and_find_flow(client):
    alice = _register(client, "uid_alice", "uid_alice@test.dev")
    bob = _register(client, "uid_bob", "uid_bob@test.dev")

    alice_headers = _auth_headers(alice["access_token"])
    bob_headers = _auth_headers(bob["access_token"])

    set_uid = client.patch(
        "/api/users/me",
        headers=alice_headers,
        json={"uid": "Astra_Link01"},
    )
    assert set_uid.status_code == 200, set_uid.text
    assert set_uid.json()["uid"] == "astra_link01"

    found = client.get("/api/users/by-uid/astra_link01", headers=bob_headers)
    assert found.status_code == 200, found.text
    assert found.json()["username"] == "uid_alice"
    assert found.json()["uid"] == "astra_link01"

    search = client.get("/api/users/search", headers=bob_headers, params={"q": "astra_link01"})
    assert search.status_code == 200, search.text
    assert any(user["uid"] == "astra_link01" for user in search.json())

    duplicate = client.patch("/api/users/me", headers=bob_headers, json={"uid": "astra_link01"})
    assert duplicate.status_code == 400


def test_release_endpoint(client):
    response = client.get("/api/releases/latest/windows")
    assert response.status_code == 200
    data = response.json()
    assert data["platform"] == "windows"
    assert "latest_version" in data
    assert "download_url" in data
