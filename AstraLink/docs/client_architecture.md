# Flutter Client Architecture (Phase 3)

The client is now split by features instead of a single monolithic UI file.

## Structure

```text
lib/src/
  api.dart
  models.dart
  realtime.dart
  session.dart
  app.dart
  core/ui/
    adaptive_size.dart
    app_theme.dart
  features/
    auth/presentation/auth_screen.dart
    home/presentation/home_shell.dart
    chats/presentation/chats_tab.dart
    contacts/presentation/contacts_tab.dart
    settings/presentation/settings_tab.dart
    profile/presentation/profile_tab.dart
```

## Notes

- `app.dart` now only bootstraps session/theme and routes to Auth/Home.
- `home_shell.dart` composes tabs and bottom navigation.
- Chat realtime/reconnect logic remains in `features/chats/presentation/chats_tab.dart`.
- Shared UI primitives are in `core/ui`.

## Next step

- Move business logic from widgets into feature controllers (`Cubit`/`Riverpod`) to support offline cache and easier testing.
