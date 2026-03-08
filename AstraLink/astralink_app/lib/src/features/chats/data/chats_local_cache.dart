import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../../models.dart';

class ChatsLocalCache {
  static const String _chatsPrefix = 'astralink.cache.v1.chats';
  static const String _messagesPrefix = 'astralink.cache.v1.messages';

  final Future<SharedPreferences> Function() _prefsFactory;

  ChatsLocalCache({Future<SharedPreferences> Function()? prefsFactory})
    : _prefsFactory = prefsFactory ?? SharedPreferences.getInstance;

  Future<List<ChatItem>> loadChats({
    required String baseUrl,
    required int userId,
  }) async {
    final prefs = await _prefsFactory();
    final raw = prefs.getString(_chatsKey(baseUrl: baseUrl, userId: userId));
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return decoded
          .whereType<Map>()
          .map((row) => ChatItem.fromJson(row.cast<String, dynamic>()))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> saveChats({
    required String baseUrl,
    required int userId,
    required List<ChatItem> chats,
    int maxItems = 250,
  }) async {
    final prefs = await _prefsFactory();
    final normalized = chats.take(maxItems).map(_chatToJson).toList();
    await prefs.setString(
      _chatsKey(baseUrl: baseUrl, userId: userId),
      jsonEncode(normalized),
    );
  }

  Future<List<MessageItem>> loadMessages({
    required String baseUrl,
    required int userId,
    required int chatId,
  }) async {
    final prefs = await _prefsFactory();
    final raw = prefs.getString(
      _messagesKey(baseUrl: baseUrl, userId: userId, chatId: chatId),
    );
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      final rows = decoded
          .whereType<Map>()
          .map((row) => MessageItem.fromJson(row.cast<String, dynamic>()))
          .toList();
      rows.sort((a, b) => a.createdAt.compareTo(b.createdAt));
      return rows;
    } catch (_) {
      return const [];
    }
  }

  Future<void> saveMessages({
    required String baseUrl,
    required int userId,
    required int chatId,
    required List<MessageItem> messages,
    int maxItems = 300,
  }) async {
    final prefs = await _prefsFactory();
    final start = messages.length > maxItems ? messages.length - maxItems : 0;
    final normalized = messages.skip(start).map(_messageToJson).toList();
    await prefs.setString(
      _messagesKey(baseUrl: baseUrl, userId: userId, chatId: chatId),
      jsonEncode(normalized),
    );
  }

  String _chatsKey({required String baseUrl, required int userId}) {
    return '$_chatsPrefix::$baseUrl::$userId';
  }

  String _messagesKey({
    required String baseUrl,
    required int userId,
    required int chatId,
  }) {
    return '$_messagesPrefix::$baseUrl::$userId::$chatId';
  }

  Map<String, dynamic> _chatToJson(ChatItem chat) {
    return {
      'id': chat.id,
      'title': chat.title,
      'type': chat.type,
      'last_message_preview': chat.lastMessagePreview,
      'last_message_at': chat.lastMessageAt?.toIso8601String(),
      'unread_count': chat.unreadCount,
      'is_archived': chat.isArchived,
      'is_pinned': chat.isPinned,
      'folder': chat.folder,
    };
  }

  Map<String, dynamic> _messageToJson(MessageItem message) {
    return {
      'id': message.id,
      'chat_id': message.chatId,
      'sender_id': message.senderId,
      'content': message.content,
      'created_at': message.createdAt.toIso8601String(),
      'status': message.status,
      'edited_at': message.editedAt?.toIso8601String(),
    };
  }
}
