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
- Offline cache is enabled for dialogs and message timelines via
  `features/chats/data/chats_local_cache.dart` (`SharedPreferences`).
- Chats/messages state is managed with `Riverpod` view-models in
  `features/chats/application/chat_view_models.dart`.

## Next step

- Move auth/settings/profile state to providers and add integration tests for view-models.
