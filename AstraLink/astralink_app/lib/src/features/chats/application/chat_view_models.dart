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
  bool sending = false;
  List<MessageItem> messages = const [];
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

  Future<String?> loadMessages() async {
    final tokens = _getTokens();
    if (tokens == null) return 'Session expired';
    if (messages.isEmpty) {
      loading = true;
      notifyListeners();
    }
    try {
      final rows = await _api.listMessages(
        accessToken: tokens.accessToken,
        refreshToken: tokens.refreshToken,
        chatId: _chatId,
      );
      rows.sort((a, b) => a.createdAt.compareTo(b.createdAt));
      messages = rows;
      _schedulePersistMessages();
      return null;
    } catch (error) {
      if (messages.isEmpty) return error.toString();
      return null;
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<String?> sendMessage(String text) async {
    final cleaned = text.trim();
    if (cleaned.isEmpty || sending) return null;
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
      );
      final hasExisting = messages.any((row) => row.id == sent.id);
      if (!hasExisting) {
        messages = [...messages, sent]
          ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
        _schedulePersistMessages();
      }
      return null;
    } catch (error) {
      return error.toString();
    } finally {
      sending = false;
      notifyListeners();
    }
  }

  void applyMessage(MessageItem item) {
    final hasExisting = messages.any((row) => row.id == item.id);
    if (hasExisting) return;
    messages = [...messages, item]
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    _schedulePersistMessages();
    notifyListeners();
  }

  void applyUpdatedMessage(MessageItem item) {
    messages = messages.map((row) => row.id == item.id ? item : row).toList();
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
        .map(
          (row) => row.id == messageId
              ? MessageItem(
                  id: row.id,
                  chatId: row.chatId,
                  senderId: row.senderId,
                  content: row.content,
                  createdAt: row.createdAt,
                  status: status,
                  editedAt: row.editedAt,
                )
              : row,
        )
        .toList();
    _schedulePersistMessages();
    notifyListeners();
  }

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
