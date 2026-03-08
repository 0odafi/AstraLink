import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../api.dart';
import '../../../core/ui/adaptive_size.dart';
import '../../../models.dart';
import '../../../realtime.dart';
import '../application/chat_view_models.dart';

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
  late ChatListVmArgs _args;
  RealtimeMeSocket? _realtime;
  Timer? _refreshDebounce;
  bool _socketConnected = false;

  @override
  void initState() {
    super.initState();
    _args = ChatListVmArgs(
      api: widget.api,
      getTokens: widget.getTokens,
      me: widget.me,
    );
    unawaited(ref.read(chatListViewModelProvider(_args)).prime());
    _startRealtime();
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
      _startRealtime();
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

  void _startRealtime() {
    _realtime?.stop();
    _realtime = RealtimeMeSocket(
      urlBuilder: _buildRealtimeUrl,
      onEvent: _handleRealtimeEvent,
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
              labelText: 'Phone or username',
              hintText: '+7900... or username',
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
                hintText: 'Search chats',
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
            Row(
              children: [
                FilterChip(
                  label: const Text('All'),
                  selected: vm.activeFilter == 'all',
                  onSelected: (_) {
                    if (vm.activeFilter == 'all') return;
                    ref.read(chatListViewModelProvider(_args)).setFilter('all');
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
                const Spacer(),
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
                                return _ChatTile(
                                  chat: chat,
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
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  const _ChatTile({required this.chat, required this.onTap, this.onLongPress});

  @override
  Widget build(BuildContext context) {
    final subtitle = chat.lastMessagePreview?.trim().isNotEmpty == true
        ? chat.lastMessagePreview!
        : 'No messages yet';
    final lastTime = chat.lastMessageAt;

    return Card(
      child: ListTile(
        onTap: onTap,
        onLongPress: onLongPress,
        leading: CircleAvatar(
          backgroundColor: Theme.of(
            context,
          ).colorScheme.primary.withValues(alpha: 0.2),
          child: Text(
            chat.title.isEmpty
                ? '?'
                : chat.title.characters.first.toUpperCase(),
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
        ),
        title: Text(
          '${chat.isPinned ? '[PIN] ' : ''}${chat.title}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        subtitle: Text(
          chat.isArchived ? '[Archived] $subtitle' : subtitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: Column(
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
                margin: const EdgeInsets.only(top: 4),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(999),
                  color: Theme.of(context).colorScheme.primary,
                ),
                child: Text(
                  '${chat.unreadCount}',
                  style: const TextStyle(
                    color: Colors.black,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
          ],
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
  final _messageController = TextEditingController();
  final _scrollController = ScrollController();

  RealtimeMeSocket? _realtime;
  Timer? _typingPauseTimer;
  bool _typingSent = false;
  bool _socketConnected = false;
  final Set<int> _typingUserIds = <int>{};

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
    _startRealtime();
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
      _startRealtime();
    }
  }

  @override
  void dispose() {
    _notifyTypingStopped();
    _typingPauseTimer?.cancel();
    _realtime?.stop();
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  List<MessageItem> get _messages {
    return ref.read(chatThreadViewModelProvider(_threadArgs)).messages;
  }

  bool get _sending {
    return ref.read(chatThreadViewModelProvider(_threadArgs)).sending;
  }

  String _buildRealtimeUrl() {
    final tokens = widget.getTokens();
    if (tokens == null) return '';
    return '${webSocketBase(widget.api.baseUrl)}/api/realtime/me/ws?token=${Uri.encodeComponent(tokens.accessToken)}';
  }

  void _startRealtime() {
    _realtime?.stop();
    _realtime = RealtimeMeSocket(
      urlBuilder: _buildRealtimeUrl,
      onEvent: _handleRealtimeEvent,
      onState: (state) {
        if (!mounted) return;
        final connected = state == RealtimeState.connected;
        if (_socketConnected != connected) {
          setState(() => _socketConnected = connected);
        }
        if (connected) {
          _ackUnreadMessages();
        }
      },
    )..start();
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
    final error = await ref
        .read(chatThreadViewModelProvider(_threadArgs))
        .sendMessage(text);
    if (error == null) {
      _messageController.clear();
      _notifyTypingStopped();
      _scrollToBottom();
      if (mounted) setState(() {});
      return;
    }
    _showSnack(error);
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
      body: Column(
        children: [
          Expanded(
            child: vm.loading
                ? const Center(child: CircularProgressIndicator())
                : ListView.builder(
                    controller: _scrollController,
                    padding: EdgeInsets.symmetric(
                      horizontal: context.sp(12),
                      vertical: context.sp(10),
                    ),
                    itemCount: vm.messages.length,
                    itemBuilder: (context, index) {
                      final message = vm.messages[index];
                      final mine = message.senderId == widget.me.id;
                      return _MessageBubble(message: message, mine: mine);
                    },
                  ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                context.sp(10),
                context.sp(8),
                context.sp(10),
                context.sp(10),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _messageController,
                      minLines: 1,
                      maxLines: 5,
                      decoration: const InputDecoration(hintText: 'Message'),
                      onChanged: _onComposerChanged,
                    ),
                  ),
                  SizedBox(width: context.sp(8)),
                  FilledButton(
                    onPressed:
                        _messageController.text.trim().isNotEmpty && !vm.sending
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
            ),
          ),
        ],
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  final MessageItem message;
  final bool mine;

  const _MessageBubble({required this.message, required this.mine});

  @override
  Widget build(BuildContext context) {
    final bubbleColor = mine
        ? const Color(0xFF244E7A)
        : const Color(0xFF1B2736);
    final alignment = mine ? Alignment.centerRight : Alignment.centerLeft;
    final radius = BorderRadius.only(
      topLeft: Radius.circular(context.sp(16)),
      topRight: Radius.circular(context.sp(16)),
      bottomLeft: Radius.circular(mine ? context.sp(16) : context.sp(4)),
      bottomRight: Radius.circular(mine ? context.sp(4) : context.sp(16)),
    );

    return Align(
      alignment: alignment,
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
          border: Border.all(color: const Color(0xFF2B3A4A)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                message.content,
                style: TextStyle(fontSize: context.sp(15)),
              ),
            ),
            SizedBox(height: context.sp(4)),
            Text(
              '${message.createdAt.hour.toString().padLeft(2, '0')}:${message.createdAt.minute.toString().padLeft(2, '0')} ${mine ? _statusMark(message.status) : ''}',
              style: TextStyle(
                fontSize: context.sp(11),
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
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
