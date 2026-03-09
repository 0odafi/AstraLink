import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../api.dart';
import '../../../core/realtime/realtime_cursor_store.dart';
import '../../../core/ui/adaptive_size.dart';
import '../../../core/ui/app_appearance.dart';
import '../../../models.dart';
import '../../../realtime.dart';
import '../../settings/application/app_preferences.dart';
import '../application/chat_view_models.dart';
import '../data/chat_drafts_local_cache.dart';

class ChatsTab extends ConsumerStatefulWidget {
  final AstraApi api;
  final AuthTokens? Function() getTokens;
  final AppUser me;

  const ChatsTab({
    super.key,
    required this.api,
    required this.getTokens,
    required this.me,
  });

  @override
  ConsumerState<ChatsTab> createState() => _ChatsTabState();
}

class _ChatsTabState extends ConsumerState<ChatsTab> {
  final _searchController = TextEditingController();
  final RealtimeCursorStore _cursorStore = RealtimeCursorStore();
  late ChatListVmArgs _args;
  RealtimeMeSocket? _realtime;
  Timer? _refreshDebounce;
  bool _socketConnected = false;
  int _realtimeCursor = 0;

  @override
  void initState() {
    super.initState();
    _args = ChatListVmArgs(
      api: widget.api,
      getTokens: widget.getTokens,
      me: widget.me,
    );
    unawaited(ref.read(chatListViewModelProvider(_args)).prime());
    unawaited(_bootstrapRealtime());
  }

  @override
  void didUpdateWidget(covariant ChatsTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.api.baseUrl != widget.api.baseUrl ||
        oldWidget.me.id != widget.me.id) {
      _args = ChatListVmArgs(
        api: widget.api,
        getTokens: widget.getTokens,
        me: widget.me,
      );
      unawaited(ref.read(chatListViewModelProvider(_args)).prime());
      unawaited(_bootstrapRealtime());
    }
  }

  @override
  void dispose() {
    _refreshDebounce?.cancel();
    _realtime?.stop();
    _searchController.dispose();
    super.dispose();
  }

  String _buildRealtimeUrl() {
    final tokens = widget.getTokens();
    if (tokens == null) return '';
    return '${webSocketBase(widget.api.baseUrl)}/api/realtime/me/ws?token=${Uri.encodeComponent(tokens.accessToken)}';
  }

  Future<void> _bootstrapRealtime() async {
    final cursor = await _cursorStore.loadCursor(
      baseUrl: widget.api.baseUrl,
      userId: widget.me.id,
    );
    if (!mounted) return;
    _realtimeCursor = cursor;
    _startRealtime();
  }

  void _startRealtime() {
    _realtime?.stop();
    _realtime = RealtimeMeSocket(
      urlBuilder: _buildRealtimeUrl,
      cursorGetter: () => _realtimeCursor,
      onEvent: _handleRealtimeEvent,
      onCursor: _rememberRealtimeCursor,
      onState: (state) {
        if (!mounted) return;
        final connected = state == RealtimeState.connected;
        if (_socketConnected != connected) {
          setState(() => _socketConnected = connected);
        }
        if (connected) {
          _scheduleBackgroundRefresh();
        }
      },
    )..start();
  }

  void _rememberRealtimeCursor(int cursor) {
    if (cursor <= _realtimeCursor) return;
    _realtimeCursor = cursor;
    unawaited(
      _cursorStore.saveCursor(
        baseUrl: widget.api.baseUrl,
        userId: widget.me.id,
        cursor: cursor,
      ),
    );
  }

  void _handleRealtimeEvent(Map<String, dynamic> event) {
    final type = (event['type'] ?? '').toString();
    if (type.isEmpty) return;
    switch (type) {
      case 'ready':
      case 'message':
      case 'message_status':
      case 'message_updated':
      case 'message_deleted':
      case 'chat_state':
        _scheduleBackgroundRefresh();
        break;
      default:
        break;
    }
  }

  void _scheduleBackgroundRefresh() {
    _refreshDebounce?.cancel();
    _refreshDebounce = Timer(const Duration(milliseconds: 450), () {
      if (!mounted) return;
      unawaited(_loadChats(silent: true));
    });
  }

  Future<void> _loadChats({bool silent = false}) async {
    final error = await ref
        .read(chatListViewModelProvider(_args))
        .loadChats(silent: silent);
    if (error != null && !silent) {
      _showSnack(error);
    }
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _searchInMessages() async {
    final error = await ref
        .read(chatListViewModelProvider(_args))
        .searchInMessages(_searchController.text);
    if (error != null) {
      _showSnack(error);
    }
  }

  Future<void> _showChatActions(ChatItem chat) async {
    final tokens = widget.getTokens();
    if (tokens == null) return;
    await showModalBottomSheet<void>(
      context: context,
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: Icon(
                  chat.isPinned ? Icons.push_pin : Icons.push_pin_outlined,
                ),
                title: Text(chat.isPinned ? 'Unpin chat' : 'Pin chat'),
                onTap: () async {
                  Navigator.of(context).pop();
                  try {
                    await widget.api.updateChatState(
                      accessToken: tokens.accessToken,
                      refreshToken: tokens.refreshToken,
                      chatId: chat.id,
                      isPinned: !chat.isPinned,
                    );
                    await _loadChats();
                  } catch (error) {
                    _showSnack(error.toString());
                  }
                },
              ),
              ListTile(
                leading: Icon(
                  chat.isArchived
                      ? Icons.unarchive_outlined
                      : Icons.archive_outlined,
                ),
                title: Text(
                  chat.isArchived ? 'Unarchive chat' : 'Archive chat',
                ),
                onTap: () async {
                  Navigator.of(context).pop();
                  try {
                    await widget.api.updateChatState(
                      accessToken: tokens.accessToken,
                      refreshToken: tokens.refreshToken,
                      chatId: chat.id,
                      isArchived: !chat.isArchived,
                    );
                    await _loadChats();
                  } catch (error) {
                    _showSnack(error.toString());
                  }
                },
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _applyQuickChatAction(
    ChatItem chat, {
    bool? isPinned,
    bool? isArchived,
  }) async {
    final tokens = widget.getTokens();
    if (tokens == null) return;
    try {
      await widget.api.updateChatState(
        accessToken: tokens.accessToken,
        refreshToken: tokens.refreshToken,
        chatId: chat.id,
        isPinned: isPinned,
        isArchived: isArchived,
      );
      await _loadChats(silent: true);
    } catch (error) {
      _showSnack(error.toString());
    }
  }

  Future<void> _createPrivateChat() async {
    final controller = TextEditingController();
    final query = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('New chat'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Phone, @username or link',
              hintText: '+7900..., @username or https://.../u/name',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.of(context).pop(controller.text.trim()),
              child: const Text('Open'),
            ),
          ],
        );
      },
    );
    if (query == null || query.isEmpty) return;

    final tokens = widget.getTokens();
    if (tokens == null) return;
    try {
      final chat = await widget.api.openPrivateChat(
        accessToken: tokens.accessToken,
        refreshToken: tokens.refreshToken,
        query: query,
      );
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ChatScreen(
            api: widget.api,
            getTokens: widget.getTokens,
            chat: chat,
            me: widget.me,
          ),
        ),
      );
      await _loadChats();
    } catch (error) {
      _showSnack(error.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final vm = ref.watch(chatListViewModelProvider(_args));
    final appearance = ref.watch(appPreferencesProvider).appearance;
    final items = vm.filteredChats(_searchController.text);
    final showMessageHits = vm.messageHits.isNotEmpty;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Chats'),
        actions: [
          Icon(
            _socketConnected
                ? Icons.cloud_done_rounded
                : Icons.cloud_off_rounded,
            color: _socketConnected
                ? Theme.of(context).colorScheme.primary
                : Theme.of(context).colorScheme.error,
          ),
          IconButton(
            onPressed: _loadChats,
            icon: const Icon(Icons.refresh_rounded),
          ),
          IconButton(
            onPressed: _createPrivateChat,
            icon: const Icon(Icons.add_comment_outlined),
          ),
        ],
      ),
      body: Padding(
        padding: EdgeInsets.all(context.sp(12)),
        child: Column(
          children: [
            TextField(
              controller: _searchController,
              decoration: const InputDecoration(
                hintText: 'Search chats, @usernames, phone',
                prefixIcon: Icon(Icons.search_rounded),
              ),
              onChanged: (_) {
                if (_searchController.text.trim().isEmpty &&
                    vm.messageHits.isNotEmpty) {
                  ref.read(chatListViewModelProvider(_args)).clearMessageHits();
                } else {
                  setState(() {});
                }
              },
            ),
            SizedBox(height: context.sp(10)),
            SizedBox(
              height: context.sp(42),
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  FilterChip(
                    label: const Text('All'),
                    selected: vm.activeFilter == 'all',
                    onSelected: (_) {
                      if (vm.activeFilter == 'all') return;
                      ref
                          .read(chatListViewModelProvider(_args))
                          .setFilter('all');
                      unawaited(_loadChats(silent: true));
                    },
                  ),
                  SizedBox(width: context.sp(8)),
                  FilterChip(
                    label: const Text('Pinned'),
                    selected: vm.activeFilter == 'pinned',
                    onSelected: (_) {
                      if (vm.activeFilter == 'pinned') return;
                      ref
                          .read(chatListViewModelProvider(_args))
                          .setFilter('pinned');
                      unawaited(_loadChats(silent: true));
                    },
                  ),
                  SizedBox(width: context.sp(8)),
                  FilterChip(
                    label: const Text('Archived'),
                    selected: vm.activeFilter == 'archived',
                    onSelected: (_) {
                      if (vm.activeFilter == 'archived') return;
                      ref
                          .read(chatListViewModelProvider(_args))
                          .setFilter('archived');
                      unawaited(_loadChats(silent: true));
                    },
                  ),
                  SizedBox(width: context.sp(8)),
                  FilterChip(
                    label: const Text('Unread'),
                    selected: vm.activeFilter == 'unread',
                    onSelected: (_) {
                      if (vm.activeFilter == 'unread') return;
                      ref
                          .read(chatListViewModelProvider(_args))
                          .setFilter('unread');
                      unawaited(_loadChats(silent: true));
                    },
                  ),
                  SizedBox(width: context.sp(8)),
                  IconButton(
                    tooltip: 'Search in messages',
                    onPressed: vm.searchingMessages ? null : _searchInMessages,
                    icon: vm.searchingMessages
                        ? SizedBox(
                            width: context.sp(16),
                            height: context.sp(16),
                            child: const CircularProgressIndicator(
                              strokeWidth: 2,
                            ),
                          )
                        : const Icon(Icons.manage_search_rounded),
                  ),
                ],
              ),
            ),
            Expanded(
              child: vm.loading
                  ? const Center(child: CircularProgressIndicator())
                  : RefreshIndicator(
                      onRefresh: _loadChats,
                      child: showMessageHits
                          ? ListView.separated(
                              itemCount: vm.messageHits.length,
                              separatorBuilder: (_, index) =>
                                  SizedBox(height: context.sp(6)),
                              itemBuilder: (context, index) {
                                final hit = vm.messageHits[index];
                                return Card(
                                  child: ListTile(
                                    leading: const Icon(Icons.search_rounded),
                                    title: Text(hit.chatTitle),
                                    subtitle: Text(
                                      hit.content,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    onTap: () async {
                                      final chat = items.firstWhere(
                                        (row) => row.id == hit.chatId,
                                        orElse: () => ChatItem(
                                          id: hit.chatId,
                                          title: hit.chatTitle,
                                          type: 'private',
                                          lastMessagePreview: hit.content,
                                          lastMessageAt: hit.createdAt,
                                          unreadCount: 0,
                                          isArchived: false,
                                          isPinned: false,
                                          folder: null,
                                        ),
                                      );
                                      await Navigator.of(context).push(
                                        MaterialPageRoute(
                                          builder: (_) => ChatScreen(
                                            api: widget.api,
                                            getTokens: widget.getTokens,
                                            chat: chat,
                                            me: widget.me,
                                          ),
                                        ),
                                      );
                                      await _loadChats();
                                    },
                                  ),
                                );
                              },
                            )
                          : items.isEmpty
                          ? ListView(
                              children: const [
                                SizedBox(height: 120),
                                Center(child: Text('No chats yet')),
                              ],
                            )
                          : ListView.separated(
                              itemCount: items.length,
                              separatorBuilder: (_, index) =>
                                  SizedBox(height: context.sp(6)),
                              itemBuilder: (context, index) {
                                final chat = items[index];
                                return Dismissible(
                                  key: ValueKey('chat-${chat.id}'),
                                  direction: DismissDirection.horizontal,
                                  confirmDismiss: (direction) async {
                                    if (direction ==
                                        DismissDirection.startToEnd) {
                                      await _applyQuickChatAction(
                                        chat,
                                        isPinned: !chat.isPinned,
                                      );
                                      return false;
                                    }
                                    await _applyQuickChatAction(
                                      chat,
                                      isArchived: !chat.isArchived,
                                    );
                                    return false;
                                  },
                                  background: Container(
                                    decoration: BoxDecoration(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.primaryContainer,
                                      borderRadius: BorderRadius.circular(
                                        context.sp(18),
                                      ),
                                    ),
                                    padding: EdgeInsets.symmetric(
                                      horizontal: context.sp(16),
                                    ),
                                    alignment: Alignment.centerLeft,
                                    child: Icon(
                                      chat.isPinned
                                          ? Icons.push_pin_outlined
                                          : Icons.push_pin_rounded,
                                    ),
                                  ),
                                  secondaryBackground: Container(
                                    decoration: BoxDecoration(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.secondaryContainer,
                                      borderRadius: BorderRadius.circular(
                                        context.sp(18),
                                      ),
                                    ),
                                    padding: EdgeInsets.symmetric(
                                      horizontal: context.sp(16),
                                    ),
                                    alignment: Alignment.centerRight,
                                    child: Icon(
                                      chat.isArchived
                                          ? Icons.unarchive_outlined
                                          : Icons.archive_outlined,
                                    ),
                                  ),
                                  child: _ChatTile(
                                    chat: chat,
                                    appearance: appearance,
                                    onTap: () async {
                                      await Navigator.of(context).push(
                                        MaterialPageRoute(
                                          builder: (_) => ChatScreen(
                                            api: widget.api,
                                            getTokens: widget.getTokens,
                                            chat: chat,
                                            me: widget.me,
                                          ),
                                        ),
                                      );
                                      await _loadChats();
                                    },
                                    onLongPress: () => _showChatActions(chat),
                                  ),
                                );
                              },
                            ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ChatTile extends StatelessWidget {
  final ChatItem chat;
  final AppAppearanceData appearance;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  const _ChatTile({
    required this.chat,
    required this.appearance,
    required this.onTap,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final subtitle = chat.lastMessagePreview?.trim().isNotEmpty == true
        ? chat.lastMessagePreview!
        : 'No messages yet';
    final lastTime = chat.lastMessageAt;
    final avatarSize = appearance.compactChatList
        ? context.sp(46)
        : context.sp(56);
    final verticalPadding = appearance.compactChatList
        ? context.sp(10)
        : context.sp(14);

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: context.sp(14),
            vertical: verticalPadding,
          ),
          child: Row(
            children: [
              SizedBox(
                width: avatarSize,
                height: avatarSize,
                child: CircleAvatar(
                  backgroundColor: appearance.accentColor.withValues(
                    alpha: 0.2,
                  ),
                  child: Text(
                    chat.title.isEmpty
                        ? '?'
                        : chat.title.characters.first.toUpperCase(),
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: context.sp(18),
                    ),
                  ),
                ),
              ),
              SizedBox(width: context.sp(12)),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            chat.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: appearance.compactChatList
                                  ? context.sp(15)
                                  : context.sp(16),
                            ),
                          ),
                        ),
                        if (chat.isPinned)
                          Padding(
                            padding: EdgeInsets.only(left: context.sp(6)),
                            child: Icon(
                              Icons.push_pin_rounded,
                              size: context.sp(14),
                              color: appearance.accentColor,
                            ),
                          ),
                        if (chat.isArchived)
                          Padding(
                            padding: EdgeInsets.only(left: context.sp(6)),
                            child: Icon(
                              Icons.archive_outlined,
                              size: context.sp(14),
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                            ),
                          ),
                      ],
                    ),
                    SizedBox(height: context.sp(4)),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: appearance.compactChatList
                            ? context.sp(12.5)
                            : context.sp(13.5),
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(width: context.sp(12)),
              Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (lastTime != null)
                    Text(
                      '${lastTime.hour.toString().padLeft(2, '0')}:${lastTime.minute.toString().padLeft(2, '0')}',
                      style: TextStyle(
                        fontSize: context.sp(12),
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  if (chat.unreadCount > 0)
                    Container(
                      margin: EdgeInsets.only(top: context.sp(6)),
                      padding: EdgeInsets.symmetric(
                        horizontal: context.sp(8),
                        vertical: context.sp(3),
                      ),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(999),
                        color: appearance.accentColor,
                      ),
                      child: Text(
                        '${chat.unreadCount}',
                        style: TextStyle(
                          color: const Color(0xFF111418),
                          fontWeight: FontWeight.w700,
                          fontSize: context.sp(11),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class ChatScreen extends ConsumerStatefulWidget {
  final AstraApi api;
  final AuthTokens? Function() getTokens;
  final ChatItem chat;
  final AppUser me;

  const ChatScreen({
    super.key,
    required this.api,
    required this.getTokens,
    required this.chat,
    required this.me,
  });

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  late ChatThreadVmArgs _threadArgs;
  final ChatDraftsLocalCache _drafts = ChatDraftsLocalCache();
  final RealtimeCursorStore _cursorStore = RealtimeCursorStore();
  final _messageController = TextEditingController();
  final _scrollController = ScrollController();
  final _composerFocusNode = FocusNode();

  RealtimeMeSocket? _realtime;
  Timer? _typingPauseTimer;
  Timer? _draftDebounce;
  bool _typingSent = false;
  bool _socketConnected = false;
  final Set<int> _typingUserIds = <int>{};
  int _realtimeCursor = 0;
  int? _replyToMessageId;
  int? _editingMessageId;

  @override
  void initState() {
    super.initState();
    _threadArgs = ChatThreadVmArgs(
      api: widget.api,
      getTokens: widget.getTokens,
      me: widget.me,
      chatId: widget.chat.id,
    );
    unawaited(ref.read(chatThreadViewModelProvider(_threadArgs)).prime());
    unawaited(_loadDraft());
    unawaited(_bootstrapRealtime());
    _scrollController.addListener(_onScroll);
  }

  @override
  void didUpdateWidget(covariant ChatScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.api.baseUrl != widget.api.baseUrl ||
        oldWidget.me.id != widget.me.id ||
        oldWidget.chat.id != widget.chat.id) {
      _threadArgs = ChatThreadVmArgs(
        api: widget.api,
        getTokens: widget.getTokens,
        me: widget.me,
        chatId: widget.chat.id,
      );
      unawaited(ref.read(chatThreadViewModelProvider(_threadArgs)).prime());
      _messageController.clear();
      _replyToMessageId = null;
      _editingMessageId = null;
      unawaited(_loadDraft());
      unawaited(_bootstrapRealtime());
    }
  }

  @override
  void dispose() {
    _notifyTypingStopped();
    _typingPauseTimer?.cancel();
    _draftDebounce?.cancel();
    _realtime?.stop();
    _messageController.dispose();
    _scrollController.dispose();
    _composerFocusNode.dispose();
    super.dispose();
  }

  Future<void> _loadDraft() async {
    final draft = await _drafts.loadDraft(
      baseUrl: widget.api.baseUrl,
      userId: widget.me.id,
      chatId: widget.chat.id,
    );
    if (!mounted || draft == null || draft.isEmpty) return;
    _messageController.text = draft;
    _messageController.selection = TextSelection.collapsed(
      offset: _messageController.text.length,
    );
    setState(() {});
  }

  void _scheduleDraftSave() {
    _draftDebounce?.cancel();
    _draftDebounce = Timer(const Duration(milliseconds: 350), () {
      unawaited(
        _drafts.saveDraft(
          baseUrl: widget.api.baseUrl,
          userId: widget.me.id,
          chatId: widget.chat.id,
          text: _messageController.text,
        ),
      );
    });
  }

  Future<void> _clearDraft() async {
    _draftDebounce?.cancel();
    await _drafts.clearDraft(
      baseUrl: widget.api.baseUrl,
      userId: widget.me.id,
      chatId: widget.chat.id,
    );
  }

  List<MessageItem> get _messages {
    return ref.read(chatThreadViewModelProvider(_threadArgs)).messages;
  }

  bool get _sending {
    return ref.read(chatThreadViewModelProvider(_threadArgs)).sending;
  }

  MessageItem? _messageById(int messageId) {
    return ref.read(chatThreadViewModelProvider(_threadArgs)).findMessageById(
      messageId,
    );
  }

  String _buildRealtimeUrl() {
    final tokens = widget.getTokens();
    if (tokens == null) return '';
    return '${webSocketBase(widget.api.baseUrl)}/api/realtime/me/ws?token=${Uri.encodeComponent(tokens.accessToken)}';
  }

  Future<void> _bootstrapRealtime() async {
    final cursor = await _cursorStore.loadCursor(
      baseUrl: widget.api.baseUrl,
      userId: widget.me.id,
    );
    if (!mounted) return;
    _realtimeCursor = cursor;
    _startRealtime();
  }

  void _startRealtime() {
    _realtime?.stop();
    _realtime = RealtimeMeSocket(
      urlBuilder: _buildRealtimeUrl,
      cursorGetter: () => _realtimeCursor,
      onEvent: _handleRealtimeEvent,
      onCursor: _rememberRealtimeCursor,
      onState: (state) {
        if (!mounted) return;
        final connected = state == RealtimeState.connected;
        if (_socketConnected != connected) {
          setState(() => _socketConnected = connected);
        }
        if (connected) {
          _ackUnreadMessages();
          unawaited(
            ref
                .read(chatThreadViewModelProvider(_threadArgs))
                .loadMessages(silent: true),
          );
        }
      },
    )..start();
  }

  void _rememberRealtimeCursor(int cursor) {
    if (cursor <= _realtimeCursor) return;
    _realtimeCursor = cursor;
    unawaited(
      _cursorStore.saveCursor(
        baseUrl: widget.api.baseUrl,
        userId: widget.me.id,
        cursor: cursor,
      ),
    );
  }

  bool _sendRealtime(Map<String, dynamic> payload) {
    return _realtime?.sendJson(payload) ?? false;
  }

  void _handleRealtimeEvent(Map<String, dynamic> map) {
    final type = map['type']?.toString();
    if (type == null || type.isEmpty) return;

    if (type == 'ready') {
      _ackUnreadMessages();
      return;
    }

    if (type == 'typing') {
      final chatId = map['chat_id'];
      final userId = map['user_id'];
      if (chatId is! int || userId is! int) return;
      if (chatId != widget.chat.id || userId == widget.me.id) return;
      final isTyping = (map['is_typing'] ?? false) == true;
      setState(() {
        if (isTyping) {
          _typingUserIds.add(userId);
        } else {
          _typingUserIds.remove(userId);
        }
      });
      return;
    }

    if (type == 'presence') {
      final chatId = map['chat_id'];
      final userId = map['user_id'];
      final status = (map['status'] ?? '').toString();
      if (chatId is! int || userId is! int) return;
      if (chatId != widget.chat.id || status != 'offline') return;
      setState(() => _typingUserIds.remove(userId));
      return;
    }

    if (type == 'message') {
      final chatId = map['chat_id'];
      if (chatId is! int || chatId != widget.chat.id) return;
      final message = map['message'];
      if (message is! Map) return;
      final item = MessageItem.fromJson(message.cast<String, dynamic>());
      ref.read(chatThreadViewModelProvider(_threadArgs)).applyMessage(item);
      _scrollToBottom();
      _ackMessageRead(item);
      return;
    }

    if (type == 'message_updated') {
      final chatId = map['chat_id'];
      if (chatId is! int || chatId != widget.chat.id) return;
      final message = map['message'];
      if (message is! Map) return;
      final item = MessageItem.fromJson(message.cast<String, dynamic>());
      ref
          .read(chatThreadViewModelProvider(_threadArgs))
          .applyUpdatedMessage(item);
      return;
    }

    if (type == 'message_deleted') {
      final chatId = map['chat_id'];
      final messageId = map['message_id'];
      if (chatId is! int || messageId is! int) return;
      if (chatId != widget.chat.id) return;
      if (_replyToMessageId == messageId || _editingMessageId == messageId) {
        _clearComposerMode();
      }
      ref
          .read(chatThreadViewModelProvider(_threadArgs))
          .deleteMessage(messageId);
      return;
    }

    if (type == 'message_status') {
      final chatId = map['chat_id'];
      final messageId = map['message_id'];
      final senderStatus = map['sender_status']?.toString();
      if (chatId is! int || messageId is! int || senderStatus == null) return;
      if (chatId != widget.chat.id) return;
      ref
          .read(chatThreadViewModelProvider(_threadArgs))
          .updateMessageStatus(messageId, senderStatus);
      return;
    }

    if (type == 'message_pinned' || type == 'message_unpinned') {
      final chatId = map['chat_id'];
      final messageId = map['message_id'];
      if (chatId is! int || messageId is! int) return;
      if (chatId != widget.chat.id) return;
      ref
          .read(chatThreadViewModelProvider(_threadArgs))
          .updatePinnedState(
            messageId: messageId,
            pinned: type == 'message_pinned',
          );
      return;
    }

    if (type == 'reaction_added' || type == 'reaction_removed') {
      final chatId = map['chat_id'];
      if (chatId is! int || chatId != widget.chat.id) return;
      unawaited(
        ref.read(chatThreadViewModelProvider(_threadArgs)).loadMessages(
          silent: true,
        ),
      );
    }
  }

  void _ackUnreadMessages() {
    for (final message in _messages) {
      _ackMessageRead(message);
    }
  }

  void _ackMessageRead(MessageItem message) {
    if (message.chatId != widget.chat.id) return;
    if (message.senderId == widget.me.id) return;
    if (message.status == 'read') return;
    _sendRealtime({
      'type': 'seen',
      'chat_id': widget.chat.id,
      'message_id': message.id,
    });
  }

  void _onComposerChanged(String _) {
    final hasText = _messageController.text.trim().isNotEmpty;
    _scheduleDraftSave();
    if (hasText && !_typingSent) {
      _typingSent = true;
      _sendRealtime({
        'type': 'typing',
        'chat_id': widget.chat.id,
        'is_typing': true,
      });
    }

    _typingPauseTimer?.cancel();
    if (!hasText) {
      _notifyTypingStopped();
      if (mounted) setState(() {});
      return;
    }

    _typingPauseTimer = Timer(const Duration(seconds: 2), _notifyTypingStopped);
    if (mounted) setState(() {});
  }

  void _notifyTypingStopped() {
    _typingPauseTimer?.cancel();
    _typingPauseTimer = null;
    if (!_typingSent) return;
    _typingSent = false;
    _sendRealtime({
      'type': 'typing',
      'chat_id': widget.chat.id,
      'is_typing': false,
    });
  }

  Future<void> _sendMessage() async {
    final text = _messageController.text.trim();
    if (text.isEmpty || _sending) return;
    final vm = ref.read(chatThreadViewModelProvider(_threadArgs));
    final error = _editingMessageId != null
        ? await vm.editMessage(messageId: _editingMessageId!, text: text)
        : await vm.sendMessage(text, replyToMessageId: _replyToMessageId);
    if (error == null) {
      _messageController.clear();
      _notifyTypingStopped();
      await _clearDraft();
      _clearComposerMode();
      _scrollToBottom();
      if (mounted) setState(() {});
      return;
    }
    _showSnack(error);
  }

  void _clearComposerMode() {
    if (!mounted) return;
    setState(() {
      _replyToMessageId = null;
      _editingMessageId = null;
    });
  }

  void _startReply(MessageItem message) {
    setState(() {
      _replyToMessageId = message.id;
      _editingMessageId = null;
    });
    _composerFocusNode.requestFocus();
  }

  void _startEdit(MessageItem message) {
    setState(() {
      _editingMessageId = message.id;
      _replyToMessageId = null;
    });
    _messageController.text = message.content;
    _messageController.selection = TextSelection.collapsed(
      offset: _messageController.text.length,
    );
    _onComposerChanged(_messageController.text);
    _composerFocusNode.requestFocus();
  }

  Future<void> _deleteMessage(MessageItem message) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Delete message'),
          content: const Text('This action removes the message from the chat.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Delete'),
            ),
          ],
        );
      },
    );
    if (confirmed != true) return;

    final error = await ref
        .read(chatThreadViewModelProvider(_threadArgs))
        .deleteRemoteMessage(message.id);
    if (error != null) {
      _showSnack(error);
      return;
    }
    if (_replyToMessageId == message.id || _editingMessageId == message.id) {
      _clearComposerMode();
      _messageController.clear();
      await _clearDraft();
    }
  }

  Future<void> _togglePin(MessageItem message) async {
    final error = await ref
        .read(chatThreadViewModelProvider(_threadArgs))
        .setMessagePinned(messageId: message.id, pinned: !message.isPinned);
    if (error != null) {
      _showSnack(error);
    }
  }

  Future<void> _showMessageActions(MessageItem message) async {
    final mine = message.senderId == widget.me.id;
    await showModalBottomSheet<void>(
      context: context,
      builder: (context) {
        return SafeArea(
          child: Wrap(
            children: [
              ListTile(
                leading: const Icon(Icons.reply_rounded),
                title: const Text('Reply'),
                onTap: () {
                  Navigator.of(context).pop();
                  _startReply(message);
                },
              ),
              if (mine)
                ListTile(
                  leading: const Icon(Icons.edit_outlined),
                  title: const Text('Edit'),
                  onTap: () {
                    Navigator.of(context).pop();
                    _startEdit(message);
                  },
                ),
              ListTile(
                leading: Icon(
                  message.isPinned
                      ? Icons.push_pin_outlined
                      : Icons.push_pin_rounded,
                ),
                title: Text(
                  message.isPinned ? 'Unpin message' : 'Pin message',
                ),
                onTap: () {
                  Navigator.of(context).pop();
                  unawaited(_togglePin(message));
                },
              ),
              if (mine)
                ListTile(
                  leading: const Icon(Icons.delete_outline_rounded),
                  title: const Text('Delete'),
                  onTap: () {
                    Navigator.of(context).pop();
                    unawaited(_deleteMessage(message));
                  },
                ),
            ],
          ),
        );
      },
    );
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    if (_scrollController.position.pixels <= context.sp(96)) {
      unawaited(_loadMoreHistory());
    }
  }

  Future<void> _loadMoreHistory() async {
    final vm = ref.read(chatThreadViewModelProvider(_threadArgs));
    if (vm.loadingMore || vm.nextBeforeId == null) return;

    final hadClients = _scrollController.hasClients;
    final previousOffset = hadClients ? _scrollController.offset : 0.0;
    final previousExtent = hadClients
        ? _scrollController.position.maxScrollExtent
        : 0.0;

    final error = await vm.loadMoreHistory();
    if (error != null) {
      _showSnack(error);
      return;
    }

    if (!hadClients) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      final delta = _scrollController.position.maxScrollExtent - previousExtent;
      final targetOffset = previousOffset + delta;
      _scrollController.jumpTo(
        targetOffset.clamp(0.0, _scrollController.position.maxScrollExtent),
      );
    });
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent + context.sp(30),
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final vm = ref.watch(chatThreadViewModelProvider(_threadArgs));
    final appearance = ref.watch(appPreferencesProvider).appearance;
    final pinnedMessage = vm.pinnedMessage;
    final replyTarget = _replyToMessageId == null
        ? null
        : _messageById(_replyToMessageId!);
    final editingTarget = _editingMessageId == null
        ? null
        : _messageById(_editingMessageId!);

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.chat.title),
        actions: [
          Icon(
            _socketConnected
                ? Icons.wifi_tethering_rounded
                : Icons.wifi_tethering_off_rounded,
            color: _socketConnected
                ? Theme.of(context).colorScheme.primary
                : Theme.of(context).colorScheme.error,
          ),
          SizedBox(width: context.sp(12)),
        ],
        bottom: _typingUserIds.isEmpty
            ? null
            : PreferredSize(
                preferredSize: Size.fromHeight(context.sp(20)),
                child: Padding(
                  padding: EdgeInsets.only(bottom: context.sp(6)),
                  child: Text(
                    'typing...',
                    style: TextStyle(
                      fontSize: context.sp(13),
                      color: Theme.of(context).colorScheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
      ),
      body: DecoratedBox(
        decoration: BoxDecoration(gradient: appearance.chatBackgroundGradient),
        child: Column(
          children: [
            if (pinnedMessage != null)
              Container(
                margin: EdgeInsets.fromLTRB(
                  context.sp(12),
                  context.sp(10),
                  context.sp(12),
                  0,
                ),
                padding: EdgeInsets.symmetric(
                  horizontal: context.sp(12),
                  vertical: context.sp(10),
                ),
                decoration: BoxDecoration(
                  color: appearance.surfaceColor.withValues(alpha: 0.92),
                  borderRadius: BorderRadius.circular(context.sp(16)),
                  border: Border.all(color: appearance.outlineColor),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.push_pin_rounded,
                      size: context.sp(18),
                      color: appearance.accentColor,
                    ),
                    SizedBox(width: context.sp(10)),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Pinned message',
                            style: TextStyle(
                              fontSize: context.sp(12),
                              fontWeight: FontWeight.w700,
                              color: appearance.accentColor,
                            ),
                          ),
                          SizedBox(height: context.sp(2)),
                          Text(
                            pinnedMessage.content.trim().isEmpty
                                ? 'Pinned media message'
                                : pinnedMessage.content,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: 'Unpin',
                      onPressed: () => unawaited(_togglePin(pinnedMessage)),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
              ),
            Expanded(
              child: vm.loading
                  ? const Center(child: CircularProgressIndicator())
                  : vm.messages.isEmpty
                  ? Center(
                      child: Text(
                        'No messages yet. Start the conversation.',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    )
                  : ListView.builder(
                      controller: _scrollController,
                      padding: EdgeInsets.symmetric(
                        horizontal: context.sp(12),
                        vertical: context.sp(10),
                      ),
                      itemCount: vm.messages.length + 1,
                      itemBuilder: (context, index) {
                        if (index == 0) {
                          if (vm.loadingMore) {
                            return Padding(
                              padding: EdgeInsets.only(bottom: context.sp(8)),
                              child: const Center(
                                child: CircularProgressIndicator(),
                              ),
                            );
                          }
                          if (vm.nextBeforeId != null) {
                            return Padding(
                              padding: EdgeInsets.only(bottom: context.sp(8)),
                              child: Center(
                                child: OutlinedButton.icon(
                                  onPressed: _loadMoreHistory,
                                  icon: const Icon(Icons.history_rounded),
                                  label: const Text('Load earlier messages'),
                                ),
                              ),
                            );
                          }
                          return const SizedBox.shrink();
                        }

                        final message = vm.messages[index - 1];
                        final mine = message.senderId == widget.me.id;
                        return _MessageBubble(
                          message: message,
                          repliedMessage: message.replyToMessageId == null
                              ? null
                              : vm.findMessageById(message.replyToMessageId!),
                          mine: mine,
                          appearance: appearance,
                          onLongPress: () => _showMessageActions(message),
                        );
                      },
                    ),
            ),
            SafeArea(
              top: false,
              child: Container(
                padding: EdgeInsets.fromLTRB(
                  context.sp(10),
                  context.sp(8),
                  context.sp(10),
                  context.sp(10),
                ),
                decoration: BoxDecoration(
                  color: appearance.surfaceColor.withValues(alpha: 0.94),
                  border: Border(
                    top: BorderSide(color: appearance.outlineColor),
                  ),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (_editingMessageId != null || _replyToMessageId != null)
                      Container(
                        width: double.infinity,
                        margin: EdgeInsets.only(bottom: context.sp(8)),
                        padding: EdgeInsets.symmetric(
                          horizontal: context.sp(12),
                          vertical: context.sp(10),
                        ),
                        decoration: BoxDecoration(
                          color: appearance.accentColorMuted.withValues(
                            alpha: 0.84,
                          ),
                          borderRadius: BorderRadius.circular(context.sp(14)),
                          border: Border.all(color: appearance.outlineColor),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              _editingMessageId != null
                                  ? Icons.edit_outlined
                                  : Icons.reply_rounded,
                              size: context.sp(18),
                              color: appearance.accentColor,
                            ),
                            SizedBox(width: context.sp(10)),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    _editingMessageId != null
                                        ? 'Editing message'
                                        : 'Replying',
                                    style: TextStyle(
                                      fontSize: context.sp(12),
                                      fontWeight: FontWeight.w700,
                                      color: appearance.accentColor,
                                    ),
                                  ),
                                  SizedBox(height: context.sp(2)),
                                  Text(
                                    (_editingMessageId != null
                                                ? editingTarget?.content
                                                : replyTarget?.content)
                                            ?.trim()
                                            .isNotEmpty ==
                                        true
                                        ? (_editingMessageId != null
                                              ? editingTarget!.content
                                              : replyTarget!.content)
                                        : 'Selected message',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                              ),
                            ),
                            IconButton(
                              onPressed: _clearComposerMode,
                              icon: const Icon(Icons.close_rounded),
                            ),
                          ],
                        ),
                      ),
                    if (_messageController.text.trim().isNotEmpty)
                      Padding(
                        padding: EdgeInsets.only(bottom: context.sp(6)),
                        child: Text(
                          'Draft is saved automatically',
                          style: TextStyle(
                            fontSize: context.sp(11),
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _messageController,
                            focusNode: _composerFocusNode,
                            minLines: 1,
                            maxLines: 5,
                            decoration: InputDecoration(
                              hintText: _editingMessageId != null
                                  ? 'Edit message'
                                  : 'Message',
                            ),
                            onChanged: _onComposerChanged,
                          ),
                        ),
                        SizedBox(width: context.sp(8)),
                        FilledButton(
                          onPressed:
                              _messageController.text.trim().isNotEmpty &&
                                  !vm.sending
                              ? _sendMessage
                              : null,
                          child: vm.sending
                              ? SizedBox(
                                  width: context.sp(16),
                                  height: context.sp(16),
                                  child: const CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.send_rounded),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  final MessageItem message;
  final MessageItem? repliedMessage;
  final bool mine;
  final AppAppearanceData appearance;
  final VoidCallback? onLongPress;

  const _MessageBubble({
    required this.message,
    required this.repliedMessage,
    required this.mine,
    required this.appearance,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final bubbleColor = mine
        ? appearance.outgoingBubbleColor
        : appearance.incomingBubbleColor;
    final borderColor = mine
        ? appearance.outgoingBubbleBorderColor
        : appearance.incomingBubbleBorderColor;
    final alignment = mine ? Alignment.centerRight : Alignment.centerLeft;
    final textSize = context.sp(15) * appearance.messageTextScale;
    final metaSize =
        context.sp(11) * appearance.messageTextScale.clamp(0.95, 1.15);
    final radius = BorderRadius.only(
      topLeft: Radius.circular(context.sp(16)),
      topRight: Radius.circular(context.sp(16)),
      bottomLeft: Radius.circular(mine ? context.sp(16) : context.sp(4)),
      bottomRight: Radius.circular(mine ? context.sp(4) : context.sp(16)),
    );
    final replyPreview = repliedMessage?.content.trim().isNotEmpty == true
        ? repliedMessage!.content
        : message.replyToMessageId != null
        ? 'Reply to message'
        : null;
    final attachmentColor = Theme.of(context).colorScheme.onSurfaceVariant;

    return Align(
      alignment: alignment,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onLongPress: onLongPress,
          borderRadius: radius,
          child: Container(
            margin: EdgeInsets.symmetric(vertical: context.sp(4)),
            constraints: BoxConstraints(
              maxWidth: MediaQuery.sizeOf(context).width * 0.78,
            ),
            padding: EdgeInsets.symmetric(
              horizontal: context.sp(12),
              vertical: context.sp(8),
            ),
            decoration: BoxDecoration(
              color: bubbleColor,
              borderRadius: radius,
              border: Border.all(color: borderColor),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (replyPreview != null)
                  Container(
                    width: double.infinity,
                    margin: EdgeInsets.only(bottom: context.sp(8)),
                    padding: EdgeInsets.symmetric(
                      horizontal: context.sp(10),
                      vertical: context.sp(8),
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(context.sp(12)),
                      border: Border(
                        left: BorderSide(
                          color: appearance.accentColor,
                          width: context.sp(3),
                        ),
                      ),
                    ),
                    child: Text(
                      replyPreview,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: context.sp(12) * appearance.messageTextScale,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                if (message.content.trim().isNotEmpty)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      message.content,
                      style: TextStyle(fontSize: textSize),
                    ),
                  ),
                if (message.attachments.isNotEmpty)
                  Padding(
                    padding: EdgeInsets.only(
                      top: message.content.trim().isEmpty ? 0 : context.sp(8),
                    ),
                    child: Column(
                      children: message.attachments
                          .map(
                            (attachment) => Container(
                              width: double.infinity,
                              margin: EdgeInsets.only(bottom: context.sp(6)),
                              padding: EdgeInsets.symmetric(
                                horizontal: context.sp(10),
                                vertical: context.sp(8),
                              ),
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.08),
                                borderRadius: BorderRadius.circular(
                                  context.sp(12),
                                ),
                              ),
                              child: Row(
                                children: [
                                  Icon(
                                    attachment.isImage
                                        ? Icons.image_outlined
                                        : Icons.attach_file_rounded,
                                    size: context.sp(18),
                                    color: attachmentColor,
                                  ),
                                  SizedBox(width: context.sp(8)),
                                  Expanded(
                                    child: Text(
                                      attachment.fileName,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize:
                                            context.sp(13) *
                                            appearance.messageTextScale,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          )
                          .toList(),
                    ),
                  ),
                if (message.reactions.isNotEmpty)
                  Padding(
                    padding: EdgeInsets.only(top: context.sp(4)),
                    child: Wrap(
                      spacing: context.sp(6),
                      runSpacing: context.sp(6),
                      children: message.reactions
                          .map(
                            (reaction) => Container(
                              padding: EdgeInsets.symmetric(
                                horizontal: context.sp(8),
                                vertical: context.sp(4),
                              ),
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(999),
                                border: Border.all(
                                  color: reaction.reactedByMe
                                      ? appearance.accentColor
                                      : borderColor,
                                ),
                              ),
                              child: Text(
                                '${reaction.emoji} ${reaction.count}',
                                style: TextStyle(
                                  fontSize:
                                      context.sp(11) *
                                      appearance.messageTextScale,
                                ),
                              ),
                            ),
                          )
                          .toList(),
                    ),
                  ),
                SizedBox(height: context.sp(4)),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (message.isPinned)
                      Padding(
                        padding: EdgeInsets.only(right: context.sp(4)),
                        child: Icon(
                          Icons.push_pin_rounded,
                          size: context.sp(14),
                          color: appearance.accentColor,
                        ),
                      ),
                    if (message.editedAt != null)
                      Padding(
                        padding: EdgeInsets.only(right: context.sp(6)),
                        child: Text(
                          'edited',
                          style: TextStyle(
                            fontSize: metaSize,
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    Text(
                      '${message.createdAt.hour.toString().padLeft(2, '0')}:${message.createdAt.minute.toString().padLeft(2, '0')} ${mine ? _statusMark(message.status) : ''}',
                      style: TextStyle(
                        fontSize: metaSize,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _statusMark(String status) {
    switch (status) {
      case 'read':
        return '\u2713\u2713';
      case 'delivered':
        return '\u2713';
      default:
        return '';
    }
  }
}
