import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

void main() {
  runApp(const AstraLinkApp());
}

String inferDefaultBaseUrl() {
  if (kIsWeb) {
    return 'http://127.0.0.1:8000';
  }
  if (defaultTargetPlatform == TargetPlatform.android) {
    return 'http://10.0.2.2:8000';
  }
  return 'http://127.0.0.1:8000';
}

String runtimePlatformKey() {
  if (kIsWeb) return 'web';
  switch (defaultTargetPlatform) {
    case TargetPlatform.android:
      return 'android';
    case TargetPlatform.windows:
      return 'windows';
    default:
      return 'web';
  }
}

List<int> _normalizeVersion(String version) {
  final split = version.split('+');
  final core = split.first;
  final build = split.length > 1 ? int.tryParse(split[1]) ?? 0 : 0;
  final parts = core.split('.').map((e) => int.tryParse(e) ?? 0).toList();
  while (parts.length < 3) {
    parts.add(0);
  }
  return [...parts.take(3), build];
}

bool isVersionNewer(String candidate, String current) {
  final c1 = _normalizeVersion(candidate);
  final c2 = _normalizeVersion(current);
  for (var i = 0; i < c1.length; i++) {
    if (c1[i] > c2[i]) return true;
    if (c1[i] < c2[i]) return false;
  }
  return false;
}

class AstraLinkApp extends StatefulWidget {
  const AstraLinkApp({super.key});

  @override
  State<AstraLinkApp> createState() => _AstraLinkAppState();
}

class _AstraLinkAppState extends State<AstraLinkApp> {
  static const _tokenKey = 'astralink_token';
  static const _baseUrlKey = 'astralink_base_url';

  bool _loading = true;
  String? _token;
  String _baseUrl = inferDefaultBaseUrl();

  @override
  void initState() {
    super.initState();
    _loadSession();
  }

  Future<void> _loadSession() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _token = prefs.getString(_tokenKey);
      _baseUrl = prefs.getString(_baseUrlKey) ?? inferDefaultBaseUrl();
      _loading = false;
    });
  }

  Future<void> _saveSession({required String baseUrl, String? token}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_baseUrlKey, baseUrl);
    if (token == null) {
      await prefs.remove(_tokenKey);
    } else {
      await prefs.setString(_tokenKey, token);
    }
  }

  Future<void> _onAuthenticated(String token, String baseUrl) async {
    await _saveSession(baseUrl: baseUrl, token: token);
    setState(() {
      _token = token;
      _baseUrl = baseUrl;
    });
  }

  Future<void> _onLogout() async {
    await _saveSession(baseUrl: _baseUrl, token: null);
    setState(() {
      _token = null;
    });
  }

  Future<void> _onUpdateBaseUrl(String newBaseUrl) async {
    await _saveSession(baseUrl: newBaseUrl, token: _token);
    setState(() {
      _baseUrl = newBaseUrl;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const MaterialApp(
        home: Scaffold(body: Center(child: CircularProgressIndicator())),
      );
    }

    return MaterialApp(
      title: 'AstraLink',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFFFA5E2F)),
        useMaterial3: true,
      ),
      home: _token == null
          ? AuthScreen(
              initialBaseUrl: _baseUrl,
              onAuthenticated: _onAuthenticated,
            )
          : HomeScreen(
              token: _token!,
              baseUrl: _baseUrl,
              onLogout: _onLogout,
              onUpdateBaseUrl: _onUpdateBaseUrl,
            ),
    );
  }
}

class ApiException implements Exception {
  final String message;
  ApiException(this.message);
  @override
  String toString() => message;
}

class ApiClient {
  final String baseUrl;
  final String? token;

  ApiClient({required this.baseUrl, this.token});

  String get _safeBase => baseUrl.endsWith('/')
      ? baseUrl.substring(0, baseUrl.length - 1)
      : baseUrl;

  Map<String, String> _headers({bool withAuth = true}) {
    final headers = <String, String>{'Content-Type': 'application/json'};
    if (withAuth && token != null && token!.isNotEmpty) {
      headers['Authorization'] = 'Bearer $token';
    }
    return headers;
  }

  Future<dynamic> _request(
    String method,
    String path, {
    bool withAuth = true,
    Object? body,
  }) async {
    final uri = Uri.parse('$_safeBase$path');
    late http.Response response;

    switch (method) {
      case 'GET':
        response = await http.get(uri, headers: _headers(withAuth: withAuth));
      case 'POST':
        response = await http.post(
          uri,
          headers: _headers(withAuth: withAuth),
          body: body == null ? null : jsonEncode(body),
        );
      case 'PATCH':
        response = await http.patch(
          uri,
          headers: _headers(withAuth: withAuth),
          body: body == null ? null : jsonEncode(body),
        );
      case 'PUT':
        response = await http.put(
          uri,
          headers: _headers(withAuth: withAuth),
          body: body == null ? null : jsonEncode(body),
        );
      default:
        throw ApiException('Unsupported method: $method');
    }

    final decoded = response.body.isEmpty ? null : jsonDecode(response.body);
    if (response.statusCode >= 400) {
      if (decoded is Map<String, dynamic> && decoded['detail'] != null) {
        throw ApiException(decoded['detail'].toString());
      }
      throw ApiException('HTTP ${response.statusCode}: ${response.body}');
    }
    return decoded;
  }

  Future<Map<String, dynamic>> register(
    String username,
    String email,
    String password,
  ) async {
    final result = await _request(
      'POST',
      '/api/auth/register',
      withAuth: false,
      body: {'username': username, 'email': email, 'password': password},
    );
    return Map<String, dynamic>.from(result as Map);
  }

  Future<Map<String, dynamic>> login(String login, String password) async {
    final result = await _request(
      'POST',
      '/api/auth/login',
      withAuth: false,
      body: {'login': login, 'password': password},
    );
    return Map<String, dynamic>.from(result as Map);
  }

  Future<Map<String, dynamic>> me() async {
    final result = await _request('GET', '/api/users/me');
    return Map<String, dynamic>.from(result as Map);
  }

  Future<List<Map<String, dynamic>>> chats() async {
    final result = await _request('GET', '/api/chats');
    return (result as List)
        .map((row) => Map<String, dynamic>.from(row as Map))
        .toList();
  }

  Future<Map<String, dynamic>> createChat({
    required String title,
    required List<int> memberIds,
  }) async {
    final result = await _request(
      'POST',
      '/api/chats',
      body: {
        'title': title,
        'description': '',
        'type': memberIds.length == 1 ? 'private' : 'group',
        'member_ids': memberIds,
      },
    );
    return Map<String, dynamic>.from(result as Map);
  }

  Future<List<Map<String, dynamic>>> messages(int chatId) async {
    final result = await _request('GET', '/api/chats/$chatId/messages');
    return (result as List)
        .map((row) => Map<String, dynamic>.from(row as Map))
        .toList();
  }

  Future<Map<String, dynamic>> sendMessage(int chatId, String content) async {
    final result = await _request(
      'POST',
      '/api/chats/$chatId/messages',
      body: {'content': content},
    );
    return Map<String, dynamic>.from(result as Map);
  }

  Future<List<Map<String, dynamic>>> feed() async {
    final result = await _request('GET', '/api/social/feed');
    return (result as List)
        .map((row) => Map<String, dynamic>.from(row as Map))
        .toList();
  }

  Future<Map<String, dynamic>> createPost(
    String content,
    String visibility,
  ) async {
    final result = await _request(
      'POST',
      '/api/social/posts',
      body: {'content': content, 'visibility': visibility},
    );
    return Map<String, dynamic>.from(result as Map);
  }

  Future<Map<String, dynamic>> customization() async {
    final result = await _request('GET', '/api/customization/me');
    return Map<String, dynamic>.from(result as Map);
  }

  Future<Map<String, dynamic>> updateCustomization({
    required String theme,
    required String accentColor,
  }) async {
    final result = await _request(
      'PUT',
      '/api/customization/me',
      body: {'theme': theme, 'accent_color': accentColor},
    );
    return Map<String, dynamic>.from(result as Map);
  }

  Future<Map<String, dynamic>?> latestRelease(
    String platform, {
    String channel = 'stable',
  }) async {
    try {
      final result = await _request(
        'GET',
        '/api/releases/latest/$platform?channel=$channel',
        withAuth: false,
      );
      return Map<String, dynamic>.from(result as Map);
    } on ApiException catch (error) {
      if (error.message.contains('404')) {
        return null;
      }
      rethrow;
    }
  }
}

class AuthScreen extends StatefulWidget {
  final String initialBaseUrl;
  final Future<void> Function(String token, String baseUrl) onAuthenticated;

  const AuthScreen({
    super.key,
    required this.initialBaseUrl,
    required this.onAuthenticated,
  });

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final _baseController = TextEditingController();
  final _loginController = TextEditingController();
  final _passwordController = TextEditingController();
  final _regUserController = TextEditingController();
  final _regEmailController = TextEditingController();
  final _regPasswordController = TextEditingController();

  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _baseController.text = widget.initialBaseUrl;
  }

  @override
  void dispose() {
    _baseController.dispose();
    _loginController.dispose();
    _passwordController.dispose();
    _regUserController.dispose();
    _regEmailController.dispose();
    _regPasswordController.dispose();
    super.dispose();
  }

  Future<void> _run(
    Future<Map<String, dynamic>> Function(ApiClient client) action,
  ) async {
    setState(() => _loading = true);
    try {
      final client = ApiClient(baseUrl: _baseController.text.trim());
      final response = await action(client);
      final token = response['access_token']?.toString();
      if (token == null || token.isEmpty) {
        throw ApiException('Token not received');
      }
      await widget.onAuthenticated(token, _baseController.text.trim());
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.toString())));
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('AstraLink Sign In'),
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Login'),
              Tab(text: 'Register'),
            ],
          ),
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    TextField(
                      controller: _baseController,
                      decoration: const InputDecoration(
                        labelText: 'API Base URL',
                        helperText:
                            'Windows/Web: http://127.0.0.1:8000, Android emulator: http://10.0.2.2:8000',
                      ),
                    ),
                    const SizedBox(height: 16),
                    Expanded(
                      child: TabBarView(
                        children: [
                          ListView(
                            children: [
                              TextField(
                                controller: _loginController,
                                decoration: const InputDecoration(
                                  labelText: 'Username or email',
                                ),
                              ),
                              const SizedBox(height: 12),
                              TextField(
                                controller: _passwordController,
                                obscureText: true,
                                decoration: const InputDecoration(
                                  labelText: 'Password',
                                ),
                              ),
                              const SizedBox(height: 16),
                              FilledButton(
                                onPressed: () {
                                  _run(
                                    (client) => client.login(
                                      _loginController.text.trim(),
                                      _passwordController.text.trim(),
                                    ),
                                  );
                                },
                                child: const Text('Login'),
                              ),
                            ],
                          ),
                          ListView(
                            children: [
                              TextField(
                                controller: _regUserController,
                                decoration: const InputDecoration(
                                  labelText: 'Username',
                                ),
                              ),
                              const SizedBox(height: 12),
                              TextField(
                                controller: _regEmailController,
                                decoration: const InputDecoration(
                                  labelText: 'Email',
                                ),
                              ),
                              const SizedBox(height: 12),
                              TextField(
                                controller: _regPasswordController,
                                obscureText: true,
                                decoration: const InputDecoration(
                                  labelText: 'Password',
                                ),
                              ),
                              const SizedBox(height: 16),
                              FilledButton(
                                onPressed: () {
                                  _run(
                                    (client) => client.register(
                                      _regUserController.text.trim(),
                                      _regEmailController.text.trim(),
                                      _regPasswordController.text.trim(),
                                    ),
                                  );
                                },
                                child: const Text('Create account'),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}

class HomeScreen extends StatefulWidget {
  final String token;
  final String baseUrl;
  final Future<void> Function() onLogout;
  final Future<void> Function(String newBaseUrl) onUpdateBaseUrl;

  const HomeScreen({
    super.key,
    required this.token,
    required this.baseUrl,
    required this.onLogout,
    required this.onUpdateBaseUrl,
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late ApiClient _api;
  int _tab = 0;
  String _identity = 'Loading...';
  Map<String, dynamic>? _availableRelease;
  String? _currentVersion;
  bool _checkingUpdates = false;
  bool _dialogShown = false;

  @override
  void initState() {
    super.initState();
    _api = ApiClient(baseUrl: widget.baseUrl, token: widget.token);
    _loadIdentity();
    _checkForUpdates();
  }

  Future<void> _loadIdentity() async {
    try {
      final me = await _api.me();
      setState(() {
        _identity = '${me['username']} (#${me['id']})';
      });
    } catch (_) {
      setState(() {
        _identity = 'Unauthorized';
      });
    }
  }

  Future<void> _changeBaseUrlDialog() async {
    final controller = TextEditingController(text: widget.baseUrl);
    final value = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('API Base URL'),
          content: TextField(
            controller: controller,
            decoration: const InputDecoration(
              labelText: 'http://127.0.0.1:8000',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, controller.text.trim()),
              child: const Text('Apply'),
            ),
          ],
        );
      },
    );

    if (value == null || value.isEmpty) return;
    await widget.onUpdateBaseUrl(value);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Restart app to switch API base URL')),
    );
  }

  Future<void> _checkForUpdates() async {
    final platform = runtimePlatformKey();
    if (platform == 'web') return;

    setState(() => _checkingUpdates = true);
    try {
      final info = await PackageInfo.fromPlatform();
      final currentVersion = '${info.version}+${info.buildNumber}';
      final release = await _api.latestRelease(platform);

      setState(() {
        _currentVersion = currentVersion;
      });

      if (release == null) return;

      final latest = release['latest_version']?.toString() ?? '';
      if (!isVersionNewer(latest, currentVersion)) return;

      setState(() {
        _availableRelease = release;
      });

      if (!_dialogShown) {
        _dialogShown = true;
        if (!mounted) return;
        await _showUpdateDialog();
      }
    } catch (_) {
      // Update check should not block app usage.
    } finally {
      if (mounted) {
        setState(() => _checkingUpdates = false);
      }
    }
  }

  Future<void> _openReleaseDownload() async {
    final url = _availableRelease?['download_url']?.toString();
    if (url == null || url.isEmpty) return;
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  Future<void> _showUpdateDialog() async {
    final release = _availableRelease;
    if (release == null || !mounted) return;

    final mandatory = release['mandatory'] == true;
    await showDialog<void>(
      context: context,
      barrierDismissible: !mandatory,
      builder: (context) {
        return AlertDialog(
          title: const Text('Update available'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Current: ${_currentVersion ?? "unknown"}'),
              Text('Latest: ${release['latest_version']}'),
              const SizedBox(height: 8),
              Text(release['notes']?.toString() ?? ''),
            ],
          ),
          actions: [
            if (!mandatory)
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Later'),
              ),
            FilledButton(
              onPressed: () async {
                Navigator.pop(context);
                await _openReleaseDownload();
              },
              child: const Text('Download'),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      ChatsPage(api: _api),
      FeedPage(api: _api),
      CustomizationPage(api: _api),
    ];

    return Scaffold(
      appBar: AppBar(
        title: Text('AstraLink - $_identity'),
        actions: [
          if (_checkingUpdates)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 8),
              child: Center(
                child: SizedBox(
                  height: 18,
                  width: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            ),
          if (_availableRelease != null)
            IconButton(
              tooltip: 'Update available',
              onPressed: _showUpdateDialog,
              icon: const Icon(Icons.system_update),
            ),
          IconButton(
            tooltip: 'API URL',
            onPressed: _changeBaseUrlDialog,
            icon: const Icon(Icons.dns),
          ),
          IconButton(
            tooltip: 'Logout',
            onPressed: widget.onLogout,
            icon: const Icon(Icons.logout),
          ),
        ],
      ),
      body: pages[_tab],
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (index) => setState(() => _tab = index),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.chat_bubble_outline),
            label: 'Chats',
          ),
          NavigationDestination(icon: Icon(Icons.rss_feed), label: 'Feed'),
          NavigationDestination(icon: Icon(Icons.tune), label: 'Theme'),
        ],
      ),
    );
  }
}

class ChatsPage extends StatefulWidget {
  final ApiClient api;
  const ChatsPage({super.key, required this.api});

  @override
  State<ChatsPage> createState() => _ChatsPageState();
}

class _ChatsPageState extends State<ChatsPage> {
  final _newChatController = TextEditingController();
  final _newMembersController = TextEditingController();
  final _messageController = TextEditingController();

  List<Map<String, dynamic>> _chats = [];
  List<Map<String, dynamic>> _messages = [];
  int? _activeChatId;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _loadChats();
  }

  @override
  void dispose() {
    _newChatController.dispose();
    _newMembersController.dispose();
    _messageController.dispose();
    super.dispose();
  }

  List<int> _parseMemberIds() {
    return _newMembersController.text
        .split(',')
        .map((e) => int.tryParse(e.trim()))
        .whereType<int>()
        .toList();
  }

  Future<void> _loadChats() async {
    setState(() => _loading = true);
    try {
      final chats = await widget.api.chats();
      setState(() => _chats = chats);
      if (_activeChatId != null) {
        await _loadMessages(_activeChatId!);
      }
    } catch (error) {
      _show(error);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadMessages(int chatId) async {
    try {
      final messages = await widget.api.messages(chatId);
      setState(() {
        _activeChatId = chatId;
        _messages = messages;
      });
    } catch (error) {
      _show(error);
    }
  }

  Future<void> _createChat() async {
    final title = _newChatController.text.trim();
    if (title.isEmpty) return;
    try {
      await widget.api.createChat(title: title, memberIds: _parseMemberIds());
      _newChatController.clear();
      await _loadChats();
    } catch (error) {
      _show(error);
    }
  }

  Future<void> _sendMessage() async {
    final chatId = _activeChatId;
    final content = _messageController.text.trim();
    if (chatId == null || content.isEmpty) return;

    try {
      await widget.api.sendMessage(chatId, content);
      _messageController.clear();
      await _loadMessages(chatId);
    } catch (error) {
      _show(error);
    }
  }

  void _show(Object error) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(error.toString())));
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: 220,
                child: TextField(
                  controller: _newChatController,
                  decoration: const InputDecoration(
                    labelText: 'New chat title',
                  ),
                ),
              ),
              SizedBox(
                width: 220,
                child: TextField(
                  controller: _newMembersController,
                  decoration: const InputDecoration(
                    labelText: 'Member IDs (2,3)',
                  ),
                ),
              ),
              FilledButton(onPressed: _createChat, child: const Text('Create')),
              OutlinedButton(
                onPressed: _loadChats,
                child: const Text('Refresh'),
              ),
            ],
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 48,
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : ListView(
                    scrollDirection: Axis.horizontal,
                    children: _chats.map((chat) {
                      final id = chat['id'] as int;
                      return Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ChoiceChip(
                          label: Text('${chat['title']} (${chat['type']})'),
                          selected: _activeChatId == id,
                          onSelected: (_) => _loadMessages(id),
                        ),
                      );
                    }).toList(),
                  ),
          ),
          const SizedBox(height: 10),
          Expanded(
            child: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                border: Border.all(
                  color: Theme.of(context).colorScheme.outlineVariant,
                ),
                borderRadius: BorderRadius.circular(12),
              ),
              child: ListView.builder(
                itemCount: _messages.length,
                itemBuilder: (context, index) {
                  final msg = _messages[index];
                  return Card(
                    child: ListTile(
                      title: Text(msg['content']?.toString() ?? ''),
                      subtitle: Text('sender ${msg['sender_id']}'),
                    ),
                  );
                },
              ),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _messageController,
                  decoration: const InputDecoration(labelText: 'Message'),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(onPressed: _sendMessage, child: const Text('Send')),
            ],
          ),
        ],
      ),
    );
  }
}

class FeedPage extends StatefulWidget {
  final ApiClient api;
  const FeedPage({super.key, required this.api});

  @override
  State<FeedPage> createState() => _FeedPageState();
}

class _FeedPageState extends State<FeedPage> {
  final _postController = TextEditingController();
  String _visibility = 'public';
  List<Map<String, dynamic>> _feed = [];
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _loadFeed();
  }

  @override
  void dispose() {
    _postController.dispose();
    super.dispose();
  }

  Future<void> _loadFeed() async {
    setState(() => _loading = true);
    try {
      final feed = await widget.api.feed();
      setState(() => _feed = feed);
    } catch (error) {
      _show(error);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _createPost() async {
    final content = _postController.text.trim();
    if (content.isEmpty) return;

    try {
      await widget.api.createPost(content, _visibility);
      _postController.clear();
      await _loadFeed();
    } catch (error) {
      _show(error);
    }
  }

  void _show(Object error) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(error.toString())));
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        children: [
          TextField(
            controller: _postController,
            minLines: 2,
            maxLines: 4,
            decoration: const InputDecoration(labelText: 'New post'),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              DropdownButton<String>(
                value: _visibility,
                onChanged: (value) =>
                    setState(() => _visibility = value ?? 'public'),
                items: const [
                  DropdownMenuItem(value: 'public', child: Text('public')),
                  DropdownMenuItem(
                    value: 'followers',
                    child: Text('followers'),
                  ),
                  DropdownMenuItem(value: 'private', child: Text('private')),
                ],
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _createPost,
                child: const Text('Publish'),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: _loadFeed,
                child: const Text('Refresh'),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : ListView.builder(
                    itemCount: _feed.length,
                    itemBuilder: (context, index) {
                      final post = _feed[index];
                      return Card(
                        child: ListTile(
                          title: Text(post['content']?.toString() ?? ''),
                          subtitle: Text(
                            'author ${post['author_id']} - ${post['visibility']}',
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class CustomizationPage extends StatefulWidget {
  final ApiClient api;
  const CustomizationPage({super.key, required this.api});

  @override
  State<CustomizationPage> createState() => _CustomizationPageState();
}

class _CustomizationPageState extends State<CustomizationPage> {
  final _themeController = TextEditingController();
  final _accentController = TextEditingController();
  bool _loading = false;
  Map<String, dynamic>? _settings;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _themeController.dispose();
    _accentController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final settings = await widget.api.customization();
      _themeController.text = settings['theme']?.toString() ?? '';
      _accentController.text = settings['accent_color']?.toString() ?? '';
      setState(() => _settings = settings);
    } catch (error) {
      _show(error);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _save() async {
    setState(() => _loading = true);
    try {
      final saved = await widget.api.updateCustomization(
        theme: _themeController.text.trim(),
        accentColor: _accentController.text.trim(),
      );
      setState(() => _settings = saved);
      _show('Saved');
    } catch (error) {
      _show(error);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _show(Object message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message.toString())));
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                TextField(
                  controller: _themeController,
                  decoration: const InputDecoration(labelText: 'Theme name'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _accentController,
                  decoration: const InputDecoration(
                    labelText: 'Accent color (#FF4D00)',
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    FilledButton(onPressed: _save, child: const Text('Save')),
                    const SizedBox(width: 8),
                    OutlinedButton(
                      onPressed: _load,
                      child: const Text('Reload'),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                SelectableText(
                  const JsonEncoder.withIndent('  ').convert(_settings ?? {}),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
    );
  }
}
