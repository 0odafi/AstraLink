import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

const String _productionBaseUrl = String.fromEnvironment(
  'ASTRALINK_API_BASE_URL',
  defaultValue: 'https://volds.ru',
);

const Set<String> _legacyLocalBaseUrls = {
  'http://127.0.0.1:8000',
  'http://localhost:8000',
  'http://10.0.2.2:8000',
  'https://127.0.0.1:8000',
};

const String kPrefUpdateChannel = 'astralink_update_channel';
const String kPrefAutoUpdateCheck = 'astralink_auto_update_check';
const String kPrefUpdateNotifications = 'astralink_update_notifications';
const String kPrefSkippedVersion = 'astralink_skipped_update_version';

void main() {
  runApp(const AstraLinkApp());
}

String normalizeBaseUrl(String input) {
  final trimmed = input.trim();
  if (trimmed.isEmpty) return _productionBaseUrl;
  return trimmed.endsWith('/') ? trimmed.substring(0, trimmed.length - 1) : trimmed;
}

String inferDefaultBaseUrl() => normalizeBaseUrl(_productionBaseUrl);

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

int? _asInt(dynamic value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value);
  return null;
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

class SessionTokens {
  final String accessToken;
  final String refreshToken;

  const SessionTokens({
    required this.accessToken,
    required this.refreshToken,
  });
}

ThemeData _buildTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: const Color(0xFF2F6D84),
    brightness: Brightness.light,
  ).copyWith(
    primary: const Color(0xFF2F6D84),
    secondary: const Color(0xFF5C8798),
    tertiary: const Color(0xFF6F8B7F),
    surface: const Color(0xFFF2F6F8),
    outline: const Color(0xFF9FB0B8),
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: const Color(0xFFEDF3F6),
    appBarTheme: AppBarTheme(
      backgroundColor: Colors.transparent,
      foregroundColor: scheme.onSurface,
      elevation: 0,
      centerTitle: false,
      surfaceTintColor: Colors.transparent,
    ),
    cardTheme: CardThemeData(
      color: Colors.white,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: const BorderSide(color: Color(0xFFE2EAED)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: const Color(0xFFF7FAFB),
      labelStyle: TextStyle(color: scheme.onSurfaceVariant),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: scheme.outline.withOpacity(0.35)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: scheme.outline.withOpacity(0.3)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: scheme.primary, width: 1.4),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: scheme.primary,
        foregroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: scheme.primary,
        side: BorderSide(color: scheme.primary.withOpacity(0.3)),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: Colors.white,
      indicatorColor: scheme.primary.withOpacity(0.16),
      labelTextStyle: MaterialStateProperty.resolveWith((states) {
        final selected = states.contains(MaterialState.selected);
        return TextStyle(
          fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
          color: selected ? scheme.primary : scheme.onSurfaceVariant,
        );
      }),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
  );
}

class AstraLinkApp extends StatefulWidget {
  const AstraLinkApp({super.key});

  @override
  State<AstraLinkApp> createState() => _AstraLinkAppState();
}

class _AstraLinkAppState extends State<AstraLinkApp> {
  static const _accessTokenKey = 'astralink_token';
  static const _refreshTokenKey = 'astralink_refresh_token';
  static const _baseUrlKey = 'astralink_base_url';

  bool _loading = true;
  String? _accessToken;
  String? _refreshToken;
  String _baseUrl = inferDefaultBaseUrl();

  @override
  void initState() {
    super.initState();
    _loadSession();
  }

  Future<void> _loadSession() async {
    final prefs = await SharedPreferences.getInstance();
    final storedRaw = prefs.getString(_baseUrlKey);
    final stored = normalizeBaseUrl(storedRaw ?? '');
    final migratedBase = storedRaw == null || _legacyLocalBaseUrls.contains(stored)
        ? inferDefaultBaseUrl()
        : stored;

    if (storedRaw == null || stored != migratedBase) {
      await prefs.setString(_baseUrlKey, migratedBase);
    }

    setState(() {
      _accessToken = prefs.getString(_accessTokenKey);
      _refreshToken = prefs.getString(_refreshTokenKey);
      _baseUrl = migratedBase;
      _loading = false;
    });
  }

  Future<void> _saveSession({
    required String baseUrl,
    String? accessToken,
    String? refreshToken,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_baseUrlKey, normalizeBaseUrl(baseUrl));
    if (accessToken == null) {
      await prefs.remove(_accessTokenKey);
      await prefs.remove(_refreshTokenKey);
    } else {
      await prefs.setString(_accessTokenKey, accessToken);
      if (refreshToken != null && refreshToken.isNotEmpty) {
        await prefs.setString(_refreshTokenKey, refreshToken);
      }
    }
  }

  Future<void> _onAuthenticated(SessionTokens tokens) async {
    await _saveSession(
      baseUrl: _baseUrl,
      accessToken: tokens.accessToken,
      refreshToken: tokens.refreshToken,
    );
    setState(() {
      _accessToken = tokens.accessToken;
      _refreshToken = tokens.refreshToken;
    });
  }

  Future<void> _onSessionUpdated(SessionTokens tokens) async {
    await _saveSession(
      baseUrl: _baseUrl,
      accessToken: tokens.accessToken,
      refreshToken: tokens.refreshToken,
    );
    if (!mounted) return;
    setState(() {
      _accessToken = tokens.accessToken;
      _refreshToken = tokens.refreshToken;
    });
  }

  Future<void> _onLogout() async {
    await _saveSession(baseUrl: _baseUrl, accessToken: null, refreshToken: null);
    setState(() {
      _accessToken = null;
      _refreshToken = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return MaterialApp(
        theme: _buildTheme(),
        home: const Scaffold(body: Center(child: CircularProgressIndicator())),
      );
    }

    return MaterialApp(
      title: 'AstraLink',
      debugShowCheckedModeBanner: false,
      theme: _buildTheme(),
      home: _accessToken == null
          ? AuthScreen(
              baseUrl: _baseUrl,
              onAuthenticated: _onAuthenticated,
            )
          : HomeScreen(
              token: _accessToken!,
              refreshToken: _refreshToken,
              baseUrl: _baseUrl,
              onSessionUpdated: _onSessionUpdated,
              onLogout: _onLogout,
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
  String? accessToken;
  String? refreshToken;
  final Future<void> Function(SessionTokens tokens)? onSessionUpdated;
  final Future<void> Function()? onUnauthorized;

  ApiClient({
    required this.baseUrl,
    this.accessToken,
    this.refreshToken,
    this.onSessionUpdated,
    this.onUnauthorized,
  });

  String get _safeBase => baseUrl.endsWith('/')
      ? baseUrl.substring(0, baseUrl.length - 1)
      : baseUrl;

  Map<String, String> _headers({bool withAuth = true}) {
    final headers = <String, String>{'Content-Type': 'application/json'};
    if (withAuth && accessToken != null && accessToken!.isNotEmpty) {
      headers['Authorization'] = 'Bearer $accessToken';
    }
    return headers;
  }

  Future<http.Response> _sendHttp(
    String method,
    Uri uri, {
    required bool withAuth,
    Object? body,
  }) async {
    switch (method) {
      case 'GET':
        return http
            .get(uri, headers: _headers(withAuth: withAuth))
            .timeout(const Duration(seconds: 25));
      case 'POST':
        return http
            .post(
              uri,
              headers: _headers(withAuth: withAuth),
              body: body == null ? null : jsonEncode(body),
            )
            .timeout(const Duration(seconds: 25));
      case 'PATCH':
        return http
            .patch(
              uri,
              headers: _headers(withAuth: withAuth),
              body: body == null ? null : jsonEncode(body),
            )
            .timeout(const Duration(seconds: 25));
      case 'PUT':
        return http
            .put(
              uri,
              headers: _headers(withAuth: withAuth),
              body: body == null ? null : jsonEncode(body),
            )
            .timeout(const Duration(seconds: 25));
      case 'DELETE':
        return http
            .delete(
              uri,
              headers: _headers(withAuth: withAuth),
              body: body == null ? null : jsonEncode(body),
            )
            .timeout(const Duration(seconds: 25));
      default:
        throw ApiException('Unsupported method: $method');
    }
  }

  dynamic _decodeResponse(http.Response response) {
    if (response.body.isEmpty) return null;
    try {
      return jsonDecode(response.body);
    } catch (_) {
      throw ApiException('Invalid JSON response from server');
    }
  }

  Future<bool> _tryRefreshAccessToken() async {
    final token = refreshToken;
    if (token == null || token.isEmpty) return false;

    try {
      final result = await _request(
        'POST',
        '/api/auth/refresh',
        withAuth: false,
        allowRefresh: false,
        body: {'refresh_token': token},
      );
      final payload = Map<String, dynamic>.from(result as Map);
      final newAccess = payload['access_token']?.toString();
      final newRefresh = payload['refresh_token']?.toString();
      if (newAccess == null || newAccess.isEmpty || newRefresh == null || newRefresh.isEmpty) {
        return false;
      }

      accessToken = newAccess;
      refreshToken = newRefresh;
      if (onSessionUpdated != null) {
        await onSessionUpdated!(
          SessionTokens(accessToken: newAccess, refreshToken: newRefresh),
        );
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<dynamic> _request(
    String method,
    String path, {
    bool withAuth = true,
    bool allowRefresh = true,
    Object? body,
  }) async {
    final uri = Uri.parse('$_safeBase$path');
    late http.Response response;

    try {
      response = await _sendHttp(method, uri, withAuth: withAuth, body: body);
    } on TimeoutException {
      throw ApiException('Connection timeout. Check internet or server status.');
    } catch (_) {
      throw ApiException('Network error. Check internet or server DNS.');
    }

    if (response.statusCode == 401 && withAuth && allowRefresh) {
      final refreshed = await _tryRefreshAccessToken();
      if (refreshed) {
        response = await _sendHttp(method, uri, withAuth: withAuth, body: body);
      } else if (onUnauthorized != null) {
        await onUnauthorized!();
      }
    }

    final decoded = _decodeResponse(response);

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

  Future<void> logoutRemote() async {
    final token = refreshToken;
    if (token == null || token.isEmpty) return;
    try {
      await _request(
        'POST',
        '/api/auth/logout',
        withAuth: false,
        allowRefresh: false,
        body: {'refresh_token': token},
      );
    } catch (_) {
      // Ignore logout transport failures on client side.
    }
  }

  Future<Map<String, dynamic>> me() async {
    final result = await _request('GET', '/api/users/me');
    return Map<String, dynamic>.from(result as Map);
  }

  Future<Map<String, dynamic>> updateProfile({
    String? bio,
    String? avatarUrl,
    String? uid,
  }) async {
    final payload = <String, dynamic>{};
    if (bio != null) payload['bio'] = bio;
    if (avatarUrl != null) payload['avatar_url'] = avatarUrl;
    if (uid != null) payload['uid'] = uid;
    final result = await _request('PATCH', '/api/users/me', body: payload);
    return Map<String, dynamic>.from(result as Map);
  }

  Future<List<Map<String, dynamic>>> searchUsers(String query) async {
    final encoded = Uri.encodeQueryComponent(query);
    final result = await _request('GET', '/api/users/search?q=$encoded');
    return (result as List)
        .map((row) => Map<String, dynamic>.from(row as Map))
        .toList();
  }

  Future<Map<String, dynamic>> userByUid(String uid) async {
    final encoded = Uri.encodeComponent(uid);
    final result = await _request('GET', '/api/users/by-uid/$encoded');
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
  final String baseUrl;
  final Future<void> Function(SessionTokens tokens) onAuthenticated;

  const AuthScreen({
    super.key,
    required this.baseUrl,
    required this.onAuthenticated,
  });

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final _loginController = TextEditingController();
  final _passwordController = TextEditingController();
  final _regUserController = TextEditingController();
  final _regEmailController = TextEditingController();
  final _regPasswordController = TextEditingController();

  bool _loading = false;

  @override
  void dispose() {
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
      final client = ApiClient(baseUrl: widget.baseUrl);
      final response = await action(client);
      final accessToken = response['access_token']?.toString();
      final refreshToken = response['refresh_token']?.toString();
      if (accessToken == null || accessToken.isEmpty) {
        throw ApiException('Access token not received');
      }
      if (refreshToken == null || refreshToken.isEmpty) {
        throw ApiException('Refresh token not received');
      }
      await widget.onAuthenticated(
        SessionTokens(accessToken: accessToken, refreshToken: refreshToken),
      );
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
    final theme = Theme.of(context);

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        body: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [Color(0xFFE7EEF2), Color(0xFFF5F8FA)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
          child: SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 540),
                  child: Card(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Container(
                                width: 48,
                                height: 48,
                                decoration: BoxDecoration(
                                  color: theme.colorScheme.primary.withOpacity(0.14),
                                  borderRadius: BorderRadius.circular(14),
                                ),
                                child: Icon(
                                  Icons.bolt_rounded,
                                  color: theme.colorScheme.primary,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'AstraLink',
                                      style: theme.textTheme.headlineSmall?.copyWith(
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                    Text(
                                      'Private messaging platform',
                                      style: theme.textTheme.bodyMedium?.copyWith(
                                        color: theme.colorScheme.onSurfaceVariant,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 18),
                          const TabBar(
                            tabs: [
                              Tab(text: 'Login'),
                              Tab(text: 'Register'),
                            ],
                          ),
                          const SizedBox(height: 14),
                          SizedBox(
                            height: 320,
                            child: _loading
                                ? const Center(child: CircularProgressIndicator())
                                : TabBarView(
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
                                          FilledButton.icon(
                                            onPressed: () {
                                              _run(
                                                (client) => client.login(
                                                  _loginController.text.trim(),
                                                  _passwordController.text.trim(),
                                                ),
                                              );
                                            },
                                            icon: const Icon(Icons.login),
                                            label: const Text('Login'),
                                          ),
                                        ],
                                      ),
                                      ListView(
                                        children: [
                                          TextField(
                                            controller: _regUserController,
                                            decoration: const InputDecoration(labelText: 'Username'),
                                          ),
                                          const SizedBox(height: 12),
                                          TextField(
                                            controller: _regEmailController,
                                            keyboardType: TextInputType.emailAddress,
                                            decoration: const InputDecoration(labelText: 'Email'),
                                          ),
                                          const SizedBox(height: 12),
                                          TextField(
                                            controller: _regPasswordController,
                                            obscureText: true,
                                            decoration: const InputDecoration(labelText: 'Password'),
                                          ),
                                          const SizedBox(height: 16),
                                          FilledButton.icon(
                                            onPressed: () {
                                              _run(
                                                (client) => client.register(
                                                  _regUserController.text.trim(),
                                                  _regEmailController.text.trim(),
                                                  _regPasswordController.text.trim(),
                                                ),
                                              );
                                            },
                                            icon: const Icon(Icons.person_add_alt_1),
                                            label: const Text('Create account'),
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
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
class HomeScreen extends StatefulWidget {
  final String token;
  final String? refreshToken;
  final String baseUrl;
  final Future<void> Function(SessionTokens tokens) onSessionUpdated;
  final Future<void> Function() onLogout;

  const HomeScreen({
    super.key,
    required this.token,
    required this.refreshToken,
    required this.baseUrl,
    required this.onSessionUpdated,
    required this.onLogout,
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late ApiClient _api;
  int _tab = 0;
  String _identity = 'Connecting...';
  Map<String, dynamic>? _availableRelease;
  String? _currentVersion;
  bool _checkingUpdates = false;
  bool _dialogShown = false;

  @override
  void initState() {
    super.initState();
    _api = ApiClient(
      baseUrl: widget.baseUrl,
      accessToken: widget.token,
      refreshToken: widget.refreshToken,
      onSessionUpdated: widget.onSessionUpdated,
      onUnauthorized: widget.onLogout,
    );
    _loadIdentity();
    _checkForUpdates();
  }

  Future<void> _loadIdentity() async {
    try {
      final me = await _api.me();
      final id = _asInt(me['id']);
      final username = me['username']?.toString() ?? 'User';
      final uid = me['uid']?.toString();
      final uidPart = uid == null || uid.isEmpty ? '' : ' @${uid.toLowerCase()}';
      setState(() {
        _identity = id == null ? '$username$uidPart' : '$username$uidPart (#$id)';
      });
    } catch (_) {
      setState(() {
        _identity = 'Unauthorized';
      });
    }
  }

  Future<void> _checkForUpdates({bool force = false}) async {
    final platform = runtimePlatformKey();
    if (platform == 'web') return;
    final prefs = await SharedPreferences.getInstance();
    final autoCheck = prefs.getBool(kPrefAutoUpdateCheck) ?? true;
    if (!force && !autoCheck) return;

    final updateChannel = prefs.getString(kPrefUpdateChannel) ?? 'stable';
    final notificationsEnabled = prefs.getBool(kPrefUpdateNotifications) ?? true;

    setState(() => _checkingUpdates = true);
    try {
      final info = await PackageInfo.fromPlatform();
      final currentVersion = '${info.version}+${info.buildNumber}';
      final release = await _api.latestRelease(platform, channel: updateChannel);

      setState(() {
        _currentVersion = currentVersion;
      });

      if (release == null) {
        if (mounted) {
          setState(() => _availableRelease = null);
        }
        return;
      }

      final latest = release['latest_version']?.toString() ?? '';
      if (!isVersionNewer(latest, currentVersion)) {
        if (mounted) {
          setState(() => _availableRelease = null);
        }
        return;
      }

      final skippedVersion = prefs.getString(kPrefSkippedVersion);
      if (!force && skippedVersion != null && skippedVersion == latest) {
        return;
      }

      setState(() {
        _availableRelease = release;
      });

      final mandatory = release['mandatory'] == true;
      if (force || mandatory || notificationsEnabled) {
        if (force || !_dialogShown) {
          _dialogShown = true;
          if (!mounted) return;
          await _showUpdateDialog();
        }
      }
    } catch (_) {
      // Ignore update checks in background.
    } finally {
      if (mounted) {
        setState(() => _checkingUpdates = false);
      }
    }
  }

  Future<void> _skipUpdateVersion(String version) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(kPrefSkippedVersion, version);
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
    final latestVersion = release['latest_version']?.toString() ?? '';
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
              Text('Latest: $latestVersion'),
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
            if (!mandatory && latestVersion.isNotEmpty)
              TextButton(
                onPressed: () async {
                  await _skipUpdateVersion(latestVersion);
                  if (!context.mounted) return;
                  Navigator.pop(context);
                },
                child: const Text('Skip this version'),
              ),
            FilledButton(
              onPressed: () async {
                Navigator.pop(context);
                await _openReleaseDownload();
              },
              child: const Text('Update'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _logout() async {
    await _api.logoutRemote();
    await widget.onLogout();
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      ChatsPage(api: _api),
      CustomizationPage(api: _api),
    ];

    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('AstraLink'),
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
              icon: const Icon(Icons.system_update_alt_rounded),
            ),
          IconButton(
            tooltip: 'Check updates',
            onPressed: () => _checkForUpdates(force: true),
            icon: const Icon(Icons.refresh_rounded),
          ),
          IconButton(
            tooltip: 'Logout',
            onPressed: _logout,
            icon: const Icon(Icons.logout),
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          child: Column(
            children: [
              _SectionCard(
                child: Row(
                  children: [
                    Icon(Icons.verified_user_outlined, color: theme.colorScheme.primary),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        _identity,
                        style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: IndexedStack(
                  index: _tab,
                  children: pages,
                ),
              ),
            ],
          ),
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (index) => setState(() => _tab = index),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.chat_bubble_outline),
            selectedIcon: Icon(Icons.chat_bubble),
            label: 'Chats',
          ),
          NavigationDestination(
            icon: Icon(Icons.palette_outlined),
            selectedIcon: Icon(Icons.palette),
            label: 'Settings',
          ),
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
  final _chatSearchController = TextEditingController();
  final _uidSearchController = TextEditingController();
  final _newChatController = TextEditingController();
  final _newMembersController = TextEditingController();
  final _messageController = TextEditingController();

  List<Map<String, dynamic>> _chats = [];
  List<Map<String, dynamic>> _messages = [];
  int? _activeChatId;
  String _chatQuery = '';
  Map<String, dynamic>? _uidResult;
  bool _loading = false;
  bool _uidLookupLoading = false;

  @override
  void initState() {
    super.initState();
    _loadChats();
  }

  @override
  void dispose() {
    _chatSearchController.dispose();
    _uidSearchController.dispose();
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
      int? nextActive = _activeChatId;
      if (nextActive != null && !chats.any((chat) => _asInt(chat['id']) == nextActive)) {
        nextActive = null;
      }
      nextActive ??= chats.isNotEmpty ? _asInt(chats.first['id']) : null;

      setState(() {
        _chats = chats;
        _activeChatId = nextActive;
      });

      if (nextActive != null) {
        await _loadMessages(nextActive);
      } else {
        setState(() => _messages = []);
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
    final members = _parseMemberIds();
    if (title.isEmpty || members.isEmpty) return;
    try {
      await widget.api.createChat(title: title, memberIds: members);
      _newChatController.clear();
      _newMembersController.clear();
      await _loadChats();
    } catch (error) {
      _show(error);
    }
  }

  Future<void> _findUserByUid() async {
    final uid = _uidSearchController.text.trim();
    if (uid.isEmpty) return;

    setState(() => _uidLookupLoading = true);
    try {
      final user = await widget.api.userByUid(uid);
      setState(() => _uidResult = user);
    } catch (error) {
      setState(() => _uidResult = null);
      _show(error);
    } finally {
      if (mounted) {
        setState(() => _uidLookupLoading = false);
      }
    }
  }

  Future<void> _startPrivateFromUid() async {
    final userId = _asInt(_uidResult?['id']);
    final username = _uidResult?['username']?.toString() ?? 'Direct chat';
    if (userId == null) return;

    try {
      await widget.api.createChat(title: username, memberIds: [userId]);
      await _loadChats();
      _uidSearchController.clear();
      setState(() => _uidResult = null);
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

  List<Map<String, dynamic>> get _visibleChats {
    final query = _chatQuery.trim().toLowerCase();
    if (query.isEmpty) return _chats;
    return _chats.where((chat) {
      final title = chat['title']?.toString().toLowerCase() ?? '';
      final lastMessage = chat['last_message_preview']?.toString().toLowerCase() ?? '';
      return title.contains(query) || lastMessage.contains(query);
    }).toList();
  }

  String _formatLastTime(dynamic raw) {
    final text = raw?.toString();
    if (text == null || text.isEmpty) return '';
    final parsed = DateTime.tryParse(text);
    if (parsed == null) return '';
    final local = parsed.toLocal();
    final hh = local.hour.toString().padLeft(2, '0');
    final mm = local.minute.toString().padLeft(2, '0');
    return '$hh:$mm';
  }

  Widget _buildChatList(BuildContext context) {
    final theme = Theme.of(context);
    final chats = _visibleChats;

    if (_loading && _chats.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (chats.isEmpty) {
      return Center(
        child: Text(
          'No chats found',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }

    return ListView.builder(
      itemCount: chats.length,
      itemBuilder: (context, index) {
        final chat = chats[index];
        final chatId = _asInt(chat['id']);
        if (chatId == null) return const SizedBox.shrink();
        final selected = _activeChatId == chatId;
        final title = chat['title']?.toString() ?? 'Untitled';
        final preview = chat['last_message_preview']?.toString() ??
            chat['description']?.toString() ??
            'No messages yet';
        final unread = _asInt(chat['unread_count']) ?? 0;
        final timeText = _formatLastTime(chat['last_message_at']);
        final avatarText = title.isNotEmpty ? title[0].toUpperCase() : '?';

        return InkWell(
          onTap: () => _loadMessages(chatId),
          borderRadius: BorderRadius.circular(14),
          child: Container(
            margin: const EdgeInsets.only(bottom: 6),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            decoration: BoxDecoration(
              color: selected ? const Color(0xFFEAF4F8) : Colors.transparent,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 22,
                  backgroundColor: const Color(0xFFD7E8EE),
                  child: Text(
                    avatarText,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: const Color(0xFF2F6D84),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          if (timeText.isNotEmpty)
                            Text(
                              timeText,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        preview,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                if (unread > 0) ...[
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: const Color(0xFF2F6D84),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      unread > 99 ? '99+' : '$unread',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                        fontSize: 11,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildThread(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        Expanded(
          child: _activeChatId == null
              ? Center(
                  child: Text(
                    'Select a chat to view messages',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                )
              : _messages.isEmpty
                  ? Center(
                      child: Text(
                        'No messages yet',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    )
                  : ListView.builder(
                      itemCount: _messages.length,
                      itemBuilder: (context, index) {
                        final msg = _messages[index];
                        final content = msg['content']?.toString() ?? '';
                        final senderId = msg['sender_id']?.toString() ?? '';
                        final status = msg['status']?.toString() ?? '';
                        return Container(
                          margin: const EdgeInsets.only(bottom: 8),
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: const Color(0xFFF6FAFC),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(color: const Color(0xFFE0EBEF)),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(content),
                              const SizedBox(height: 4),
                              Text(
                                'sender $senderId${status.isNotEmpty ? ' • $status' : ''}',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _messageController,
                decoration: const InputDecoration(labelText: 'Message'),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton.icon(
              onPressed: _sendMessage,
              icon: const Icon(Icons.send_rounded),
              label: const Text('Send'),
            ),
          ],
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(4),
      child: Column(
        children: [
          _SectionCard(
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _chatSearchController,
                    onChanged: (value) => setState(() => _chatQuery = value),
                    decoration: const InputDecoration(
                      labelText: 'Search chats',
                      prefixIcon: Icon(Icons.search),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: _loadChats,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Reload'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          _SectionCard(
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SizedBox(
                  width: 220,
                  child: TextField(
                    controller: _uidSearchController,
                    decoration: const InputDecoration(labelText: 'Find by UID (@uid)'),
                  ),
                ),
                FilledButton.icon(
                  onPressed: _uidLookupLoading ? null : _findUserByUid,
                  icon: const Icon(Icons.person_search),
                  label: const Text('Find'),
                ),
                if (_uidResult != null)
                  OutlinedButton.icon(
                    onPressed: _startPrivateFromUid,
                    icon: const Icon(Icons.chat_bubble_outline),
                    label: Text('Chat with ${_uidResult!['username']}'),
                  ),
                const SizedBox(width: 12),
                SizedBox(
                  width: 220,
                  child: TextField(
                    controller: _newChatController,
                    decoration: const InputDecoration(labelText: 'Group title'),
                  ),
                ),
                SizedBox(
                  width: 220,
                  child: TextField(
                    controller: _newMembersController,
                    decoration: const InputDecoration(labelText: 'Member IDs (2,3)'),
                  ),
                ),
                FilledButton.icon(
                  onPressed: _createChat,
                  icon: const Icon(Icons.group_add_outlined),
                  label: const Text('Create group'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final wide = constraints.maxWidth >= 900;
                if (wide) {
                  return Row(
                    children: [
                      Expanded(
                        flex: 4,
                        child: _SectionCard(
                          padding: const EdgeInsets.all(8),
                          child: _buildChatList(context),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        flex: 6,
                        child: _SectionCard(
                          padding: const EdgeInsets.all(10),
                          child: _buildThread(context),
                        ),
                      ),
                    ],
                  );
                }
                return Column(
                  children: [
                    Expanded(
                      flex: 5,
                      child: _SectionCard(
                        padding: const EdgeInsets.all(8),
                        child: _buildChatList(context),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Expanded(
                      flex: 6,
                      child: _SectionCard(
                        padding: const EdgeInsets.all(10),
                        child: _buildThread(context),
                      ),
                    ),
                  ],
                );
              },
            ),
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
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(4),
      child: Column(
        children: [
          _SectionCard(
            child: Column(
              children: [
                TextField(
                  controller: _postController,
                  minLines: 2,
                  maxLines: 4,
                  decoration: const InputDecoration(labelText: 'Share an update'),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    DropdownButton<String>(
                      value: _visibility,
                      onChanged: (value) => setState(() => _visibility = value ?? 'public'),
                      items: const [
                        DropdownMenuItem(value: 'public', child: Text('public')),
                        DropdownMenuItem(value: 'followers', child: Text('followers')),
                        DropdownMenuItem(value: 'private', child: Text('private')),
                      ],
                    ),
                    const Spacer(),
                    FilledButton.icon(
                      onPressed: _createPost,
                      icon: const Icon(Icons.publish),
                      label: const Text('Publish'),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton.icon(
                      onPressed: _loadFeed,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Refresh'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Expanded(
            child: _SectionCard(
              padding: const EdgeInsets.all(10),
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _feed.isEmpty
                      ? Center(
                          child: Text(
                            'Feed is empty',
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        )
                      : ListView.builder(
                          itemCount: _feed.length,
                          itemBuilder: (context, index) {
                            final post = _feed[index];
                            return Container(
                              margin: const EdgeInsets.only(bottom: 10),
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: const Color(0xFFF6FAFC),
                                borderRadius: BorderRadius.circular(14),
                                border: Border.all(color: const Color(0xFFE0EBEF)),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(post['content']?.toString() ?? ''),
                                  const SizedBox(height: 6),
                                  Text(
                                    'author ${post['author_id']} • ${post['visibility']}',
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: theme.colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
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
  final _uidController = TextEditingController();
  final _themeController = TextEditingController();
  final _accentController = TextEditingController();
  bool _loading = false;
  Map<String, dynamic>? _settings;
  bool _autoUpdateCheck = true;
  bool _updateNotifications = true;
  String _updateChannel = 'stable';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _uidController.dispose();
    _themeController.dispose();
    _accentController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final settings = await widget.api.customization();
      final me = await widget.api.me();
      final prefs = await SharedPreferences.getInstance();
      _uidController.text = me['uid']?.toString() ?? '';
      _themeController.text = settings['theme']?.toString() ?? '';
      _accentController.text = settings['accent_color']?.toString() ?? '';
      setState(() {
        _settings = settings;
        _autoUpdateCheck = prefs.getBool(kPrefAutoUpdateCheck) ?? true;
        _updateNotifications = prefs.getBool(kPrefUpdateNotifications) ?? true;
        _updateChannel = prefs.getString(kPrefUpdateChannel) ?? 'stable';
      });
    } catch (error) {
      _show(error);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _save() async {
    setState(() => _loading = true);
    try {
      final uid = _uidController.text.trim();
      if (uid.isNotEmpty) {
        await widget.api.updateProfile(uid: uid);
      }
      final saved = await widget.api.updateCustomization(
        theme: _themeController.text.trim(),
        accentColor: _accentController.text.trim(),
      );
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(kPrefAutoUpdateCheck, _autoUpdateCheck);
      await prefs.setBool(kPrefUpdateNotifications, _updateNotifications);
      await prefs.setString(kPrefUpdateChannel, _updateChannel);
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
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(4),
      child: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                _SectionCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      TextField(
                        controller: _uidController,
                        decoration: const InputDecoration(
                          labelText: 'UID (findable ID, example: astra_link01)',
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _themeController,
                        decoration: const InputDecoration(labelText: 'Theme name'),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _accentController,
                        decoration: const InputDecoration(
                          labelText: 'Accent color (#2F6D84)',
                        ),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          FilledButton.icon(
                            onPressed: _save,
                            icon: const Icon(Icons.save_outlined),
                            label: const Text('Save'),
                          ),
                          const SizedBox(width: 8),
                          OutlinedButton.icon(
                            onPressed: _load,
                            icon: const Icon(Icons.refresh),
                            label: const Text('Reload'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                _SectionCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Updates',
                        style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 10),
                      DropdownButtonFormField<String>(
                        initialValue: _updateChannel,
                        decoration: const InputDecoration(labelText: 'Update channel'),
                        items: const [
                          DropdownMenuItem(value: 'stable', child: Text('stable')),
                          DropdownMenuItem(value: 'beta', child: Text('beta')),
                        ],
                        onChanged: (value) {
                          if (value == null) return;
                          setState(() => _updateChannel = value);
                        },
                      ),
                      const SizedBox(height: 8),
                      SwitchListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Auto-check updates on startup'),
                        value: _autoUpdateCheck,
                        onChanged: (value) => setState(() => _autoUpdateCheck = value),
                      ),
                      SwitchListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Show update notifications'),
                        value: _updateNotifications,
                        onChanged: (value) => setState(() => _updateNotifications = value),
                      ),
                      Text(
                        'To check immediately, use the refresh icon in the top bar.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                _SectionCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Current profile settings',
                        style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 8),
                      SelectableText(
                        const JsonEncoder.withIndent('  ').convert(_settings ?? {}),
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;

  const _SectionCard({
    required this.child,
    this.padding = const EdgeInsets.all(12),
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: padding,
        child: child,
      ),
    );
  }
}


