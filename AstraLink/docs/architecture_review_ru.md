# Архитектурный обзор AstraLink и предложения по улучшению

## 1) Что есть сейчас (в целом)

AstraLink уже построен как **двухконтурная система**:

- Backend на FastAPI + SQLAlchemy.
- Клиент на Flutter с feature-структурой.

По репозиторию видно, что проект уже прошёл переход от «монолита в UI» к модульности (feature folders в клиенте), и в backend есть разделение на `api/`, `services/`, `models/`, `schemas/`, `core/`.

## 2) Текущая структура: сильные стороны

### Backend

- Чёткий вход в приложение (`app/main.py`) с lifecycle, health-check, роутерами и статикой.
- Разделение на слои:
  - `api/routers` — HTTP/WS-контракты,
  - `services` — бизнес-логика,
  - `models` — ORM-модели,
  - `schemas` — Pydantic DTO.
- Есть фундаментальные функции мессенджера:
  - телефонная авторизация + refresh rotation,
  - приватные чаты,
  - сообщения с delivery/read,
  - реакции, pin, reply/forward,
  - realtime WS-канал.

### Клиент (Flutter)

- Структура по фичам уже лучше монолитного `main.dart`.
- Есть `SessionStore`, централизованный `AstraApi`, обработка refresh на уровне API-клиента.
- Наличие локальных кэшей и Riverpod view-models в chat-фиче — хороший базис для офлайн и отзывчивого UI.

## 3) Основные архитектурные риски и «узкие места»

### 3.1 Backend: смешение транзакций, доменной логики и инфраструктуры

Сервисы вроде `chat_service.py` и `auth_service.py` содержат много разнотипной ответственности:

- валидация,
- orchestration сценария,
- SQL-запросы,
- доменные правила,
- частично сериализация и подготовка output-моделей.

Это ускоряет MVP, но со временем приводит к:

- росту сложности изменений,
- трудным unit-тестам,
- риску регрессий при рефакторинге.

**Что лучше:**

- Ввести слой use-cases (application services),
- отделить репозитории/DAO от доменной логики,
- вынести «query-операции для чтения» отдельно от «command-операций».

### 3.2 N+1 и деградация производительности в чатах

В `get_user_chats` видно потенциальный N+1:

- на каждый чат отдельно читается последний message,
- отдельно считается unread,
- отдельно вычисляется title приватного чата.

На десятках/сотнях диалогов это станет bottleneck.

**Что лучше:**

- перейти на aggregate-query (CTE/subquery/join с pre-aggregation),
- подготовить read-model (`chat_list_view`) или materialized подход,
- добавить пагинацию списка чатов курсором.

### 3.3 Миграции: runtime-ALTER в `create_tables`

Сейчас есть «совместимые миграции» через runtime SQL в `database.py`.
Это удобно временно, но рискованно в production:

- сложно контролировать версионирование схемы,
- нет прозрачной истории миграций,
- риск гонок при нескольких инстансах.

**Что лучше:**

- перейти на Alembic,
- запретить DDL-миграции при старте API,
- сделать явный migration step в CI/CD.

### 3.4 Realtime: вероятная проблема масштабирования

Есть in-process manager для realtime. Это ок для 1 инстанса, но при горизонтальном масштабировании события между инстансами не синхронизируются.

**Что лучше:**

- вынести шину событий в Redis pub/sub (или NATS/Kafka при росте),
- отделить WS-gateway от API-процесса,
- добавить sequence/cursor для «надёжного догоняющего reconnect».

### 3.5 Конфигурация и безопасность

- В `config.py` есть небезопасный default `secret_key`.
- Нет жёсткого fail-fast на production-конфиг.

**Что лучше:**

- при `environment=production` валидировать обязательные секреты,
- ввести structured logging + trace-id,
- добавить rate-limit для auth/request-code и verify.

### 3.6 Flutter: «god service» API и слабая типизация домена

`api.dart` уже достаточно большой и содержит почти весь transport + error mapping + часть retry-flow.
При расширении фич он станет «узлом сцепления».

**Что лучше:**

- разбить клиент на data sources per feature:
  - `auth_api.dart`, `chats_api.dart`, `users_api.dart`, `releases_api.dart`,
- поверх них — repositories,
- выше — use-cases/view-models.

Так проще тестировать и менять backend-контракты локально.

## 4) Целевая архитектура (практично, без overengineering)

## Backend (Clean-ish, pragmatic)

- `app/api` — thin controllers (FastAPI routers).
- `app/application` — use cases (например, `SendMessage`, `OpenPrivateChat`, `VerifyPhoneCode`).
- `app/domain` — сущности/правила/доменные сервисы (минимально, где это окупается).
- `app/infrastructure`:
  - SQLAlchemy repositories,
  - Redis event bus,
  - SMS providers,
  - media storage adapters.
- `app/readmodels` — оптимизированные query-проекции для тяжелых экранов.

## Клиент (Feature-first + layered)

Для каждой фичи:

- `data/` (API + local cache)
- `domain/` (entities + use-cases)
- `presentation/` (UI + state)

Общее:

- `core/network` (http client, interceptors, auth refresh)
- `core/storage`
- `core/telemetry`

## 5) Приоритетный roadmap улучшений

### Этап 1 (быстрые победы, 1–2 недели)

1. Ввести Alembic и убрать runtime DDL-миграции из `create_tables`.
2. Разделить `chat_service.get_user_chats` на optimized read query.
3. Добавить rate limit на auth endpoints.
4. Проставить production guards для env-конфига (secret key, CORS, SMS).

### Этап 2 (масштабирование, 2–4 недели)

1. Вынести realtime fanout в Redis pub/sub.
2. Добавить event cursor и reconnect protocol.
3. Разделить большие backend-сервисы на use-cases + repositories.

### Этап 3 (качество и DX, параллельно)

1. Контрактные тесты API (schema + critical flows).
2. Нагрузочные сценарии для chat list / send message / realtime ack.
3. Observability: metrics (p95 latency, ws connections, failed refresh, sms send errors).

## 6) Конкретные «до/после» примеры

### Пример A: список чатов

**Сейчас:** цикл по чатам + множественные запросы.

**После:** один SQL с:

- latest message per chat,
- unread aggregate per chat,
- membership flags,
- сортировкой pinned + activity.

Результат: меньше latency и нагрузки на БД.

### Пример B: телефонная авторизация

**Сейчас:** логика кода/попыток/создания user в одном сервисе.

**После:**

- `RequestLoginCodeUseCase`
- `VerifyLoginCodeUseCase`
- `UserIdentityRepository`
- `PhoneCodeRepository`
- `SmsGateway`

Результат: проще тестировать edge cases и менять SMS-провайдера.

## 7) Итог

Текущая архитектура **хорошо подходит для активной разработки MVP+**: функциональность уже богата, структура не хаотична.

Чтобы проект устойчиво рос (нагрузка, команда, релизы), ключевые улучшения:

1. Миграции (Alembic вместо runtime ALTER).
2. Read-model/оптимизация запросов чатов.
3. Realtime через внешнюю шину (Redis).
4. Чёткое разделение application/domain/infrastructure.
5. На Flutter — декомпозиция API-слоя по фичам.

Это даст заметный прирост по скорости разработки, предсказуемости релизов и масштабируемости без радикального переписывания.
