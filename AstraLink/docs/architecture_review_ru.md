# Архитектурный разбор AstraLink (backend + Flutter client)

## 1) Что уже сделано хорошо

- **Функциональная декомпозиция backend**: есть разделение на `api/routers`, `services`, `models`, `schemas`, `core`, `realtime`, что уже лучше «плоского» монолита.  
- **Явный service-layer**: большая часть бизнес-логики вынесена из роутеров в сервисы (`auth_service`, `chat_service`, `user_service`).  
- **Feature-first на клиенте**: Flutter-клиент разделён на `features/*`, есть выделенные `application`, `data`, `presentation` для чатов.  
- **Наличие интеграционных тестов API**: покрываются основные пользовательские сценарии (аутентификация, приватные чаты, realtime, refresh, release endpoint).

## 2) Ключевые архитектурные риски

### 2.1 Backend: «сервис-бог» в чатах

`app/services/chat_service.py` стал чрезмерно крупным и объединяет сразу несколько bounded contexts:

- жизненный цикл чатов и участников;
- отправка/редактирование/удаление сообщений;
- статусы доставки/read;
- закрепы/реакции;
- сериализация DTO;
- вычисление preview/unread;
- доступ к медиа.

**Риск:** рост стоимости изменений, сложность тестирования, высокий шанс регрессий при доработке любой чат-фичи.

---

### 2.2 Router-уровень содержит orchestration realtime

В `app/api/routers/chats.py` роутер не только обрабатывает HTTP, но и orchestrates broadcast-события (`_broadcast_chat_event`, `user_realtime_manager.broadcast*`).

**Риск:** смешение транспортного слоя (HTTP) и доменного workflow, сложнее переиспользовать те же сценарии из других интерфейсов (например, worker/CLI).

---

### 2.3 Синхронные SQLAlchemy-сессии в async-контексте

Приложение использует `FastAPI` + `async`-эндпойнты, но работа с БД выполнена через sync `Session` и синхронные сервисные вызовы.

**Риск:** под нагрузкой возможна деградация latency из-за блокировок event loop в I/O-bound участках.

---

### 2.4 Создание таблиц при старте приложения

В `lifespan` вызывается `create_tables()`. Это упрощает старт, но в production мешает управляемой эволюции схемы.

**Риск:** неуправляемые изменения schema state, отсутствие формального migration-flow.

---

### 2.5 Клиент: часть состояния остаётся в UI shell

В `lib/src/app.dart` состояние сессии/пользователя/refresh-логики хранится в StatefulWidget и связывается напрямую с API.

**Риск:** трудно тестировать и масштабировать (сложнее добавить background sync, offline-first авторизацию, сложные auth-state transitions).

## 3) Как сделать лучше (практически)

### 3.1 Разделить backend по модулям домена (modular monolith)

Предлагаемая структура:

```text
app/
  modules/
    auth/
      api.py
      service.py
      repository.py
      models.py
      schemas.py
    chats/
      api.py
      application/
        commands/
          send_message.py
          update_chat_state.py
        queries/
          list_user_chats.py
      domain/
        entities.py
        policies.py
      infrastructure/
        repository_sqlalchemy.py
        serializers.py
    realtime/
      gateway.py
      events.py
```

**Эффект:** меньше когнитивной нагрузки; проще ownership команды; легче выделять контракты.

---

### 3.2 Ввести CQRS-lite для chat-модуля

- **Commands**: `SendMessage`, `EditMessage`, `PinMessage`, `ReactToMessage`.
- **Queries**: `GetMessages`, `ListChats`, `SearchMessages`.

Это можно сделать без отдельной шины: просто разные handler-классы + dependency injection.

**Эффект:** query-оптимизации не ломают mutation-код; проще профилировать «горячие» запросы.

---

### 3.3 Вынести realtime в доменные события

Сейчас роутер сам решает, какие события отправлять. Лучше:

1. service/command возвращает `DomainEvent` (например, `MessageCreated`);
2. event-publisher превращает его в websocket payload;
3. transport-layer (HTTP/WebSocket) только подписывается/публикует.

**Эффект:** слабее связность между HTTP и realtime, легче добавлять push/email/analytics consumers.

---

### 3.4 Перейти на миграции (Alembic)

- Запретить `create_tables()` в runtime для production.
- Добавить CI шаг: `alembic upgrade head` на ephemeral БД.

**Эффект:** предсказуемые schema changes и rollback strategy.

---

### 3.5 Клиент: завершить переход на provider-driven state

Следующий шаг после текущего feature split:

- auth/session/update-channel вынести в Riverpod `Notifier`/`AsyncNotifier`;
- `app.dart` оставить как composition-root;
- API-клиент инжектировать через provider;
- покрыть auth-state machine unit-тестами.

**Эффект:** меньше «жирного» UI state, лучше тестируемость и предсказуемость.

## 4) Приоритетный roadmap (на 6–8 недель)

### Этап 1 (1–2 недели): стабилизация и наблюдаемость

- Ввести структурированные логи + request-id.
- Добавить базовые метрики (RPS, p95 latency, DB query timing).
- Зафиксировать Python runtime в CI и dev (>=3.11).

### Этап 2 (2–3 недели): рефакторинг chat-domain

- Разбить `chat_service.py` на `chat_commands.py`, `chat_queries.py`, `message_status_service.py`, `chat_serializers.py`.
- Добавить unit-тесты на каждый command/query handler.

### Этап 3 (1–2 недели): database governance

- Подключить Alembic, сделать baseline migration.
- Убрать автоматическое создание таблиц из runtime.

### Этап 4 (1–2 недели): Flutter state architecture

- Перевести auth/session в Riverpod.
- Добавить тесты для refresh/logout и bootstrap-flow.

## 5) Быстрые «точечные» улучшения без большого рефакторинга

1. Вынести `serialize_messages(...)` из `chat_service.py` в отдельный serializer-модуль.  
2. Убрать из роутеров realtime-детали в отдельный `events_service`.  
3. Ввести transaction boundaries в сервисах через явные use-case функции (`with db.begin()`).  
4. Ограничить размер файла сервиса (soft limit ~300–400 строк).  
5. Добавить smoke-тест на запуск под Python 3.11 в CI.

## 6) Целевая «north-star» архитектура

- **Backend:** модульный монолит (DDD-lite + CQRS-lite + Alembic + event-driven realtime adapter).
- **Client:** feature-first + provider-driven application state + typed API error model.
- **Ops:** измеримость (метрики/логи), миграции, окружение фиксированной версии рантайма.

Это даст лучший баланс между скоростью фич и управляемостью сложности без преждевременного перехода в микросервисы.
