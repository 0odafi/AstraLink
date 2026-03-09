import 'dart:async';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../api.dart';
import '../../../core/realtime/realtime_cursor_store.dart';
import '../../../core/ui/adaptive_size.dart';
import '../../../core/ui/app_appearance.dart';
import '../../../models.dart';
import '../../../realtime.dart';
import '../../settings/application/app_preferences.dart';
import '../application/chat_view_models.dart';
import '../data/chat_drafts_local_cache.dart';

const List<String> _kQuickReactionEmoji = <String>[
  '👍',
  '❤️',
  '🔥',
  '😂',
  '😮',
  '😢',
];

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
  final AudioRecorder _audioRecorder = AudioRecorder();

  RealtimeMeSocket? _realtime;
  Timer? _typingPauseTimer;
  Timer? _draftDebounce;
  Timer? _voiceTicker;
  bool _typingSent = false;
  bool _socketConnected = false;
  bool _voiceRecording = false;
  bool _voiceUploading = false;
  final Set<int> _typingUserIds = <int>{};
  int _realtimeCursor = 0;
  int? _replyToMessageId;
  int? _editingMessageId;
  int _attachmentSeed = 0;
  DateTime? _voiceRecordingStartedAt;
  Duration _voiceRecordingDuration = Duration.zero;
  List<_PendingComposerAttachment> _pendingAttachments =
      const <_PendingComposerAttachment>[];

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
      _pendingAttachments = const <_PendingComposerAttachment>[];
      unawaited(_loadDraft());
      unawaited(_bootstrapRealtime());
    }
  }

  @override
  void dispose() {
    _notifyTypingStopped();
    _typingPauseTimer?.cancel();
    _draftDebounce?.cancel();
    _voiceTicker?.cancel();
    unawaited(_audioRecorder.dispose());
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

  bool get _hasUploadingAttachments {
    return _pendingAttachments.any((item) => item.isUploading);
  }

  bool get _hasFailedAttachments {
    return _pendingAttachments.any((item) => item.errorMessage != null);
  }

  List<int> get _readyAttachmentIds {
    return _pendingAttachments
        .map((item) => item.uploadedAttachment?.id)
        .whereType<int>()
        .toList();
  }

  bool get _canSend {
    final hasPayload = _editingMessageId != null
        ? _messageController.text.trim().isNotEmpty
        : (_messageController.text.trim().isNotEmpty ||
              _readyAttachmentIds.isNotEmpty);
    return hasPayload &&
        !_sending &&
        !_voiceRecording &&
        !_voiceUploading &&
        !_hasUploadingAttachments &&
        !_hasFailedAttachments;
  }

  bool get _canRecordVoice {
    return !_voiceRecording &&
        !_voiceUploading &&
        !_sending &&
        !_hasUploadingAttachments &&
        _editingMessageId == null;
  }

  bool get _supportsQuickMediaCapture {
    if (kIsWeb) return false;
    return defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;
  }

  MessageItem? _messageById(int messageId) {
    return ref
        .read(chatThreadViewModelProvider(_threadArgs))
        .findMessageById(messageId);
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
        ref
            .read(chatThreadViewModelProvider(_threadArgs))
            .loadMessages(silent: true),
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

  Future<void> _startVoiceRecording() async {
    if (!_canRecordVoice) return;
    if (kIsWeb) {
      _showSnack('Voice messages are not available on web yet');
      return;
    }

    final granted = await _audioRecorder.hasPermission();
    if (!granted) {
      _showSnack('Microphone permission denied');
      return;
    }

    try {
      _notifyTypingStopped();
      _composerFocusNode.unfocus();
      final directory = await getTemporaryDirectory();
      final recordingPath =
          '${directory.path}/voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
      await _audioRecorder.start(
        const RecordConfig(
          encoder: AudioEncoder.aacLc,
          bitRate: 128000,
          sampleRate: 44100,
        ),
        path: recordingPath,
      );
      _voiceTicker?.cancel();
      final startedAt = DateTime.now();
      if (!mounted) return;
      setState(() {
        _voiceRecording = true;
        _voiceUploading = false;
        _voiceRecordingStartedAt = startedAt;
        _voiceRecordingDuration = Duration.zero;
      });
      _voiceTicker = Timer.periodic(const Duration(seconds: 1), (_) {
        final base = _voiceRecordingStartedAt;
        if (!mounted || !_voiceRecording || base == null) return;
        setState(() {
          _voiceRecordingDuration = DateTime.now().difference(base);
        });
      });
    } catch (error) {
      _showSnack('Could not start voice recording');
    }
  }

  Future<void> _cancelVoiceRecording() async {
    if (!_voiceRecording) return;
    try {
      await _audioRecorder.cancel();
    } catch (_) {
      // Best-effort cleanup for temporary recording file.
    }
    _voiceTicker?.cancel();
    if (!mounted) return;
    setState(() {
      _voiceRecording = false;
      _voiceUploading = false;
      _voiceRecordingStartedAt = null;
      _voiceRecordingDuration = Duration.zero;
    });
  }

  Future<void> _finishVoiceRecording() async {
    if (!_voiceRecording) return;
    final tokens = widget.getTokens();
    if (tokens == null) {
      await _cancelVoiceRecording();
      _showSnack('Session expired');
      return;
    }

    String? recordingPath;
    try {
      recordingPath = await _audioRecorder.stop();
    } catch (_) {
      recordingPath = null;
    }

    _voiceTicker?.cancel();
    if (!mounted) return;
    setState(() {
      _voiceRecording = false;
      _voiceUploading = true;
      _voiceRecordingStartedAt = null;
      _voiceRecordingDuration = Duration.zero;
    });

    if (recordingPath == null || recordingPath.trim().isEmpty) {
      if (mounted) {
        setState(() => _voiceUploading = false);
      }
      _showSnack('Voice message was not recorded');
      return;
    }

    try {
      final uploaded = await widget.api.uploadChatMedia(
        accessToken: tokens.accessToken,
        refreshToken: tokens.refreshToken,
        chatId: widget.chat.id,
        fileName: 'voice_${DateTime.now().millisecondsSinceEpoch}.m4a',
        filePath: recordingPath,
      );
      final error = await ref
          .read(chatThreadViewModelProvider(_threadArgs))
          .sendMessage('', attachmentIds: <int>[uploaded.id]);
      if (error != null) {
        _showSnack(error);
      } else {
        _scrollToBottom();
      }
    } catch (error) {
      _showSnack(error.toString());
    } finally {
      if (mounted) {
        setState(() => _voiceUploading = false);
      }
    }
  }

  Future<void> _sendMessage() async {
    final text = _messageController.text.trim();
    if (!_canSend) return;
    final vm = ref.read(chatThreadViewModelProvider(_threadArgs));
    final error = _editingMessageId != null
        ? await vm.editMessage(messageId: _editingMessageId!, text: text)
        : await vm.sendMessage(
            text,
            replyToMessageId: _replyToMessageId,
            attachmentIds: _readyAttachmentIds,
          );
    if (error == null) {
      _messageController.clear();
      _notifyTypingStopped();
      await _clearDraft();
      _clearComposerMode();
      if (mounted) {
        setState(() {
          _pendingAttachments = const <_PendingComposerAttachment>[];
        });
      }
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
      _pendingAttachments = const <_PendingComposerAttachment>[];
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
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: EdgeInsets.fromLTRB(
                  context.sp(16),
                  context.sp(12),
                  context.sp(16),
                  context.sp(8),
                ),
                child: Row(
                  children: _kQuickReactionEmoji
                      .map(
                        (emoji) => Expanded(
                          child: Padding(
                            padding: EdgeInsets.symmetric(
                              horizontal: context.sp(4),
                            ),
                            child: _QuickReactionButton(
                              emoji: emoji,
                              active: message.reactions.any(
                                (reaction) =>
                                    reaction.emoji == emoji &&
                                    reaction.reactedByMe,
                              ),
                              onTap: () {
                                Navigator.of(context).pop();
                                unawaited(
                                  _toggleReaction(
                                    message: message,
                                    emoji: emoji,
                                  ),
                                );
                              },
                            ),
                          ),
                        ),
                      )
                      .toList(),
                ),
              ),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
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
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _showAttachOptions() async {
    if (!_supportsQuickMediaCapture) {
      await _pickAttachments();
      return;
    }

    await showModalBottomSheet<void>(
      context: context,
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.photo_library_outlined),
                title: const Text('Gallery'),
                subtitle: const Text('Pick a photo from device gallery'),
                onTap: () {
                  Navigator.of(context).pop();
                  unawaited(_pickGalleryImage());
                },
              ),
              ListTile(
                leading: const Icon(Icons.photo_camera_outlined),
                title: const Text('Camera'),
                subtitle: const Text('Capture a photo now'),
                onTap: () {
                  Navigator.of(context).pop();
                  unawaited(_capturePhoto());
                },
              ),
              ListTile(
                leading: const Icon(Icons.attach_file_rounded),
                title: const Text('Files'),
                subtitle: const Text('Browse documents and media files'),
                onTap: () {
                  Navigator.of(context).pop();
                  unawaited(_pickAttachments());
                },
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _pickAttachments() async {
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      withData: kIsWeb,
    );
    if (result == null || result.files.isEmpty || !mounted) return;

    final selected = result.files.map((file) {
      final localId = ++_attachmentSeed;
      return _PendingComposerAttachment.fromPlatformFile(
        localId: localId,
        file: file,
      );
    }).toList();

    _queuePendingAttachments(selected);
  }

  Future<void> _pickGalleryImage() async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 92,
    );
    if (picked == null || !mounted) return;

    final pending = await _pendingFromXFile(
      file: picked,
      fallbackName: 'gallery_${DateTime.now().millisecondsSinceEpoch}.jpg',
    );
    if (pending == null || !mounted) return;
    _queuePendingAttachments(<_PendingComposerAttachment>[pending]);
  }

  Future<void> _capturePhoto() async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(
      source: ImageSource.camera,
      preferredCameraDevice: CameraDevice.rear,
      imageQuality: 90,
    );
    if (picked == null || !mounted) return;

    final pending = await _pendingFromXFile(
      file: picked,
      fallbackName: 'camera_${DateTime.now().millisecondsSinceEpoch}.jpg',
    );
    if (pending == null || !mounted) return;
    _queuePendingAttachments(<_PendingComposerAttachment>[pending]);
  }

  Future<_PendingComposerAttachment?> _pendingFromXFile({
    required XFile file,
    required String fallbackName,
  }) async {
    try {
      final filePath = file.path.trim();
      final bytes = kIsWeb || filePath.isEmpty
          ? await file.readAsBytes()
          : null;
      final size = await file.length();
      return _PendingComposerAttachment(
        localId: ++_attachmentSeed,
        name: file.name.isEmpty ? fallbackName : file.name,
        sizeBytes: size,
        isImage: true,
        isAudio: false,
        filePath: filePath.isEmpty ? null : filePath,
        bytes: bytes,
        isUploading: true,
        errorMessage: null,
        uploadedAttachment: null,
      );
    } catch (error) {
      _showSnack('Could not prepare picked media');
      return null;
    }
  }

  void _queuePendingAttachments(List<_PendingComposerAttachment> selected) {
    if (selected.isEmpty || !mounted) return;
    setState(() {
      _pendingAttachments = [..._pendingAttachments, ...selected];
    });
    for (final item in selected) {
      unawaited(_uploadAttachment(item.localId));
    }
  }

  Future<void> _uploadAttachment(int localId) async {
    final tokens = widget.getTokens();
    if (tokens == null) {
      _updatePendingAttachment(
        localId,
        (item) =>
            item.copyWith(isUploading: false, errorMessage: 'Session expired'),
      );
      return;
    }

    final current = _pendingAttachments.where(
      (item) => item.localId == localId,
    );
    if (current.isEmpty) return;

    _updatePendingAttachment(
      localId,
      (item) => item.copyWith(isUploading: true, errorMessage: null),
    );

    final item = current.first;
    try {
      final uploaded = await widget.api.uploadChatMedia(
        accessToken: tokens.accessToken,
        refreshToken: tokens.refreshToken,
        chatId: widget.chat.id,
        fileName: item.name,
        filePath: item.filePath,
        bytes: item.bytes,
      );
      _updatePendingAttachment(
        localId,
        (pending) => pending.copyWith(
          isUploading: false,
          uploadedAttachment: uploaded,
          errorMessage: null,
        ),
      );
    } catch (error) {
      _updatePendingAttachment(
        localId,
        (pending) => pending.copyWith(
          isUploading: false,
          errorMessage: error.toString(),
        ),
      );
    }
  }

  void _updatePendingAttachment(
    int localId,
    _PendingComposerAttachment Function(_PendingComposerAttachment current)
    transform,
  ) {
    if (!mounted) return;
    setState(() {
      _pendingAttachments = _pendingAttachments.map((item) {
        if (item.localId != localId) return item;
        return transform(item);
      }).toList();
    });
  }

  void _removePendingAttachment(int localId) {
    if (!mounted) return;
    setState(() {
      _pendingAttachments = _pendingAttachments
          .where((item) => item.localId != localId)
          .toList();
    });
  }

  Future<void> _retryAttachment(_PendingComposerAttachment item) async {
    await _uploadAttachment(item.localId);
  }

  Future<void> _openAttachment(MessageAttachmentItem attachment) async {
    final uri = Uri.tryParse(widget.api.resolveUrl(attachment.url));
    if (uri == null) {
      _showSnack('Attachment URL is invalid');
      return;
    }
    final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!opened) {
      _showSnack('Could not open attachment');
    }
  }

  Future<void> _toggleReaction({
    required MessageItem message,
    required String emoji,
    bool? reactedByMe,
  }) async {
    final existing = message.reactions.where((item) => item.emoji == emoji);
    final alreadyReacted =
        reactedByMe ?? (existing.isNotEmpty && existing.first.reactedByMe);
    final error = await ref
        .read(chatThreadViewModelProvider(_threadArgs))
        .toggleReaction(
          messageId: message.id,
          emoji: emoji,
          reactedByMe: alreadyReacted,
        );
    if (error != null) {
      _showSnack(error);
    }
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
                          attachmentUrlBuilder: widget.api.resolveUrl,
                          onAttachmentTap: _openAttachment,
                          onReactionTap: (emoji, reactedByMe) =>
                              _toggleReaction(
                                message: message,
                                emoji: emoji,
                                reactedByMe: reactedByMe,
                              ),
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
                    if (_pendingAttachments.isNotEmpty)
                      Padding(
                        padding: EdgeInsets.only(bottom: context.sp(8)),
                        child: SizedBox(
                          height: context.sp(84),
                          child: ListView.separated(
                            scrollDirection: Axis.horizontal,
                            itemCount: _pendingAttachments.length,
                            separatorBuilder: (context, index) =>
                                SizedBox(width: context.sp(8)),
                            itemBuilder: (context, index) {
                              final attachment = _pendingAttachments[index];
                              return _PendingAttachmentChip(
                                attachment: attachment,
                                appearance: appearance,
                                resolveUrl: widget.api.resolveUrl,
                                onRemove: () => _removePendingAttachment(
                                  attachment.localId,
                                ),
                                onRetry: attachment.isUploading
                                    ? null
                                    : () => _retryAttachment(attachment),
                              );
                            },
                          ),
                        ),
                      ),
                    if (_voiceRecording || _voiceUploading)
                      Container(
                        width: double.infinity,
                        margin: EdgeInsets.only(bottom: context.sp(8)),
                        padding: EdgeInsets.symmetric(
                          horizontal: context.sp(12),
                          vertical: context.sp(10),
                        ),
                        decoration: BoxDecoration(
                          color: appearance.surfaceRaisedColor,
                          borderRadius: BorderRadius.circular(context.sp(16)),
                          border: Border.all(color: appearance.outlineColor),
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: context.sp(36),
                              height: context.sp(36),
                              decoration: BoxDecoration(
                                color: appearance.accentColor.withValues(
                                  alpha: 0.16,
                                ),
                                shape: BoxShape.circle,
                              ),
                              child: _voiceUploading
                                  ? Padding(
                                      padding: EdgeInsets.all(context.sp(8)),
                                      child: const CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : Icon(
                                      Icons.mic_rounded,
                                      color: appearance.accentColor,
                                    ),
                            ),
                            SizedBox(width: context.sp(12)),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    _voiceUploading
                                        ? 'Uploading voice message'
                                        : 'Recording voice message',
                                    style: TextStyle(
                                      fontSize: context.sp(13),
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  SizedBox(height: context.sp(2)),
                                  Text(
                                    _voiceUploading
                                        ? 'Please wait until upload finishes'
                                        : _formatClockDuration(
                                            _voiceRecordingDuration,
                                          ),
                                    style: TextStyle(
                                      fontSize: context.sp(12),
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            if (_voiceRecording)
                              IconButton(
                                tooltip: 'Cancel recording',
                                onPressed: _cancelVoiceRecording,
                                icon: const Icon(Icons.delete_outline_rounded),
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
                        IconButton.filledTonal(
                          tooltip: 'Attach files',
                          onPressed:
                              _editingMessageId == null &&
                                  !_voiceRecording &&
                                  !_voiceUploading
                              ? _showAttachOptions
                              : null,
                          icon: const Icon(Icons.attach_file_rounded),
                        ),
                        SizedBox(width: context.sp(8)),
                        Expanded(
                          child: TextField(
                            controller: _messageController,
                            focusNode: _composerFocusNode,
                            minLines: 1,
                            maxLines: 5,
                            enabled: !_voiceRecording && !_voiceUploading,
                            decoration: InputDecoration(
                              hintText: _editingMessageId != null
                                  ? 'Edit message'
                                  : 'Message',
                            ),
                            onChanged: _onComposerChanged,
                          ),
                        ),
                        SizedBox(width: context.sp(8)),
                        IconButton.filledTonal(
                          tooltip: _voiceRecording
                              ? 'Stop and send voice message'
                              : 'Record voice message',
                          onPressed: _voiceUploading
                              ? null
                              : _voiceRecording
                              ? _finishVoiceRecording
                              : _canRecordVoice
                              ? _startVoiceRecording
                              : null,
                          icon: _voiceUploading
                              ? SizedBox(
                                  width: context.sp(16),
                                  height: context.sp(16),
                                  child: const CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : Icon(
                                  _voiceRecording
                                      ? Icons.stop_rounded
                                      : Icons.mic_none_rounded,
                                ),
                        ),
                        SizedBox(width: context.sp(8)),
                        FilledButton(
                          onPressed: _canSend ? _sendMessage : null,
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

class _PendingAttachmentChip extends StatelessWidget {
  final _PendingComposerAttachment attachment;
  final AppAppearanceData appearance;
  final String Function(String pathOrUrl) resolveUrl;
  final VoidCallback onRemove;
  final VoidCallback? onRetry;

  const _PendingAttachmentChip({
    required this.attachment,
    required this.appearance,
    required this.resolveUrl,
    required this.onRemove,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final uploaded = attachment.uploadedAttachment;
    final previewUrl = uploaded == null ? null : resolveUrl(uploaded.url);
    return Container(
      width: context.sp(140),
      padding: EdgeInsets.all(context.sp(8)),
      decoration: BoxDecoration(
        color: appearance.surfaceRaisedColor,
        borderRadius: BorderRadius.circular(context.sp(16)),
        border: Border.all(
          color: attachment.errorMessage != null
              ? Theme.of(context).colorScheme.error
              : appearance.outlineColor,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(context.sp(12)),
              child: Container(
                width: double.infinity,
                color: Colors.black.withValues(alpha: 0.08),
                child: uploaded?.isImage == true && previewUrl != null
                    ? Image.network(
                        previewUrl,
                        fit: BoxFit.cover,
                        errorBuilder: (context, error, stackTrace) =>
                            _PendingAttachmentPlaceholder(
                              attachment: attachment,
                            ),
                      )
                    : _PendingAttachmentPlaceholder(attachment: attachment),
              ),
            ),
          ),
          SizedBox(height: context.sp(8)),
          Text(
            attachment.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: context.sp(12),
              fontWeight: FontWeight.w600,
            ),
          ),
          SizedBox(height: context.sp(2)),
          Text(
            attachment.errorMessage ??
                (attachment.isUploading
                    ? 'Uploading...'
                    : uploaded != null
                    ? _formatBytes(uploaded.sizeBytes)
                    : _formatBytes(attachment.sizeBytes)),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: context.sp(10),
              color: attachment.errorMessage != null
                  ? Theme.of(context).colorScheme.error
                  : Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          SizedBox(height: context.sp(4)),
          Row(
            children: [
              if (attachment.errorMessage != null && onRetry != null)
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Retry upload',
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh_rounded),
                )
              else if (attachment.isUploading)
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: context.sp(8)),
                  child: SizedBox(
                    width: context.sp(16),
                    height: context.sp(16),
                    child: const CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              else
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: context.sp(8)),
                  child: Icon(
                    Icons.check_circle_rounded,
                    size: context.sp(18),
                    color: appearance.accentColor,
                  ),
                ),
              const Spacer(),
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: 'Remove',
                onPressed: onRemove,
                icon: const Icon(Icons.close_rounded),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PendingAttachmentPlaceholder extends StatelessWidget {
  final _PendingComposerAttachment attachment;

  const _PendingAttachmentPlaceholder({required this.attachment});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Icon(
        attachment.isImage
            ? Icons.image_outlined
            : attachment.isAudio
            ? Icons.mic_rounded
            : Icons.attach_file_rounded,
        size: context.sp(26),
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
  }
}

class _QuickReactionButton extends StatelessWidget {
  final String emoji;
  final bool active;
  final VoidCallback onTap;

  const _QuickReactionButton({
    required this.emoji,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Material(
      color: active
          ? colorScheme.primary.withValues(alpha: 0.18)
          : colorScheme.surfaceContainerHighest.withValues(alpha: 0.6),
      borderRadius: BorderRadius.circular(context.sp(14)),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(context.sp(14)),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: context.sp(10),
            vertical: context.sp(10),
          ),
          child: Center(
            child: Text(emoji, style: TextStyle(fontSize: context.sp(22))),
          ),
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
  final String Function(String pathOrUrl) attachmentUrlBuilder;
  final Future<void> Function(MessageAttachmentItem attachment)?
  onAttachmentTap;
  final Future<void> Function(String emoji, bool reactedByMe)? onReactionTap;

  const _MessageBubble({
    required this.message,
    required this.repliedMessage,
    required this.mine,
    required this.appearance,
    this.onLongPress,
    required this.attachmentUrlBuilder,
    this.onAttachmentTap,
    this.onReactionTap,
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
                            (attachment) => Padding(
                              padding: EdgeInsets.only(bottom: context.sp(6)),
                              child: InkWell(
                                borderRadius: BorderRadius.circular(
                                  context.sp(12),
                                ),
                                onTap: onAttachmentTap == null
                                    ? null
                                    : () => onAttachmentTap!(attachment),
                                child: Container(
                                  width: double.infinity,
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
                                  child: attachment.isImage
                                      ? Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            ClipRRect(
                                              borderRadius:
                                                  BorderRadius.circular(
                                                    context.sp(10),
                                                  ),
                                              child: Image.network(
                                                attachmentUrlBuilder(
                                                  attachment.url,
                                                ),
                                                height: context.sp(140),
                                                width: double.infinity,
                                                fit: BoxFit.cover,
                                                errorBuilder:
                                                    (
                                                      context,
                                                      error,
                                                      stackTrace,
                                                    ) => Container(
                                                      height: context.sp(140),
                                                      color: Colors.black
                                                          .withValues(
                                                            alpha: 0.08,
                                                          ),
                                                      alignment:
                                                          Alignment.center,
                                                      child: Icon(
                                                        Icons
                                                            .broken_image_outlined,
                                                        size: context.sp(28),
                                                        color: attachmentColor,
                                                      ),
                                                    ),
                                              ),
                                            ),
                                            SizedBox(height: context.sp(8)),
                                            Text(
                                              attachment.fileName,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                fontSize:
                                                    context.sp(13) *
                                                    appearance.messageTextScale,
                                              ),
                                            ),
                                          ],
                                        )
                                      : attachment.isAudio
                                      ? _AudioAttachmentTile(
                                          attachment: attachment,
                                          url: attachmentUrlBuilder(
                                            attachment.url,
                                          ),
                                          appearance: appearance,
                                        )
                                      : Row(
                                          children: [
                                            Icon(
                                              Icons.attach_file_rounded,
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
                                                      appearance
                                                          .messageTextScale,
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                ),
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
                            (reaction) => InkWell(
                              borderRadius: BorderRadius.circular(999),
                              onTap: onReactionTap == null
                                  ? null
                                  : () => onReactionTap!(
                                      reaction.emoji,
                                      reaction.reactedByMe,
                                    ),
                              child: Container(
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

class _AudioAttachmentTile extends StatefulWidget {
  final MessageAttachmentItem attachment;
  final String url;
  final AppAppearanceData appearance;

  const _AudioAttachmentTile({
    required this.attachment,
    required this.url,
    required this.appearance,
  });

  @override
  State<_AudioAttachmentTile> createState() => _AudioAttachmentTileState();
}

class _AudioAttachmentTileState extends State<_AudioAttachmentTile> {
  late final AudioPlayer _player;
  StreamSubscription<PlayerState>? _playerStateSubscription;
  StreamSubscription<Duration>? _positionSubscription;
  StreamSubscription<Duration>? _durationSubscription;
  StreamSubscription<void>? _playerCompleteSubscription;
  PlayerState _playerState = PlayerState.stopped;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;

  @override
  void initState() {
    super.initState();
    _player = AudioPlayer();
    _playerStateSubscription = _player.onPlayerStateChanged.listen((state) {
      if (!mounted) return;
      setState(() => _playerState = state);
    });
    _positionSubscription = _player.onPositionChanged.listen((position) {
      if (!mounted) return;
      setState(() => _position = position);
    });
    _durationSubscription = _player.onDurationChanged.listen((duration) {
      if (!mounted) return;
      setState(() => _duration = duration);
    });
    _playerCompleteSubscription = _player.onPlayerComplete.listen((_) {
      if (!mounted) return;
      setState(() {
        _playerState = PlayerState.completed;
        _position = _duration;
      });
    });
  }

  @override
  void dispose() {
    _playerStateSubscription?.cancel();
    _positionSubscription?.cancel();
    _durationSubscription?.cancel();
    _playerCompleteSubscription?.cancel();
    unawaited(_player.dispose());
    super.dispose();
  }

  Future<void> _togglePlayback() async {
    try {
      if (_playerState == PlayerState.playing) {
        await _player.pause();
        return;
      }
      if (_playerState == PlayerState.paused) {
        await _player.resume();
        return;
      }
      if (_playerState == PlayerState.completed) {
        await _player.seek(Duration.zero);
      }
      await _player.play(UrlSource(widget.url));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not play audio attachment')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final active = _playerState == PlayerState.playing;
    final total = _duration.inMilliseconds <= 0
        ? 1.0
        : _duration.inMilliseconds.toDouble();
    final progress = (_position.inMilliseconds / total).clamp(0.0, 1.0);
    final shownDuration = _duration.inMilliseconds > 0 ? _duration : _position;

    return Row(
      children: [
        IconButton.filledTonal(
          tooltip: active ? 'Pause' : 'Play',
          onPressed: _togglePlayback,
          icon: Icon(active ? Icons.pause_rounded : Icons.play_arrow_rounded),
        ),
        SizedBox(width: context.sp(8)),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                widget.attachment.displayLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: context.sp(13) * widget.appearance.messageTextScale,
                  fontWeight: FontWeight.w600,
                ),
              ),
              SizedBox(height: context.sp(4)),
              ClipRRect(
                borderRadius: BorderRadius.circular(999),
                child: LinearProgressIndicator(
                  value: progress,
                  minHeight: context.sp(5),
                  backgroundColor: Colors.black.withValues(alpha: 0.08),
                ),
              ),
              SizedBox(height: context.sp(4)),
              Text(
                '${_formatClockDuration(_position)} / ${_formatClockDuration(shownDuration)}',
                style: TextStyle(
                  fontSize: context.sp(11) * widget.appearance.messageTextScale,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _PendingComposerAttachment {
  final int localId;
  final String name;
  final int sizeBytes;
  final bool isImage;
  final bool isAudio;
  final String? filePath;
  final Uint8List? bytes;
  final bool isUploading;
  final String? errorMessage;
  final MessageAttachmentItem? uploadedAttachment;

  const _PendingComposerAttachment({
    required this.localId,
    required this.name,
    required this.sizeBytes,
    required this.isImage,
    required this.isAudio,
    required this.filePath,
    required this.bytes,
    required this.isUploading,
    required this.errorMessage,
    required this.uploadedAttachment,
  });

  factory _PendingComposerAttachment.fromPlatformFile({
    required int localId,
    required PlatformFile file,
  }) {
    final lowerName = file.name.toLowerCase();
    return _PendingComposerAttachment(
      localId: localId,
      name: file.name,
      sizeBytes: file.size,
      isImage:
          lowerName.endsWith('.png') ||
          lowerName.endsWith('.jpg') ||
          lowerName.endsWith('.jpeg') ||
          lowerName.endsWith('.gif') ||
          lowerName.endsWith('.webp'),
      isAudio:
          lowerName.endsWith('.m4a') ||
          lowerName.endsWith('.aac') ||
          lowerName.endsWith('.mp3') ||
          lowerName.endsWith('.wav') ||
          lowerName.endsWith('.ogg') ||
          lowerName.endsWith('.oga'),
      filePath: file.path,
      bytes: file.bytes,
      isUploading: true,
      errorMessage: null,
      uploadedAttachment: null,
    );
  }

  _PendingComposerAttachment copyWith({
    int? localId,
    String? name,
    int? sizeBytes,
    bool? isImage,
    bool? isAudio,
    Object? filePath = _pendingAttachmentSentinel,
    Object? bytes = _pendingAttachmentSentinel,
    bool? isUploading,
    Object? errorMessage = _pendingAttachmentSentinel,
    Object? uploadedAttachment = _pendingAttachmentSentinel,
  }) {
    return _PendingComposerAttachment(
      localId: localId ?? this.localId,
      name: name ?? this.name,
      sizeBytes: sizeBytes ?? this.sizeBytes,
      isImage: isImage ?? this.isImage,
      isAudio: isAudio ?? this.isAudio,
      filePath: filePath == _pendingAttachmentSentinel
          ? this.filePath
          : filePath as String?,
      bytes: bytes == _pendingAttachmentSentinel
          ? this.bytes
          : bytes as Uint8List?,
      isUploading: isUploading ?? this.isUploading,
      errorMessage: errorMessage == _pendingAttachmentSentinel
          ? this.errorMessage
          : errorMessage as String?,
      uploadedAttachment: uploadedAttachment == _pendingAttachmentSentinel
          ? this.uploadedAttachment
          : uploadedAttachment as MessageAttachmentItem?,
    );
  }
}

const Object _pendingAttachmentSentinel = Object();

String _formatClockDuration(Duration duration) {
  final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
  final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
  final hours = duration.inHours;
  if (hours > 0) {
    return '${hours.toString().padLeft(2, '0')}:$minutes:$seconds';
  }
  return '$minutes:$seconds';
}

String _formatBytes(int bytes) {
  if (bytes >= 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  if (bytes >= 1024) {
    return '${(bytes / 1024).toStringAsFixed(1)} KB';
  }
  return '$bytes B';
}
