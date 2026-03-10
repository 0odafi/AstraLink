import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../api.dart';
import '../../../models.dart';
import '../data/chats_local_cache.dart';

@immutable
class ChatListVmArgs {
  final AstraApi api;
  final AuthTokens? Function() getTokens;
  final AppUser me;

  const ChatListVmArgs({
    required this.api,
    required this.getTokens,
    required this.me,
  });

  @override
  bool operator ==(Object other) {
    return other is ChatListVmArgs &&
        other.api.baseUrl == api.baseUrl &&
        other.me.id == me.id;
  }

  @override
  int get hashCode => Object.hash(api.baseUrl, me.id);
}

@immutable
class ChatThreadVmArgs {
  final AstraApi api;
  final AuthTokens? Function() getTokens;
  final AppUser me;
  final int chatId;

  const ChatThreadVmArgs({
    required this.api,
    required this.getTokens,
    required this.me,
    required this.chatId,
  });

  @override
  bool operator ==(Object other) {
    return other is ChatThreadVmArgs &&
        other.api.baseUrl == api.baseUrl &&
        other.me.id == me.id &&
        other.chatId == chatId;
  }

  @override
  int get hashCode => Object.hash(api.baseUrl, me.id, chatId);
}

final chatListViewModelProvider = ChangeNotifierProvider.autoDispose
    .family<ChatListViewModel, ChatListVmArgs>(
      (ref, args) => ChatListViewModel(
        api: args.api,
        getTokens: args.getTokens,
        me: args.me,
        cache: ChatsLocalCache(),
      ),
    );

final chatThreadViewModelProvider = ChangeNotifierProvider.autoDispose
    .family<ChatThreadViewModel, ChatThreadVmArgs>(
      (ref, args) => ChatThreadViewModel(
        api: args.api,
        getTokens: args.getTokens,
        me: args.me,
        chatId: args.chatId,
        cache: ChatsLocalCache(),
      ),
    );

class ChatListViewModel extends ChangeNotifier {
  final AstraApi _api;
  final AuthTokens? Function() _getTokens;
  final AppUser _me;
  final ChatsLocalCache _cache;

  bool loading = true;
  List<ChatItem> allChats = const [];
  bool searchingMessages = false;
  List<MessageSearchHit> messageHits = const [];
  String activeFilter = 'all';

  ChatListViewModel({
    required AstraApi api,
    required AuthTokens? Function() getTokens,
    required AppUser me,
    required ChatsLocalCache cache,
  }) : _api = api,
       _getTokens = getTokens,
       _me = me,
       _cache = cache;

  Future<void> prime() async {
    await _loadCachedChats();
    await loadChats();
  }

  Future<void> _loadCachedChats() async {
    final cached = await _cache.loadChats(
      baseUrl: _api.baseUrl,
      userId: _me.id,
    );
    if (cached.isEmpty) return;
    allChats = cached;
    loading = false;
    notifyListeners();
  }

  Future<String?> loadChats({bool silent = false}) async {
    final tokens = _getTokens();
    if (tokens == null) return 'Session expired';
    if (!silent && allChats.isEmpty) {
      loading = true;
      notifyListeners();
    }
    try {
      final chats = await _api.listChats(
        accessToken: tokens.accessToken,
        refreshToken: tokens.refreshToken,
        includeArchived: true,
      );
      allChats = chats;
      await _cache.saveChats(
        baseUrl: _api.baseUrl,
        userId: _me.id,
        chats: chats,
      );
      return null;
    } catch (error) {
      if (!silent && allChats.isEmpty) {
        return error.toString();
      }
      return null;
    } finally {
      if (!silent) {
        loading = false;
        notifyListeners();
      } else {
        notifyListeners();
      }
    }
  }

  Future<String?> searchInMessages(String query) async {
    final cleaned = query.trim();
    if (cleaned.length < 2) {
      messageHits = const [];
      notifyListeners();
      return null;
    }
    final tokens = _getTokens();
    if (tokens == null) return 'Session expired';
    searchingMessages = true;
    notifyListeners();
    try {
      final hits = await _api.searchMessages(
        accessToken: tokens.accessToken,
        refreshToken: tokens.refreshToken,
        query: cleaned,
      );
      messageHits = hits;
      return null;
    } catch (error) {
      return error.toString();
    } finally {
      searchingMessages = false;
      notifyListeners();
    }
  }

  void clearMessageHits() {
    if (messageHits.isEmpty) return;
    messageHits = const [];
    notifyListeners();
  }

  void setFilter(String filter) {
    if (activeFilter == filter) return;
    activeFilter = filter;
    notifyListeners();
  }

  List<ChatItem> filteredChats(String query) {
    final scoped = switch (activeFilter) {
      'pinned' => allChats.where((chat) => chat.isPinned).toList(),
      'archived' => allChats.where((chat) => chat.isArchived).toList(),
      'unread' =>
        allChats
            .where((chat) => !chat.isArchived && chat.unreadCount > 0)
            .toList(),
      _ => allChats.where((chat) => !chat.isArchived).toList(),
    };
    final cleaned = query.trim().toLowerCase();
    if (cleaned.isEmpty) return scoped;
    return scoped.where((chat) {
      return chat.title.toLowerCase().contains(cleaned) ||
          (chat.lastMessagePreview ?? '').toLowerCase().contains(cleaned);
    }).toList();
  }
}

class ChatThreadViewModel extends ChangeNotifier {
  final AstraApi _api;
  final AuthTokens? Function() _getTokens;
  final AppUser _me;
  final int _chatId;
  final ChatsLocalCache _cache;

  bool loading = true;
  bool loadingMore = false;
  bool sending = false;
  List<MessageItem> messages = const [];
  bool scheduledLoading = false;
  List<ScheduledMessageItem> scheduledMessages = const [];
  int? nextBeforeId;
  Timer? _persistDebounce;

  ChatThreadViewModel({
    required AstraApi api,
    required AuthTokens? Function() getTokens,
    required AppUser me,
    required int chatId,
    required ChatsLocalCache cache,
  }) : _api = api,
       _getTokens = getTokens,
       _me = me,
       _chatId = chatId,
       _cache = cache;

  Future<void> prime() async {
    await _loadCachedMessages();
    await loadMessages();
    await loadScheduledMessages(silent: true);
  }

  Future<void> _loadCachedMessages() async {
    final cached = await _cache.loadMessages(
      baseUrl: _api.baseUrl,
      userId: _me.id,
      chatId: _chatId,
    );
    if (cached.isEmpty) return;
    messages = cached;
    loading = false;
    notifyListeners();
  }

  Future<String?> loadMessages({bool silent = false}) async {
    final tokens = _getTokens();
    if (tokens == null) return 'Session expired';
    if (!silent && messages.isEmpty) {
      loading = true;
      notifyListeners();
    }
    try {
      final page = await _api.listMessagesCursor(
        accessToken: tokens.accessToken,
        refreshToken: tokens.refreshToken,
        chatId: _chatId,
        limit: 60,
      );
      final rows = [...page.items]
        ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
      messages = rows;
      nextBeforeId = page.nextBeforeId;
      _schedulePersistMessages();
      return null;
    } catch (error) {
      if (messages.isEmpty) return error.toString();
      return null;
    } finally {
      if (!silent) {
        loading = false;
      }
      notifyListeners();
    }
  }

  Future<String?> loadMoreHistory() async {
    if (loadingMore || nextBeforeId == null) return null;
    final tokens = _getTokens();
    if (tokens == null) return 'Session expired';

    loadingMore = true;
    notifyListeners();
    try {
      final page = await _api.listMessagesCursor(
        accessToken: tokens.accessToken,
        refreshToken: tokens.refreshToken,
        chatId: _chatId,
        limit: 50,
        beforeId: nextBeforeId,
      );
      nextBeforeId = page.nextBeforeId;
      if (page.items.isEmpty) return null;

      final existingIds = messages.map((row) => row.id).toSet();
      final merged = [
        ...page.items.where((row) => !existingIds.contains(row.id)),
        ...messages,
      ]..sort((a, b) => a.createdAt.compareTo(b.createdAt));
      messages = merged;
      _schedulePersistMessages();
      return null;
    } catch (error) {
      return error.toString();
    } finally {
      loadingMore = false;
      notifyListeners();
    }
  }

  Future<String?> sendMessage(
    String text, {
    int? replyToMessageId,
    List<int> attachmentIds = const [],
  }) async {
    final cleaned = text.trim();
    if ((cleaned.isEmpty && attachmentIds.isEmpty) || sending) return null;
    final tokens = _getTokens();
    if (tokens == null) return 'Session expired';

    sending = true;
    notifyListeners();
    try {
      final sent = await _api.sendMessage(
        accessToken: tokens.accessToken,
        refreshToken: tokens.refreshToken,
        chatId: _chatId,
        content: cleaned,
        replyToMessageId: replyToMessageId,
        attachmentIds: attachmentIds,
      );
      applyUpdatedMessage(sent);
      return null;
    } catch (error) {
      return error.toString();
    } finally {
      sending = false;
      notifyListeners();
    }
  }

  Future<String?> loadScheduledMessages({bool silent = false}) async {
    final tokens = _getTokens();
    if (tokens == null) return 'Session expired';
    if (!silent) {
      scheduledLoading = true;
      notifyListeners();
    }
    try {
      final rows = await _api.listScheduledMessages(
        accessToken: tokens.accessToken,
        refreshToken: tokens.refreshToken,
        chatId: _chatId,
      );
      scheduledMessages = rows;
      return null;
    } catch (error) {
      return error.toString();
    } finally {
      scheduledLoading = false;
      notifyListeners();
    }
  }

  Future<String?> scheduleMessage({
    required String text,
    required String mode,
    DateTime? sendAt,
    int? replyToMessageId,
    List<int> attachmentIds = const [],
  }) async {
    final cleaned = text.trim();
    if ((cleaned.isEmpty && attachmentIds.isEmpty) || sending) return null;
    final tokens = _getTokens();
    if (tokens == null) return 'Session expired';

    sending = true;
    notifyListeners();
    try {
      final scheduled = await _api.scheduleMessage(
        accessToken: tokens.accessToken,
        refreshToken: tokens.refreshToken,
        chatId: _chatId,
        content: cleaned,
        mode: mode,
        sendAt: sendAt,
        replyToMessageId: replyToMessageId,
        attachmentIds: attachmentIds,
      );
      scheduledMessages = [...scheduledMessages, scheduled]
        ..sort((a, b) {
          final aStamp = a.sendAt ?? a.createdAt;
          final bStamp = b.sendAt ?? b.createdAt;
          return aStamp.compareTo(bStamp);
        });
      return null;
    } catch (error) {
      return error.toString();
    } finally {
      sending = false;
      notifyListeners();
    }
  }

  Future<String?> cancelScheduledMessage(int scheduledMessageId) async {
    final tokens = _getTokens();
    if (tokens == null) return 'Session expired';
    try {
      final removed = await _api.cancelScheduledMessage(
        accessToken: tokens.accessToken,
        refreshToken: tokens.refreshToken,
        chatId: _chatId,
        scheduledMessageId: scheduledMessageId,
      );
      if (removed) {
        scheduledMessages = scheduledMessages
            .where((item) => item.id != scheduledMessageId)
            .toList();
        notifyListeners();
      }
      return null;
    } catch (error) {
      return error.toString();
    }
  }

  Future<String?> editMessage({
    required int messageId,
    required String text,
  }) async {
    final cleaned = text.trim();
    if (cleaned.isEmpty) return null;
    final tokens = _getTokens();
    if (tokens == null) return 'Session expired';
    try {
      final updated = await _api.updateMessage(
        accessToken: tokens.accessToken,
        refreshToken: tokens.refreshToken,
        messageId: messageId,
        content: cleaned,
      );
      applyUpdatedMessage(updated);
      return null;
    } catch (error) {
      return error.toString();
    }
  }

  Future<String?> deleteRemoteMessage(int messageId) async {
    final tokens = _getTokens();
    if (tokens == null) return 'Session expired';
    try {
      final removed = await _api.deleteMessage(
        accessToken: tokens.accessToken,
        refreshToken: tokens.refreshToken,
        messageId: messageId,
      );
      if (removed) {
        deleteMessage(messageId);
      }
      return null;
    } catch (error) {
      return error.toString();
    }
  }

  Future<String?> setMessagePinned({
    required int messageId,
    required bool pinned,
  }) async {
    final tokens = _getTokens();
    if (tokens == null) return 'Session expired';
    try {
      if (pinned) {
        await _api.pinMessage(
          accessToken: tokens.accessToken,
          refreshToken: tokens.refreshToken,
          chatId: _chatId,
          messageId: messageId,
        );
      } else {
        await _api.unpinMessage(
          accessToken: tokens.accessToken,
          refreshToken: tokens.refreshToken,
          chatId: _chatId,
          messageId: messageId,
        );
      }
      updatePinnedState(messageId: messageId, pinned: pinned);
      return null;
    } catch (error) {
      return error.toString();
    }
  }

  Future<String?> toggleReaction({
    required int messageId,
    required String emoji,
    required bool reactedByMe,
  }) async {
    final tokens = _getTokens();
    if (tokens == null) return 'Session expired';
    try {
      if (reactedByMe) {
        await _api.removeReaction(
          accessToken: tokens.accessToken,
          refreshToken: tokens.refreshToken,
          messageId: messageId,
          emoji: emoji,
        );
      } else {
        await _api.addReaction(
          accessToken: tokens.accessToken,
          refreshToken: tokens.refreshToken,
          messageId: messageId,
          emoji: emoji,
        );
      }
      await loadMessages(silent: true);
      return null;
    } catch (error) {
      return error.toString();
    }
  }

  void applyMessage(MessageItem item) {
    applyUpdatedMessage(item);
  }

  void applyUpdatedMessage(MessageItem item) {
    final existingIndex = messages.indexWhere((row) => row.id == item.id);
    if (existingIndex == -1) {
      messages = [...messages, item]
        ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    } else {
      final next = [...messages];
      next[existingIndex] = item;
      messages = next;
    }
    _schedulePersistMessages();
    notifyListeners();
  }

  void deleteMessage(int messageId) {
    messages = messages.where((row) => row.id != messageId).toList();
    _schedulePersistMessages();
    notifyListeners();
  }

  void updateMessageStatus(int messageId, String status) {
    messages = messages
        .map((row) => row.id == messageId ? row.copyWith(status: status) : row)
        .toList();
    _schedulePersistMessages();
    notifyListeners();
  }

  void updatePinnedState({required int messageId, required bool pinned}) {
    messages = messages
        .map(
          (row) => row.id == messageId ? row.copyWith(isPinned: pinned) : row,
        )
        .toList();
    _schedulePersistMessages();
    notifyListeners();
  }

  MessageItem? findMessageById(int messageId) {
    for (final message in messages) {
      if (message.id == messageId) return message;
    }
    return null;
  }

  MessageItem? get pinnedMessage {
    MessageItem? pinned;
    for (final message in messages) {
      if (message.isPinned) {
        pinned = message;
      }
    }
    return pinned;
  }

  int get scheduledPendingCount =>
      scheduledMessages.where((item) => item.status == 'pending').length;

  void _schedulePersistMessages() {
    _persistDebounce?.cancel();
    _persistDebounce = Timer(const Duration(milliseconds: 300), () async {
      await _cache.saveMessages(
        baseUrl: _api.baseUrl,
        userId: _me.id,
        chatId: _chatId,
        messages: messages,
      );
    });
  }

  @override
  void dispose() {
    _persistDebounce?.cancel();
    super.dispose();
  }
}
