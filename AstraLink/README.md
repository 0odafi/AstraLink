# AstraLink

AstraLink is a production-ready backend foundation for a messenger + social network platform with:

- account system with JWT auth
- chats (private/group/channel model), messages, reactions
- realtime chat transport via WebSocket
- social layer (posts, feed, follow graph, reactions)
- advanced per-user customization settings (theme/layout/notifications/privacy)

This is a strong starting point for a project that can evolve beyond Telegram-level customization with modular architecture and clear extension points.

## 1. Quick Start

```powershell
cd C:\Users\odafi\Desktop\AstraLink
python -m venv .venv
.venv\Scripts\Activate.ps1
pip install -e .
Copy-Item .env.example .env
uvicorn app.main:app --reload
```

Open Swagger:

- [http://127.0.0.1:8000/docs](http://127.0.0.1:8000/docs)
- [http://127.0.0.1:8000/](http://127.0.0.1:8000/) (AstraLink web console)

Health check:

- `GET /health`

## 2. Demo Data

```powershell
python -m scripts.seed_demo
```

Demo users:

- `alice / Password123`
- `bob / Password123`
- `carol / Password123`

## 3. API Capabilities

### Auth
- `POST /api/auth/register`
- `POST /api/auth/login`
- `POST /api/auth/refresh`
- `POST /api/auth/logout`

### Users + Social Graph
- `GET /api/users/me`
- `PATCH /api/users/me`
- `GET /api/users/search?q=...`
- `GET /api/users/by-uid/{uid}`
- `POST /api/users/{user_id}/follow`
- `DELETE /api/users/{user_id}/follow`
- `GET /api/users/{user_id}/followers`
- `GET /api/users/{user_id}/following`

### Chats + Messages
- `POST /api/chats`
- `GET /api/chats`
- `POST /api/chats/{chat_id}/members`
- `GET /api/chats/{chat_id}/messages`
- `POST /api/chats/{chat_id}/messages`
- `POST /api/chats/messages/{message_id}/reactions`
- `DELETE /api/chats/messages/{message_id}/reactions?emoji=...`

### Realtime
- `WS /api/realtime/chats/{chat_id}/ws?token=<jwt>`
- Incoming events: `ping`, `message`
- Outgoing events: `ready`, `pong`, `message`, `error`

### Social Feed
- `POST /api/social/posts`
- `GET /api/social/feed`
- `GET /api/social/users/{user_id}/posts`
- `POST /api/social/posts/{post_id}/reactions`
- `DELETE /api/social/posts/{post_id}/reactions?emoji=...`

### Customization
- `GET /api/customization/me`
- `PUT /api/customization/me`

### Releases / Updates
- `GET /api/releases/latest/{platform}?channel=stable`
- Manifest file: `releases/manifest.json`
- Manifest update helper: `python scripts/update_manifest.py --help`

## 4. Tests

```powershell
pytest -q
```

## 5. Build Outputs (Windows + Android)

```powershell
powershell -ExecutionPolicy Bypass -File scripts\build_windows.ps1 -Version 1.0.0+1
powershell -ExecutionPolicy Bypass -File scripts\build_android.ps1 -Version 1.0.0+1 -BuildAab
```

Artifacts are placed in `dist/windows/<version>` and `dist/android/<version>`.

## 6. CI Workflow

- GitHub Actions workflow: `.github/workflows/flutter-build.yml`
- Trigger by tag push (`v*`) or manual run.
- Produces Windows release folder and Android APK artifacts.

## 7. Auto Publish To Ubuntu Server

- Workflow: `.github/workflows/release-publish.yml`
- Server setup guide: `deploy/ubuntu/README.md`
- Required GitHub secrets: `deploy/github-secrets.md`
- Current target server: `root@87.120.84.205` (`volds.ru`)
- Publish trigger:
  - manual workflow run with version input
  - push tag like `v1.0.1+2`

## 8. Current Architecture

```
app/
  api/          # FastAPI routers + dependencies
  core/         # config, DB, security
  models/       # ORM models
  schemas/      # request/response contracts
  services/     # domain logic
  realtime/     # websocket connection manager
```

## 9. Telegram+ Roadmap

### Stage A - Product Core
- media uploads with object storage and CDN
- message edit/delete history
- threaded replies, pinning, scheduling
- ephemeral stories and short-form clips

### Stage B - Scale + Reliability
- PostgreSQL + Alembic migrations
- Redis (presence, pub/sub fanout, rate limits)
- background workers (Celery/RQ/Arq)
- full observability (OpenTelemetry + Prometheus/Grafana)

### Stage C - Differentiation
- deep profile/theme packs and custom UI layout marketplace
- community plugins/bots with permission sandboxing
- AI assistants for moderation/summarization/translation
- cross-device encrypted cloud sync and multi-session controls

## 10. Security Notes

- Use a strong `SECRET_KEY` in production.
- Add HTTPS termination and WAF/rate-limit rules.
- Move from auto-table creation to migration-based deployment.
- Add E2EE design for direct chats and key-management services before production launch.
