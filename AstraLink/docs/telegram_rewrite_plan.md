# AstraLink Rewrite Plan (Messenger-First)

## Product direction

AstraLink should be a **messenger first** product.
Social features stay optional and should never dominate the main UX.

## Architecture targets

- Backend: FastAPI + PostgreSQL + Redis + WebSocket gateway
- Realtime: delivery/read receipts, typing, presence, reconnect protocol
- Storage: object storage (S3-compatible) for media/voice/files
- Mobile/Desktop/Web client: feature-based architecture (auth, dialogs, chat, calls, settings)
- Deploy: CI/CD with canary + stable channels, health checks, migration gates
- Database changes must ship through Alembic migrations, not runtime `create_all`
- Chat list APIs must be query-efficient: latest message, unread counters, and chat state in a single backend path

## Rewrite phases

### Phase 1 - Core messaging model

- Dialog model (private/group/channel)
- Message model with status (`sent`, `delivered`, `read`)
- Cursor pagination (no full list fetches)
- Message edit/delete, pin, reply, forward

### Phase 2 - Realtime transport

- Dedicated WS events: `message.new`, `message.update`, `message.read`, `typing`, `presence`
- Reliable reconnect with last event cursor
- Server-side fanout via Redis pub/sub
- Global per-user WS channel as the primary transport, not one socket per chat

### Phase 3 - Client architecture

- Split giant UI file into modules:
  - `core/` (config, theme, transport, error handling)
  - `features/auth`
  - `features/chats`
  - `features/messages`
  - `features/settings`
- Unified state management (Cubit/Bloc or Riverpod)
- Offline cache for dialogs/messages
- User appearance/settings state in providers, shared by the whole app

### Phase 4 - Telegram-level UX

- Native-like chat list and thread screen
- Pinned dialogs, unread counters, swipe actions
- Media preview, voice notes, file sending
- Polished typography, spacing, animation, skeleton loaders

### Phase 5 - Security & operations

- Refresh tokens + rotation
- Device sessions and remote logout
- Rate limits, abuse controls, audit logs
- Observability: tracing, metrics, alerting

## Immediate next sprint (what to do now)

1. Finish messenger-first client shell (dialogs + messages focus)
2. Add WS chat stream in client (no manual refresh)
3. Add backend read receipts + unread counters
4. Split Flutter app into feature folders and remove monolithic `main.dart`
