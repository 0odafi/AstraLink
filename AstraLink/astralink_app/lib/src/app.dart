import 'dart:async';

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import 'api.dart';
import 'models.dart';
import 'realtime.dart';
import 'session.dart';

extension AdaptiveSize on BuildContext {
  double sp(double value, {double min = 0.88, double max = 1.16}) {
    final width = MediaQuery.sizeOf(this).width;
    final scale = (width / 390).clamp(min, max).toDouble();
    return value * scale;
  }
}

ThemeData _buildTheme() {
  final scheme =
      ColorScheme.fromSeed(
        seedColor: const Color(0xFF4EA4F4),
        brightness: Brightness.dark,
      ).copyWith(
        primary: const Color(0xFF4EA4F4),
        secondary: const Color(0xFF61C1FF),
        surface: const Color(0xFF131A24),
        surfaceContainer: const Color(0xFF1B2431),
        outline: const Color(0xFF2C3A4A),
      );

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: const Color(0xFF0E141D),
    appBarTheme: const AppBarTheme(
      elevation: 0,
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
      backgroundColor: Color(0xFF0E141D),
    ),
    cardTheme: CardThemeData(
      color: const Color(0xFF151F2C),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: const BorderSide(color: Color(0xFF263444)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: const Color(0xFF1A2534),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: Color(0xFF2C3A4A)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: Color(0xFF2C3A4A)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: Color(0xFF4EA4F4), width: 1.3),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
  );
}

class AstraMessengerApp extends StatefulWidget {
  const AstraMessengerApp({super.key});

  @override
  State<AstraMessengerApp> createState() => _AstraMessengerAppState();
}

class _AstraMessengerAppState extends State<AstraMessengerApp> {
  final SessionStore _store = SessionStore();
  bool _loading = true;
  String _baseUrl = normalizeBaseUrl(kDefaultApiBaseUrl);
  String _updateChannel = 'stable';
  String _appVersion = '0.0.0+0';
  AuthTokens? _tokens;
  AppUser? _user;

  AstraApi get _api =>
      AstraApi(baseUrl: _baseUrl, onRefreshToken: _refreshFromApi);

  @override
  void initState() {
    super.initState();
    unawaited(_bootstrap());
  }

  Future<void> _bootstrap() async {
    final info = await PackageInfo.fromPlatform();
    final session = await _store.load();
    _baseUrl = session.baseUrl;
    _updateChannel = session.updateChannel;
    _appVersion = '${info.version}+${info.buildNumber}';

    if (session.isAuthenticated) {
      _tokens = AuthTokens(
        accessToken: session.accessToken!,
        refreshToken: session.refreshToken ?? '',
      );
      await _loadCurrentUser();
    }

    if (!mounted) return;
    setState(() {
      _loading = false;
    });
  }

  Future<AuthTokens?> _refreshFromApi(String refreshToken) async {
    try {
      final refreshed = await _api.refreshSession(refreshToken);
      _tokens = refreshed.tokens;
      _user = refreshed.user;
      await _store.saveSession(baseUrl: _baseUrl, tokens: _tokens);
      if (mounted) setState(() {});
      return _tokens;
    } catch (_) {
      await _performLogout();
      return null;
    }
  }

  Future<void> _loadCurrentUser() async {
    if (_tokens == null) return;
    try {
      final me = await _api.me(
        accessToken: _tokens!.accessToken,
        refreshToken: _tokens!.refreshToken,
      );
      _user = me;
    } catch (_) {
      await _performLogout();
    }
  }

  Future<void> _onAuthorized(AuthResult result) async {
    _tokens = result.tokens;
    _user = result.user;
    await _store.saveSession(baseUrl: _baseUrl, tokens: _tokens);
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _onUserUpdated(AppUser next) async {
    _user = next;
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _performLogout() async {
    _tokens = null;
    _user = null;
    await _store.saveSession(baseUrl: _baseUrl, tokens: null);
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _changeUpdateChannel(String channel) async {
    _updateChannel = channel;
    await _store.saveUpdateChannel(channel);
    if (!mounted) return;
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AstraLink',
      debugShowCheckedModeBanner: false,
      theme: _buildTheme(),
      home: _loading
          ? const _SplashScreen()
          : (_tokens == null || _user == null)
          ? AuthScreen(api: _api, onAuthorized: _onAuthorized)
          : HomeShell(
              api: _api,
              getTokens: () => _tokens,
              user: _user!,
              appVersion: _appVersion,
              updateChannel: _updateChannel,
              onUserUpdated: _onUserUpdated,
              onUpdateChannelChanged: _changeUpdateChannel,
              onLogout: _performLogout,
            ),
    );
  }
}

class _SplashScreen extends StatelessWidget {
  const _SplashScreen();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.send_rounded,
              size: context.sp(52),
              color: Theme.of(context).colorScheme.primary,
            ),
            SizedBox(height: context.sp(14)),
            Text(
              'AstraLink',
              style: TextStyle(
                fontSize: context.sp(24),
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class AuthScreen extends StatefulWidget {
  final AstraApi api;
  final Future<void> Function(AuthResult result) onAuthorized;

  const AuthScreen({super.key, required this.api, required this.onAuthorized});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final _phoneController = TextEditingController();
  final _codeController = TextEditingController();
  final _firstNameController = TextEditingController();
  final _lastNameController = TextEditingController();

  bool _loading = false;
  PhoneCodeSession? _session;

  @override
  void dispose() {
    _phoneController.dispose();
    _codeController.dispose();
    _firstNameController.dispose();
    _lastNameController.dispose();
    super.dispose();
  }

  bool get _isPhoneStep => _session == null;

  bool get _canSendCode {
    final digits = _phoneController.text.replaceAll(RegExp(r'[^0-9]'), '');
    return digits.length >= 10;
  }

  bool get _canVerify {
    final codeOk = _codeController.text.trim().length >= 4;
    if (!codeOk) return false;
    if (_session == null) return false;
    if (_session!.isRegistered) return true;
    return _firstNameController.text.trim().isNotEmpty;
  }

  Future<void> _requestCode() async {
    if (!_canSendCode || _loading) return;
    setState(() => _loading = true);
    try {
      final session = await widget.api.requestPhoneCode(_phoneController.text);
      if (!mounted) return;
      setState(() {
        _session = session;
      });
      _showSnack('Code sent to ${session.phone}');
    } catch (error) {
      _showSnack(error.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _verifyCode() async {
    if (!_canVerify || _loading || _session == null) return;
    setState(() => _loading = true);
    try {
      final result = await widget.api.verifyPhoneCode(
        phone: _session!.phone,
        codeToken: _session!.codeToken,
        code: _codeController.text.trim(),
        firstName: _session!.isRegistered
            ? null
            : _firstNameController.text.trim(),
        lastName: _session!.isRegistered
            ? null
            : _lastNameController.text.trim(),
      );
      await widget.onAuthorized(result);
    } catch (error) {
      _showSnack(error.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final horizontalPadding = context.sp(22);
    final titleStyle = TextStyle(
      fontSize: context.sp(32),
      fontWeight: FontWeight.w800,
      height: 1.1,
    );

    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: context.sp(520)),
          child: SingleChildScrollView(
            padding: EdgeInsets.symmetric(
              horizontal: horizontalPadding,
              vertical: context.sp(28),
            ),
            child: Card(
              child: Padding(
                padding: EdgeInsets.all(context.sp(20)),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.send_rounded,
                      color: Theme.of(context).colorScheme.primary,
                      size: context.sp(42),
                    ),
                    SizedBox(height: context.sp(12)),
                    Text('AstraLink', style: titleStyle),
                    SizedBox(height: context.sp(6)),
                    Text(
                      'Phone-first messenger',
                      style: TextStyle(
                        fontSize: context.sp(16),
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                    SizedBox(height: context.sp(22)),
                    if (_isPhoneStep) ...[
                      TextField(
                        controller: _phoneController,
                        keyboardType: TextInputType.phone,
                        decoration: const InputDecoration(
                          labelText: 'Phone number',
                          hintText: '+7 900 000 00 00',
                        ),
                        onChanged: (_) => setState(() {}),
                      ),
                      SizedBox(height: context.sp(16)),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: _canSendCode && !_loading
                              ? _requestCode
                              : null,
                          icon: _loading
                              ? SizedBox(
                                  width: context.sp(18),
                                  height: context.sp(18),
                                  child: const CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.sms_rounded),
                          label: const Text('Send code'),
                        ),
                      ),
                    ] else ...[
                      Text(
                        'Code sent to ${_session!.phone}',
                        style: TextStyle(
                          fontSize: context.sp(14),
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                      SizedBox(height: context.sp(10)),
                      TextField(
                        controller: _codeController,
                        keyboardType: TextInputType.number,
                        maxLength: 6,
                        decoration: const InputDecoration(
                          labelText: 'Verification code',
                        ),
                        onChanged: (_) => setState(() {}),
                      ),
                      if (!_session!.isRegistered) ...[
                        SizedBox(height: context.sp(6)),
                        TextField(
                          controller: _firstNameController,
                          decoration: const InputDecoration(
                            labelText: 'First name',
                          ),
                          onChanged: (_) => setState(() {}),
                        ),
                        SizedBox(height: context.sp(10)),
                        TextField(
                          controller: _lastNameController,
                          decoration: const InputDecoration(
                            labelText: 'Last name (optional)',
                          ),
                          onChanged: (_) => setState(() {}),
                        ),
                      ],
                      SizedBox(height: context.sp(16)),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              onPressed: _loading
                                  ? null
                                  : () {
                                      setState(() {
                                        _session = null;
                                        _codeController.clear();
                                      });
                                    },
                              child: const Text('Change number'),
                            ),
                          ),
                          SizedBox(width: context.sp(10)),
                          Expanded(
                            child: FilledButton(
                              onPressed: _canVerify && !_loading
                                  ? _verifyCode
                                  : null,
                              child: _loading
                                  ? SizedBox(
                                      width: context.sp(18),
                                      height: context.sp(18),
                                      child: const CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Text('Continue'),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class HomeShell extends StatefulWidget {
  final AstraApi api;
  final AuthTokens? Function() getTokens;
  final AppUser user;
  final String appVersion;
  final String updateChannel;
  final Future<void> Function(AppUser user) onUserUpdated;
  final Future<void> Function(String channel) onUpdateChannelChanged;
  final Future<void> Function() onLogout;

  const HomeShell({
    super.key,
    required this.api,
    required this.getTokens,
    required this.user,
    required this.appVersion,
    required this.updateChannel,
    required this.onUserUpdated,
    required this.onUpdateChannelChanged,
    required this.onLogout,
  });

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    final pages = [
      ChatsTab(api: widget.api, getTokens: widget.getTokens, me: widget.user),
      ContactsTab(
        api: widget.api,
        getTokens: widget.getTokens,
        me: widget.user,
      ),
      SettingsTab(
        api: widget.api,
        appVersion: widget.appVersion,
        updateChannel: widget.updateChannel,
        onUpdateChannelChanged: widget.onUpdateChannelChanged,
        onLogout: widget.onLogout,
      ),
      ProfileTab(
        api: widget.api,
        getTokens: widget.getTokens,
        me: widget.user,
        onUserUpdated: widget.onUserUpdated,
      ),
    ];

    return Scaffold(
      body: AnimatedSwitcher(
        duration: const Duration(milliseconds: 200),
        child: KeyedSubtree(key: ValueKey(_index), child: pages[_index]),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (value) => setState(() => _index = value),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.chat_bubble_outline),
            label: 'Chats',
          ),
          NavigationDestination(
            icon: Icon(Icons.person_search_outlined),
            label: 'Contacts',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            label: 'Settings',
          ),
          NavigationDestination(
            icon: Icon(Icons.account_circle_outlined),
            label: 'Profile',
          ),
        ],
      ),
    );
  }
}

class ChatsTab extends StatefulWidget {
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
  State<ChatsTab> createState() => _ChatsTabState();
}

class _ChatsTabState extends State<ChatsTab> {
  final _searchController = TextEditingController();
  bool _loading = true;
  List<ChatItem> _all = const [];
  bool _searchingMessages = false;
  List<MessageSearchHit> _messageHits = const [];
  String _activeFilter = 'all';
  RealtimeMeSocket? _realtime;
  Timer? _refreshDebounce;
  bool _socketConnected = false;

  @override
  void initState() {
    super.initState();
    unawaited(_loadChats());
    _startRealtime();
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
    final tokens = widget.getTokens();
    if (tokens == null) return;
    if (mounted && !silent) setState(() => _loading = true);
    try {
      final chats = await widget.api.listChats(
        accessToken: tokens.accessToken,
        refreshToken: tokens.refreshToken,
        archivedOnly: _activeFilter == 'archived',
        pinnedOnly: _activeFilter == 'pinned',
      );
      if (!mounted) return;
      setState(() {
        _all = chats;
      });
    } catch (error) {
      if (!silent) {
        _showSnack(error.toString());
      }
    } finally {
      if (mounted && !silent) setState(() => _loading = false);
    }
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  List<ChatItem> get _filtered {
    final q = _searchController.text.trim().toLowerCase();
    if (q.isEmpty) return _all;
    return _all.where((chat) {
      return chat.title.toLowerCase().contains(q) ||
          (chat.lastMessagePreview ?? '').toLowerCase().contains(q);
    }).toList();
  }

  Future<void> _searchInMessages() async {
    final query = _searchController.text.trim();
    if (query.length < 2) {
      setState(() {
        _messageHits = const [];
      });
      return;
    }

    final tokens = widget.getTokens();
    if (tokens == null) return;

    setState(() => _searchingMessages = true);
    try {
      final hits = await widget.api.searchMessages(
        accessToken: tokens.accessToken,
        refreshToken: tokens.refreshToken,
        query: query,
      );
      if (!mounted) return;
      setState(() {
        _messageHits = hits;
      });
    } catch (error) {
      _showSnack(error.toString());
    } finally {
      if (mounted) setState(() => _searchingMessages = false);
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
    final items = _filtered;
    final showMessageHits = _messageHits.isNotEmpty;
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
                    _messageHits.isNotEmpty) {
                  setState(() {
                    _messageHits = const [];
                  });
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
                  selected: _activeFilter == 'all',
                  onSelected: (_) {
                    if (_activeFilter == 'all') return;
                    setState(() => _activeFilter = 'all');
                    unawaited(_loadChats());
                  },
                ),
                SizedBox(width: context.sp(8)),
                FilterChip(
                  label: const Text('Pinned'),
                  selected: _activeFilter == 'pinned',
                  onSelected: (_) {
                    if (_activeFilter == 'pinned') return;
                    setState(() => _activeFilter = 'pinned');
                    unawaited(_loadChats());
                  },
                ),
                SizedBox(width: context.sp(8)),
                FilterChip(
                  label: const Text('Archived'),
                  selected: _activeFilter == 'archived',
                  onSelected: (_) {
                    if (_activeFilter == 'archived') return;
                    setState(() => _activeFilter = 'archived');
                    unawaited(_loadChats());
                  },
                ),
                const Spacer(),
                IconButton(
                  tooltip: 'Search in messages',
                  onPressed: _searchingMessages ? null : _searchInMessages,
                  icon: _searchingMessages
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
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : RefreshIndicator(
                      onRefresh: _loadChats,
                      child: showMessageHits
                          ? ListView.separated(
                              itemCount: _messageHits.length,
                              separatorBuilder: (_, index) =>
                                  SizedBox(height: context.sp(6)),
                              itemBuilder: (context, index) {
                                final hit = _messageHits[index];
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

class ChatScreen extends StatefulWidget {
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
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _messageController = TextEditingController();
  final _scrollController = ScrollController();

  bool _loading = true;
  bool _sending = false;
  List<MessageItem> _messages = const [];
  RealtimeMeSocket? _realtime;
  Timer? _typingPauseTimer;
  bool _typingSent = false;
  bool _socketConnected = false;
  final Set<int> _typingUserIds = <int>{};

  @override
  void initState() {
    super.initState();
    unawaited(_loadMessages());
    _startRealtime();
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

  Future<void> _loadMessages() async {
    final tokens = widget.getTokens();
    if (tokens == null) return;
    if (mounted) setState(() => _loading = true);
    try {
      final rows = await widget.api.listMessages(
        accessToken: tokens.accessToken,
        refreshToken: tokens.refreshToken,
        chatId: widget.chat.id,
      );
      rows.sort((a, b) => a.createdAt.compareTo(b.createdAt));
      if (!mounted) return;
      setState(() {
        _messages = rows;
      });
      _scrollToBottom();
      _ackUnreadMessages();
    } catch (error) {
      _showSnack(error.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
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
      final hasExisting = _messages.any((row) => row.id == item.id);
      if (hasExisting) return;
      setState(() {
        _messages = [..._messages, item]
          ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
      });
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
      setState(() {
        _messages = _messages
            .map((row) => row.id == item.id ? item : row)
            .toList();
      });
      return;
    }

    if (type == 'message_deleted') {
      final chatId = map['chat_id'];
      final messageId = map['message_id'];
      if (chatId is! int || messageId is! int) return;
      if (chatId != widget.chat.id) return;
      setState(() {
        _messages = _messages.where((row) => row.id != messageId).toList();
      });
      return;
    }

    if (type == 'message_status') {
      final chatId = map['chat_id'];
      final messageId = map['message_id'];
      final senderStatus = map['sender_status']?.toString();
      if (chatId is! int || messageId is! int || senderStatus == null) return;
      if (chatId != widget.chat.id) return;
      setState(() {
        _messages = _messages
            .map(
              (row) => row.id == messageId
                  ? MessageItem(
                      id: row.id,
                      chatId: row.chatId,
                      senderId: row.senderId,
                      content: row.content,
                      createdAt: row.createdAt,
                      status: senderStatus,
                      editedAt: row.editedAt,
                    )
                  : row,
            )
            .toList();
      });
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
    final tokens = widget.getTokens();
    if (tokens == null) return;

    setState(() => _sending = true);
    try {
      final sent = await widget.api.sendMessage(
        accessToken: tokens.accessToken,
        refreshToken: tokens.refreshToken,
        chatId: widget.chat.id,
        content: text,
      );
      _messageController.clear();
      _notifyTypingStopped();
      final hasExisting = _messages.any((row) => row.id == sent.id);
      if (!hasExisting) {
        setState(() {
          _messages = [..._messages, sent]
            ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
        });
      }
      _scrollToBottom();
    } catch (error) {
      _showSnack(error.toString());
    } finally {
      if (mounted) setState(() => _sending = false);
    }
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
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : ListView.builder(
                    controller: _scrollController,
                    padding: EdgeInsets.symmetric(
                      horizontal: context.sp(12),
                      vertical: context.sp(10),
                    ),
                    itemCount: _messages.length,
                    itemBuilder: (context, index) {
                      final message = _messages[index];
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
                        _messageController.text.trim().isNotEmpty && !_sending
                        ? _sendMessage
                        : null,
                    child: _sending
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

class ContactsTab extends StatefulWidget {
  final AstraApi api;
  final AuthTokens? Function() getTokens;
  final AppUser me;

  const ContactsTab({
    super.key,
    required this.api,
    required this.getTokens,
    required this.me,
  });

  @override
  State<ContactsTab> createState() => _ContactsTabState();
}

class _ContactsTabState extends State<ContactsTab> {
  final _searchController = TextEditingController();
  bool _loading = false;
  List<AppUser> _results = const [];

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final query = _searchController.text.trim();
    final tokens = widget.getTokens();
    if (tokens == null || query.length < 2) return;

    setState(() => _loading = true);
    try {
      final users = await widget.api.searchUsers(
        accessToken: tokens.accessToken,
        refreshToken: tokens.refreshToken,
        query: query,
      );
      if (!mounted) return;
      setState(() {
        _results = users.where((user) => user.id != widget.me.id).toList();
      });
    } catch (error) {
      _showSnack(error.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _openDialogAndCreate() async {
    final queryController = TextEditingController();
    final query = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Find user'),
          content: TextField(
            controller: queryController,
            autofocus: true,
            decoration: const InputDecoration(hintText: 'Phone or username'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.pop(context, queryController.text.trim()),
              child: const Text('Open chat'),
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
    } catch (error) {
      _showSnack(error.toString());
    }
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Contacts'),
        actions: [
          IconButton(
            onPressed: _openDialogAndCreate,
            icon: const Icon(Icons.person_add_alt_1_rounded),
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
                prefixIcon: Icon(Icons.search_rounded),
                hintText: 'Search by phone / username / name',
              ),
              onSubmitted: (_) => _search(),
              onChanged: (_) => setState(() {}),
            ),
            SizedBox(height: context.sp(10)),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed:
                    _searchController.text.trim().length >= 2 && !_loading
                    ? _search
                    : null,
                child: _loading
                    ? SizedBox(
                        width: context.sp(16),
                        height: context.sp(16),
                        child: const CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Search'),
              ),
            ),
            SizedBox(height: context.sp(8)),
            Expanded(
              child: _results.isEmpty
                  ? const Center(child: Text('No results'))
                  : ListView.separated(
                      itemCount: _results.length,
                      separatorBuilder: (_, index) =>
                          SizedBox(height: context.sp(6)),
                      itemBuilder: (context, index) {
                        final user = _results[index];
                        return Card(
                          child: ListTile(
                            leading: CircleAvatar(
                              child: Text(
                                user.displayName.characters.first.toUpperCase(),
                              ),
                            ),
                            title: Text(user.displayName),
                            subtitle: Text(
                              '@${user.username}${user.phone == null ? '' : '  ${user.phone}'}',
                            ),
                            onTap: () async {
                              final tokens = widget.getTokens();
                              if (tokens == null) return;
                              try {
                                final chat = await widget.api.openPrivateChat(
                                  accessToken: tokens.accessToken,
                                  refreshToken: tokens.refreshToken,
                                  query: user.username,
                                );
                                if (!context.mounted) return;
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
                              } catch (error) {
                                _showSnack(error.toString());
                              }
                            },
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class SettingsTab extends StatefulWidget {
  final AstraApi api;
  final String appVersion;
  final String updateChannel;
  final Future<void> Function(String channel) onUpdateChannelChanged;
  final Future<void> Function() onLogout;

  const SettingsTab({
    super.key,
    required this.api,
    required this.appVersion,
    required this.updateChannel,
    required this.onUpdateChannelChanged,
    required this.onLogout,
  });

  @override
  State<SettingsTab> createState() => _SettingsTabState();
}

class _SettingsTabState extends State<SettingsTab> {
  bool _checkingUpdate = false;
  ReleaseInfo? _latest;

  Future<void> _checkUpdates() async {
    if (_checkingUpdate) return;
    setState(() => _checkingUpdate = true);
    try {
      final release = await widget.api.latestRelease(
        platform: runtimePlatformKey(),
        channel: widget.updateChannel,
      );
      if (!mounted) return;
      setState(() => _latest = release);
      if (release == null) {
        _showSnack('No release found for ${runtimePlatformKey()}');
        return;
      }
      if (_isVersionNewer(release.latestVersion, widget.appVersion)) {
        _showSnack('Update available: ${release.latestVersion}');
      } else {
        _showSnack('You are on latest version');
      }
    } catch (error) {
      _showSnack(error.toString());
    } finally {
      if (mounted) setState(() => _checkingUpdate = false);
    }
  }

  Future<void> _openDownload() async {
    final link = _latest?.downloadUrl;
    if (link == null || link.isEmpty) return;
    final uri = Uri.parse(link);
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && mounted) {
      _showSnack('Cannot open download link');
    }
  }

  bool _isVersionNewer(String candidate, String current) {
    final a = _normalizeVersion(candidate);
    final b = _normalizeVersion(current);
    for (var i = 0; i < a.length; i++) {
      if (a[i] > b[i]) return true;
      if (a[i] < b[i]) return false;
    }
    return false;
  }

  List<int> _normalizeVersion(String raw) {
    final split = raw.split('+');
    final core = split.first;
    final build = split.length > 1 ? int.tryParse(split[1]) ?? 0 : 0;
    final parts = core
        .split('.')
        .map((part) => int.tryParse(part) ?? 0)
        .toList();
    while (parts.length < 3) {
      parts.add(0);
    }
    return [parts[0], parts[1], parts[2], build];
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final hasUpdate =
        _latest != null &&
        _isVersionNewer(_latest!.latestVersion, widget.appVersion);
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: EdgeInsets.all(context.sp(12)),
        children: [
          Card(
            child: Padding(
              padding: EdgeInsets.all(context.sp(14)),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Updates',
                    style: TextStyle(
                      fontSize: context.sp(18),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  SizedBox(height: context.sp(10)),
                  Text('Current version: ${widget.appVersion}'),
                  SizedBox(height: context.sp(10)),
                  DropdownButtonFormField<String>(
                    initialValue: widget.updateChannel,
                    items: const [
                      DropdownMenuItem(value: 'stable', child: Text('stable')),
                      DropdownMenuItem(value: 'beta', child: Text('beta')),
                    ],
                    onChanged: (value) {
                      if (value == null) return;
                      widget.onUpdateChannelChanged(value);
                      setState(() {});
                    },
                    decoration: const InputDecoration(labelText: 'Channel'),
                  ),
                  SizedBox(height: context.sp(10)),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton(
                          onPressed: _checkingUpdate ? null : _checkUpdates,
                          child: _checkingUpdate
                              ? SizedBox(
                                  width: context.sp(16),
                                  height: context.sp(16),
                                  child: const CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Text('Check updates'),
                        ),
                      ),
                    ],
                  ),
                  if (_latest != null) ...[
                    SizedBox(height: context.sp(10)),
                    Text('Latest: ${_latest!.latestVersion}'),
                    if (_latest!.notes.trim().isNotEmpty)
                      Text('Notes: ${_latest!.notes}'),
                    SizedBox(height: context.sp(8)),
                    OutlinedButton(
                      onPressed: hasUpdate ? _openDownload : null,
                      child: const Text('Download update'),
                    ),
                  ],
                ],
              ),
            ),
          ),
          SizedBox(height: context.sp(10)),
          Card(
            child: ListTile(
              leading: const Icon(Icons.logout_rounded),
              title: const Text('Log out'),
              onTap: widget.onLogout,
            ),
          ),
        ],
      ),
    );
  }
}

class ProfileTab extends StatefulWidget {
  final AstraApi api;
  final AuthTokens? Function() getTokens;
  final AppUser me;
  final Future<void> Function(AppUser user) onUserUpdated;

  const ProfileTab({
    super.key,
    required this.api,
    required this.getTokens,
    required this.me,
    required this.onUserUpdated,
  });

  @override
  State<ProfileTab> createState() => _ProfileTabState();
}

class _ProfileTabState extends State<ProfileTab> {
  late TextEditingController _usernameController;
  late TextEditingController _firstNameController;
  late TextEditingController _lastNameController;
  late TextEditingController _bioController;

  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _usernameController = TextEditingController(text: widget.me.username);
    _firstNameController = TextEditingController(text: widget.me.firstName);
    _lastNameController = TextEditingController(text: widget.me.lastName);
    _bioController = TextEditingController(text: widget.me.bio);
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _firstNameController.dispose();
    _lastNameController.dispose();
    _bioController.dispose();
    super.dispose();
  }

  Future<void> _saveProfile() async {
    if (_saving) return;
    final tokens = widget.getTokens();
    if (tokens == null) return;

    setState(() => _saving = true);
    try {
      final updated = await widget.api.updateMe(
        accessToken: tokens.accessToken,
        refreshToken: tokens.refreshToken,
        username: _usernameController.text.trim(),
        firstName: _firstNameController.text.trim(),
        lastName: _lastNameController.text.trim(),
        bio: _bioController.text.trim(),
      );
      await widget.onUserUpdated(updated);
      if (!mounted) return;
      _showSnack('Profile updated');
    } catch (error) {
      _showSnack(error.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Profile')),
      body: ListView(
        padding: EdgeInsets.all(context.sp(12)),
        children: [
          Card(
            child: Padding(
              padding: EdgeInsets.all(context.sp(14)),
              child: Column(
                children: [
                  CircleAvatar(
                    radius: context.sp(34),
                    child: Text(
                      widget.me.displayName.characters.first.toUpperCase(),
                      style: TextStyle(
                        fontSize: context.sp(24),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  SizedBox(height: context.sp(10)),
                  Text(
                    widget.me.displayName,
                    style: TextStyle(
                      fontSize: context.sp(22),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (widget.me.phone != null)
                    Text(
                      widget.me.phone!,
                      style: TextStyle(
                        fontSize: context.sp(14),
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
          ),
          SizedBox(height: context.sp(10)),
          TextField(
            controller: _usernameController,
            decoration: const InputDecoration(labelText: 'Username'),
            onChanged: (_) => setState(() {}),
          ),
          SizedBox(height: context.sp(10)),
          TextField(
            controller: _firstNameController,
            decoration: const InputDecoration(labelText: 'First name'),
            onChanged: (_) => setState(() {}),
          ),
          SizedBox(height: context.sp(10)),
          TextField(
            controller: _lastNameController,
            decoration: const InputDecoration(labelText: 'Last name'),
            onChanged: (_) => setState(() {}),
          ),
          SizedBox(height: context.sp(10)),
          TextField(
            controller: _bioController,
            minLines: 2,
            maxLines: 4,
            decoration: const InputDecoration(labelText: 'Bio'),
            onChanged: (_) => setState(() {}),
          ),
          SizedBox(height: context.sp(14)),
          FilledButton(
            onPressed: _saving ? null : _saveProfile,
            child: _saving
                ? SizedBox(
                    width: context.sp(16),
                    height: context.sp(16),
                    child: const CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Save'),
          ),
        ],
      ),
    );
  }
}

