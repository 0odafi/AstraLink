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
        json={"emoji": "🔥"},
    )
    assert message_reaction.status_code == 201

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


def test_release_endpoint(client):
    response = client.get("/api/releases/latest/windows")
    assert response.status_code == 200
    data = response.json()
    assert data["platform"] == "windows"
    assert "latest_version" in data
    assert "download_url" in data
