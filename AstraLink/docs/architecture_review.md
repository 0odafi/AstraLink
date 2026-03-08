# AstraLink: обзор структуры и архитектуры + предложения по улучшению

Дата: 2026-03-08

## 1) Что есть сейчас (краткий срез)

### Backend (FastAPI)
- Слои в целом разделены: `api/routers` → `services` → `models/schemas`.
- Конфиг из `BaseSettings`, JWT auth, refresh-token rotation, websocket realtime.
- Есть базовый набор интеграционных тестов (`tests/test_api.py`) на ключевые сценарии.
- В текущем виде приложение запускает `create_tables()` на старте и для SQLite выполняет «compat migrations» через raw SQL.

### Client (Flutter)
- Уже сделан шаг к feature-based структуре (`features/auth`, `features/chats`, `features/settings` и т.п.).
- Есть локальный session-store, realtime клиент, offline cache для части chat-сценариев.
- Но в `features/chats/presentation/chats_tab.dart` сосредоточен слишком большой объём UI + логики.

### Что особенно хорошо
- Фокус продукта и API уже «messenger-first».
- Есть realtime-события и статусы доставок/прочтений.
- Есть минимальная эксплуатационная основа (release endpoint + manifest).

---

## 2) Основные архитектурные риски

### R1. Смешение уровней в сервисах и роутерах
Сейчас часть бизнес-логики, обогащения DTO и realtime-notify распределена между роутерами и сервисами. Это увеличивает связность и усложняет изменение контрактов.

**Симптомы:**
- роутер знает много деталей о событиях и форматах payload;
- сервисы местами возвращают ORM-модели, местами словари/промежуточные структуры.

**Что улучшить:**
- Ввести явный Application слой (`app/application/*`) с use-case классами/функциями;
- роутер оставить thin-controller: валидация запроса + вызов use-case + HTTP mapping.

---

### R2. Потенциальные N+1 и высокие латентности в чат-листе
Для чат-листа вычисляются last message / unread count / display name с дополнительными запросами на каждый чат.

**Риск:** деградация при росте диалогов.

**Что улучшить:**
- Перевести `get_user_chats` на один агрегирующий запрос (или 2 фиксированных батча);
- Вынести `unread_count` в materialized counters (обновление по событиям);
- Добавить индексы/проверить план запросов для PostgreSQL (EXPLAIN ANALYZE).

---

### R3. Управление схемой БД через `create_all + compat migrations`
Подход хорош для прототипа, но рискован для production (неявные/неповторяемые миграции).

**Что улучшить:**
- Перейти на Alembic как единственный источник миграций;
- Убрать runtime DDL из startup;
- В CI добавить шаг проверки `alembic upgrade head` на чистой БД.

---

### R4. Ограниченная масштабируемость realtime слоя
Текущий connection manager in-memory, значит горизонтальное масштабирование API-инстансов ограничено.

**Что улучшить:**
- Вынести fanout/presence в Redis pub/sub (или NATS);
- Ввести event envelope (id, type, ts, actor, chat_id, payload, version);
- Добавить cursor-resume при reconnect (last_event_id).

---

### R5. Крупные «god files» на клиенте
`chats_tab.dart` уже >1000 строк: UI, orchestration, side effects, стейт в одном месте.

**Что улучшить:**
- Разделить на:
  - `presentation/` (виджеты);
  - `application/` (Riverpod Notifier/UseCase);
  - `data/` (repo + datasource);
- Ввести feature-level DI и единый Result/Error type.

---

## 3) Рекомендуемая целевая архитектура

## Backend (Clean-ish, pragmatic)

```text
app/
  api/
    routers/
    dto/
  application/
    auth/
    chats/
    users/
    realtime/
  domain/
    entities/
    value_objects/
    services/
    events/
  infrastructure/
    db/
      repositories/
      models/
    messaging/
      redis_bus.py
    sms/
  main.py
```

### Принципы
1. **Router ничего не знает о SQLAlchemy моделях напрямую**.
2. **Use-case возвращает типизированный результат**, не ORM object.
3. **Repository интерфейсы** для критичных сценариев (чаты/сообщения/доставки).
4. **Outbox/Domain events** для сообщений, read receipts, presence.

---

## Client (Flutter feature slices)

```text
lib/src/features/chats/
  presentation/
    screens/
    widgets/
  application/
    controllers/
    state/
  domain/
    models/
    services/
  data/
    repositories/
    datasources/
```

### Принципы
1. UI не делает сетевые вызовы напрямую.
2. Realtime/REST сходятся в общий `ChatRepository`.
3. Стейт хранится в typed immutable state + unit/widget tests.

---

## 4) План улучшений (поэтапно)

### Этап 1 (1-2 недели): «быстрые победы»
- Вынести из роутеров payload-конструирование realtime событий в application/use-cases.
- В чат-листе убрать N+1 (хотя бы last_message и unread_count батчами).
- Добавить метрики: p95 latency для `/api/chats`, `/api/chats/{id}/messages`, ws reconnect rate.

### Этап 2 (2-4 недели): база для роста
- Подключить Alembic, зафиксировать baseline migration.
- Ввести репозитории для `chats/messages` и контрактные unit tests.
- На Flutter разделить `chats_tab.dart` на screen + widgets + controller.

### Этап 3 (4-8 недель): масштабирование
- Redis-backed realtime bus + presence store.
- Cursor-based event replay.
- Кеш unread counters (event-driven обновление).

---

## 5) Конкретные KPI успеха
- `GET /api/chats` p95 < 150ms (на целевом объёме данных).
- Время cold start мобильного клиента до first interactive < 2s.
- Доля websocket reconnect с успешным resync > 99.5%.
- Средний размер PR по backend-domain логике < 400 LOC (признак модульности).

---

## 6) Что делать в первую очередь (моё предложение)
1. **БД миграции (Alembic)** — снижает операционные риски сразу.
2. **Чат-лист без N+1** — прямой эффект на UX и стоимость инфраструктуры.
3. **Декомпозиция `chats_tab.dart`** — ускорит дальнейшую разработку клиента.
4. **Redis fanout для realtime** — готовит платформу к горизонтальному росту.

Если нужно, следующим шагом могу подготовить:
- draft целевой структуры каталогов с точками миграции файлов;
- RFC по websocket event contract (versioning + resume cursor);
- техдолг backlog с оценкой в story points.
