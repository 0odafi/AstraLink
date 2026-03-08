import 'package:astralink_app/src/features/chats/data/chats_local_cache.dart';
import 'package:astralink_app/src/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('chats cache roundtrip', () async {
    final cache = ChatsLocalCache();
    final now = DateTime.utc(2026, 3, 9, 12, 0, 0);
    final chats = [
      ChatItem(
        id: 10,
        title: 'Alice',
        type: 'private',
        lastMessagePreview: 'Hi',
        lastMessageAt: now,
        unreadCount: 2,
        isArchived: false,
        isPinned: true,
        folder: null,
      ),
    ];

    await cache.saveChats(baseUrl: 'https://volds.ru', userId: 1, chats: chats);
    final loaded = await cache.loadChats(
      baseUrl: 'https://volds.ru',
      userId: 1,
    );

    expect(loaded, hasLength(1));
    expect(loaded.first.id, 10);
    expect(loaded.first.title, 'Alice');
    expect(loaded.first.unreadCount, 2);
    expect(loaded.first.isPinned, true);
  });

  test('messages cache keeps recent tail', () async {
    final cache = ChatsLocalCache();
    final rows = List.generate(
      5,
      (index) => MessageItem(
        id: index + 1,
        chatId: 7,
        senderId: 1,
        content: 'm${index + 1}',
        createdAt: DateTime.utc(2026, 3, 9, 12, 0, index),
        status: 'sent',
        editedAt: null,
      ),
    );

    await cache.saveMessages(
      baseUrl: 'https://volds.ru',
      userId: 1,
      chatId: 7,
      messages: rows,
      maxItems: 3,
    );
    final loaded = await cache.loadMessages(
      baseUrl: 'https://volds.ru',
      userId: 1,
      chatId: 7,
    );

    expect(loaded, hasLength(3));
    expect(loaded.first.id, 3);
    expect(loaded.last.id, 5);
    expect(loaded.last.content, 'm5');
  });
}
