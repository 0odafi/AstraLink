# AstraLink — обзор текущей архитектуры и предложения по улучшению

## 1) Что уже сделано хорошо

- **Явный messenger-first фокус** зафиксирован в корневом README и плане rewrite: phone auth, private chats, realtime, release-check endpoint. Это снижает «размывание» продукта и помогает приоритизировать бэклог.
- **Слои на backend читаемые**: `api/routers` → `services` → `models` + `schemas`; для текущего масштаба это понятная и рабочая декомпозиция.
- **Клиент уже движется к feature-based структуре** и использует Riverpod для chat state, есть локальный кэш чатов/сообщений.
- **Есть сквозные API-тесты** ключевых сценариев (auth, chats, search, realtime, refresh, release endpoint).

## 2) Основные архитектурные риски (что станет узким местом)

## 2.1 Backend

1. **Инициализация БД через `create_all` + runtime ALTER-миграции**
   - Сейчас таблицы создаются при старте приложения, а совместимость для SQLite поддерживается ручными `ALTER TABLE` в рантайме.
   - Для production это риск дрейфа схемы, сложного отката и непредсказуемых релизов.

2. **N+1 паттерн в чат-листе**
   - `get_user_chats` для каждого чата отдельно тянет последний message и unread count.
   - При росте числа чатов это даст лишние round-trip и рост latency.

3. **In-memory WebSocket connection manager**
   - Менеджеры realtime держат подключения в памяти процесса.
   - Это ограничивает горизонтальное масштабирование (несколько инстансов без общего брокера будут «слепы» друг к другу).

4. **Часть доменной логики разъезжается между router/service**
   - В роутерах остаются orchestration-ветки (формирование event payloads, часть проверок/маппинга ошибок).
   - Пока допустимо, но со временем усложнит поддержку и повторное использование.

5. **Смешение бизнес-логики и инфраструктуры в service-слое**
   - Текущий `chat_service` аккумулирует много ответственности (membership, message lifecycle, delivery/read, reactions, pinning, serialization helpers).
   - Это ухудшает модульность и затрудняет тестирование по bounded-context.

## 2.2 Flutter client

1. **Критическая сессионная логика сосредоточена в `app.dart`**
   - bootstrap, refresh/logout, user load находятся в root stateful widget.
   - Усложняет unit/integration тестирование и переиспользование сценариев auth/session.

2. **ChangeNotifier VM на feature, но без чётких application/use-case границ**
   - Для текущего объема нормально, но рост бизнес-правил приведет к «толстым VM».

3. **Offline-кэш только на локальных util-слоях без единого cache policy**
   - Нет явной стратегии: TTL, invalidation, versioning payload.

## 2.3 Platform / DevOps

1. **Ориентация на SQLite по умолчанию**
   - для local dev удобно, но в проде нужно явно закрепить PostgreSQL + миграционный процесс.

2. **Недостаточно формализованы SLO/наблюдаемость**
   - В плане упомянуты observability и alerting, но нет явного стандарта (trace-id, метрики p95, error budget, structured logs).

## 3) Целевая архитектура (эволюционно, без «big bang rewrite»)

## 3.1 Backend: модульный монолит с явными доменными модулями

Рекомендованный срез:

- `app/modules/auth/`
- `app/modules/users/`
- `app/modules/chats/`
- `app/modules/realtime/`
- `app/modules/releases/`
- `app/shared/` (db, config, security, observability primitives)

Внутри модуля:

- `api` (router + DTO mapping)
- `application` (use cases / orchestration)
- `domain` (entities/value objects/business rules)
- `infrastructure` (SQLAlchemy repositories, external gateways)

> Это даст лучшее разделение ответственности, но останется в формате одного deployable сервиса.

## 3.2 Данные и миграции

- Ввести **Alembic** как единственный источник изменений схемы.
- Убрать runtime-ALTER из `database.py` после фиксации baseline миграции.
- Для критичных таблиц (messages, deliveries, chat_members) — ревью индексов под реальные запросы.

## 3.3 Realtime

Этапы:

1. Оставить текущий WS API, но добавить **Redis Pub/Sub** для межинстансного fanout.
2. Добавить **event envelope** с `event_id`, `occurred_at`, `chat_id`, `actor_id`.
3. Ввести reconnect-протокол с `last_event_id` (частично уже планировалось в документации).

## 3.4 Клиент

- Вынести session/auth bootstrap из `app.dart` в отдельный `SessionController` (Riverpod Notifier).
- Для chats/messages: перейти на use-case style (`LoadChats`, `SendMessage`, `AcknowledgeRead`) поверх API слоя.
- Ввести единую стратегию local cache:
  - versioned cache keys
  - TTL по сущностям
  - invalidation на критичных мутациях

## 3.5 Наблюдаемость и эксплуатация

Минимум для production-ready:

- structured logging (JSON)
- request correlation id
- метрики: RPS, p95/p99 latency, WS active connections, message delivery lag
- health/readiness/liveness отдельно
- алерты на деградацию realtime и refresh token ошибок

## 4) Приоритетный roadmap улучшений

## Sprint 1 (1–2 недели)

- Поднять Alembic и baseline migration.
- Зафиксировать PostgreSQL как prod-target в deploy docs.
- Разгрузить `get_user_chats`: один агрегирующий запрос на last_message/unread.
- Ввести structured logs + request id middleware.

## Sprint 2

- Разделить `chat_service` на подмодули:
  - chat_members_service
  - message_service
  - message_delivery_service
  - message_reactions_service
- Добавить unit-тесты для каждого use-case слоя.

## Sprint 3

- Redis-backed realtime fanout.
- Event envelope + reconnect cursor.
- Клиентский SessionController + унификация error handling.

## 5) Практические quick wins (без большого рефакторинга)

1. Добавить индексы под частые фильтры и сортировки чат-листа.
2. Ограничить и документировать максимальный размер WS payload.
3. Явно описать контракт ошибок API (единый формат + коды).
4. Вынести конфигурацию окружений (dev/stage/prod) в отдельные наборы env templates.
5. Добавить архитектурные decision records (ADR) для ключевых решений.

## 6) Итог

Текущая архитектура — **хорошая база для MVP+/раннего роста**. Ключевая задача следующего этапа: не переписывать всё, а последовательно усилить **границы доменов, миграционный процесс и realtime scalability**, сохранив текущий темп поставки фич.
