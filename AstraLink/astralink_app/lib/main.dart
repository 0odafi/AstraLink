import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

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
  return trimmed.endsWith('/')
      ? trimmed.substring(0, trimmed.length - 1)
      : trimmed;
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
  final String? refreshToken;

  const SessionTokens({required this.accessToken, required this.refreshToken});
}

ThemeData _buildTheme() {
  final scheme =
      ColorScheme.fromSeed(
        seedColor: const Color(0xFF8E3FF3),
        brightness: Brightness.dark,
      ).copyWith(
        primary: const Color(0xFFB35DFF),
        secondary: const Color(0xFF7B8BFF),
        tertiary: const Color(0xFF32D7FF),
        surface: const Color(0xFF15171E),
        surfaceContainer: const Color(0xFF1A1D26),
        outline: const Color(0xFF343947),
      );

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: const Color(0xFF0F1116),
    appBarTheme: AppBarTheme(
      backgroundColor: const Color(0xFF0F1116),
      foregroundColor: scheme.onSurface,
      elevation: 0,
      centerTitle: false,
      surfaceTintColor: Colors.transparent,
    ),
    cardTheme: CardThemeData(
      color: const Color(0xFF171A22),
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: const BorderSide(color: Color(0xFF252A36)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: const Color(0xFF1A1F2A),
      labelStyle: TextStyle(color: scheme.onSurfaceVariant),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: scheme.outline),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: scheme.outline),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: scheme.primary, width: 1.2),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: const Color(0xFFB35DFF),
        foregroundColor: const Color(0xFF12091C),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: scheme.primary,
        side: BorderSide(color: scheme.outline),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: const Color(0xFF151922),
      indicatorColor: const Color(0xFF332040),
      labelTextStyle: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return TextStyle(
          fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
          color: selected ? scheme.primary : const Color(0xFFB3BACB),
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
    final migratedBase =
        storedRaw == null || _legacyLocalBaseUrls.contains(stored)
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
      } else {
        await prefs.remove(_refreshTokenKey);
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
    await _saveSession(
      baseUrl: _baseUrl,
      accessToken: null,
      refreshToken: null,
    );
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
          ? AuthScreen(baseUrl: _baseUrl, onAuthenticated: _onAuthenticated)
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

class DraftAttachment {
  final String localId;
  final int chatId;
  final String fileName;
  final String mimeType;
  final int sizeBytes;
  Uint8List? bytes;
  double progress;
  bool uploading;
  int? mediaId;
  String? mediaUrl;
  String? error;

  DraftAttachment({
    required this.localId,
    required this.chatId,
    required this.fileName,
    required this.mimeType,
    required this.sizeBytes,
    required this.bytes,
    this.progress = 0,
    this.uploading = false,
    this.mediaId,
    this.mediaUrl,
    this.error,
  });

  bool get isUploaded => mediaId != null;
  bool get isImage => mimeType.startsWith('image/');
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

  String _friendlyFieldName(String raw) {
    switch (raw) {
      case 'login':
        return 'Login';
      case 'username':
        return 'Username';
      case 'email':
        return 'Email';
      case 'password':
        return 'Password';
      default:
        if (raw.isEmpty) return 'Field';
        return '${raw[0].toUpperCase()}${raw.substring(1)}';
    }
  }

  String _extractErrorMessage(dynamic detail) {
    if (detail is String && detail.trim().isNotEmpty) {
      return detail.trim();
    }

    if (detail is List) {
      final parts = <String>[];
      for (final item in detail) {
        if (item is Map) {
          final msg = item['msg']?.toString().trim();
          if (msg == null || msg.isEmpty) continue;
          final loc = item['loc'];
          if (loc is List && loc.isNotEmpty) {
            final field = _friendlyFieldName(loc.last.toString());
            parts.add('$field: $msg');
          } else {
            parts.add(msg);
          }
          continue;
        }
        if (item != null) {
          parts.add(item.toString());
        }
      }
      if (parts.isNotEmpty) {
        return parts.join('\n');
      }
    }

    if (detail is Map) {
      final message = detail['message']?.toString().trim();
      if (message != null && message.isNotEmpty) {
        return message;
      }
    }

    return 'Request failed. Please verify input and try again.';
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
      if (newAccess == null || newAccess.isEmpty) {
        return false;
      }
      final resolvedRefresh = newRefresh == null || newRefresh.isEmpty
          ? token
          : newRefresh;

      accessToken = newAccess;
      refreshToken = resolvedRefresh;
      if (onSessionUpdated != null) {
        await onSessionUpdated!(
          SessionTokens(accessToken: newAccess, refreshToken: resolvedRefresh),
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
      throw ApiException(
        'Connection timeout. Check internet or server status.',
      );
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
        throw ApiException(_extractErrorMessage(decoded['detail']));
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

  Future<Map<String, dynamic>> messagesCursor(
    int chatId, {
    int limit = 40,
    int? beforeId,
  }) async {
    final query = <String>['limit=$limit'];
    if (beforeId != null) {
      query.add('before_id=$beforeId');
    }
    final result = await _request(
      'GET',
      '/api/chats/$chatId/messages/cursor?${query.join('&')}',
    );
    return Map<String, dynamic>.from(result as Map);
  }

  Iterable<List<int>> _chunkBytes(
    Uint8List bytes, {
    int chunkSize = 64 * 1024,
  }) sync* {
    if (bytes.isEmpty) return;
    var offset = 0;
    while (offset < bytes.length) {
      final end = (offset + chunkSize < bytes.length)
          ? offset + chunkSize
          : bytes.length;
      yield bytes.sublist(offset, end);
      offset = end;
    }
  }

  Future<Map<String, dynamic>> uploadAttachment(
    int chatId, {
    required String fileName,
    required Uint8List bytes,
    void Function(double progress)? onProgress,
  }) async {
    Future<http.Response> sendOnce() async {
      final request = http.MultipartRequest(
        'POST',
        Uri.parse('$_safeBase/api/media/upload?chat_id=$chatId'),
      );
      if (accessToken != null && accessToken!.isNotEmpty) {
        request.headers['Authorization'] = 'Bearer $accessToken';
      }

      final total = bytes.length;
      var sent = 0;
      final stream = Stream<List<int>>.fromIterable(_chunkBytes(bytes)).map((
        chunk,
      ) {
        sent += chunk.length;
        if (total > 0 && onProgress != null) {
          onProgress((sent / total).clamp(0, 1).toDouble());
        }
        return chunk;
      });

      request.files.add(
        http.MultipartFile('file', stream, bytes.length, filename: fileName),
      );

      final streamed = await request.send().timeout(
        const Duration(seconds: 45),
      );
      return http.Response.fromStream(streamed);
    }

    http.Response response;
    try {
      response = await sendOnce();
    } on TimeoutException {
      throw ApiException('Upload timeout. Check internet or server status.');
    } catch (_) {
      throw ApiException('Upload failed. Check internet connection.');
    }

    if (response.statusCode == 401) {
      final refreshed = await _tryRefreshAccessToken();
      if (refreshed) {
        try {
          response = await sendOnce();
        } on TimeoutException {
          throw ApiException(
            'Upload timeout. Check internet or server status.',
          );
        } catch (_) {
          throw ApiException('Upload failed. Check internet connection.');
        }
      } else if (onUnauthorized != null) {
        await onUnauthorized!();
      }
    }

    final decoded = _decodeResponse(response);
    if (response.statusCode >= 400) {
      if (decoded is Map<String, dynamic> && decoded['detail'] != null) {
        throw ApiException(_extractErrorMessage(decoded['detail']));
      }
      throw ApiException('HTTP ${response.statusCode}: ${response.body}');
    }

    if (decoded is! Map) {
      throw ApiException('Invalid upload response');
    }
    if (onProgress != null) {
      onProgress(1);
    }
    return Map<String, dynamic>.from(decoded);
  }

  Future<Map<String, dynamic>> sendMessage(
    int chatId,
    String content, {
    List<int> attachmentIds = const [],
  }) async {
    final result = await _request(
      'POST',
      '/api/chats/$chatId/messages',
      body: {'content': content, 'attachment_ids': attachmentIds},
    );
    return Map<String, dynamic>.from(result as Map);
  }

  Future<Map<String, dynamic>> updateMessage(
    int messageId,
    String content,
  ) async {
    final result = await _request(
      'PATCH',
      '/api/chats/messages/$messageId',
      body: {'content': content},
    );
    return Map<String, dynamic>.from(result as Map);
  }

  Future<Map<String, dynamic>> deleteMessage(int messageId) async {
    final result = await _request('DELETE', '/api/chats/messages/$messageId');
    return Map<String, dynamic>.from(result as Map);
  }

  Future<Map<String, dynamic>> addMessageReaction(
    int messageId,
    String emoji,
  ) async {
    final result = await _request(
      'POST',
      '/api/chats/messages/$messageId/reactions',
      body: {'emoji': emoji},
    );
    return Map<String, dynamic>.from(result as Map);
  }

  Future<Map<String, dynamic>> removeMessageReaction(
    int messageId,
    String emoji,
  ) async {
    final encoded = Uri.encodeQueryComponent(emoji);
    final result = await _request(
      'DELETE',
      '/api/chats/messages/$messageId/reactions?emoji=$encoded',
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
  static final RegExp _emailPattern = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

  bool _loading = false;

  bool get _canLogin {
    final login = _loginController.text.trim();
    final password = _passwordController.text.trim();
    return login.length >= 3 && password.length >= 8;
  }

  bool get _canRegister {
    final username = _regUserController.text.trim();
    final email = _regEmailController.text.trim();
    final password = _regPasswordController.text.trim();
    return username.length >= 3 &&
        _emailPattern.hasMatch(email) &&
        password.length >= 8;
  }

  @override
  void dispose() {
    _loginController.dispose();
    _passwordController.dispose();
    _regUserController.dispose();
    _regEmailController.dispose();
    _regPasswordController.dispose();
    super.dispose();
  }

  void _onFieldChanged(String _) {
    if (!_loading) {
      setState(() {});
    }
  }

  Future<void> _run(
    Future<Map<String, dynamic>> Function(ApiClient client) action,
  ) async {
    if (_loading) return;
    setState(() => _loading = true);
    try {
      final client = ApiClient(baseUrl: widget.baseUrl);
      final response = await action(client);
      final accessToken = response['access_token']?.toString();
      final refreshToken = response['refresh_token']?.toString();
      if (accessToken == null || accessToken.isEmpty) {
        throw ApiException('Access token not received');
      }
      final normalizedRefresh = refreshToken == null || refreshToken.isEmpty
          ? null
          : refreshToken;
      await widget.onAuthenticated(
        SessionTokens(
          accessToken: accessToken,
          refreshToken: normalizedRefresh,
        ),
      );
    } catch (error) {
      if (!mounted) return;
      final message = error is ApiException
          ? error.message
          : 'Unable to complete request. Try again.';
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  Widget _buildAuthField({
    required TextEditingController controller,
    required String label,
    required IconData icon,
    bool obscureText = false,
    TextInputType? keyboardType,
    String? helperText,
  }) {
    return TextField(
      controller: controller,
      enabled: !_loading,
      obscureText: obscureText,
      keyboardType: keyboardType,
      onChanged: _onFieldChanged,
      decoration: InputDecoration(
        labelText: label,
        helperText: helperText,
        prefixIcon: Icon(icon),
      ),
    );
  }

  Widget _buildSubmitButton({
    required bool enabled,
    required IconData icon,
    required String label,
    required VoidCallback onPressed,
  }) {
    return FilledButton.icon(
      onPressed: enabled && !_loading ? onPressed : null,
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(54),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      icon: _loading
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(icon),
      label: Text(_loading ? 'Please wait...' : label),
    );
  }

  Widget _buildLoginTab(ThemeData theme) {
    return ListView(
      children: [
        Text(
          'Welcome back',
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'Use your username or email to continue.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 14),
        _buildAuthField(
          controller: _loginController,
          label: 'Username or email',
          icon: Icons.alternate_email_rounded,
          helperText: 'Minimum 3 characters',
        ),
        const SizedBox(height: 8),
        _buildAuthField(
          controller: _passwordController,
          label: 'Password',
          icon: Icons.lock_outline_rounded,
          obscureText: true,
          helperText: 'Minimum 8 characters',
        ),
        const SizedBox(height: 12),
        _buildSubmitButton(
          enabled: _canLogin,
          icon: Icons.login_rounded,
          label: 'Login',
          onPressed: () {
            _run(
              (client) => client.login(
                _loginController.text.trim(),
                _passwordController.text.trim(),
              ),
            );
          },
        ),
      ],
    );
  }

  Widget _buildRegisterTab(ThemeData theme) {
    return ListView(
      children: [
        Text(
          'Create your account',
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'Choose your identity and start messaging instantly.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 14),
        _buildAuthField(
          controller: _regUserController,
          label: 'Username',
          icon: Icons.person_outline_rounded,
          helperText: 'Minimum 3 characters',
        ),
        const SizedBox(height: 8),
        _buildAuthField(
          controller: _regEmailController,
          label: 'Email',
          icon: Icons.mail_outline_rounded,
          keyboardType: TextInputType.emailAddress,
          helperText: 'Valid email required',
        ),
        const SizedBox(height: 8),
        _buildAuthField(
          controller: _regPasswordController,
          label: 'Password',
          icon: Icons.key_rounded,
          obscureText: true,
          helperText: 'Minimum 8 characters',
        ),
        const SizedBox(height: 12),
        _buildSubmitButton(
          enabled: _canRegister,
          icon: Icons.person_add_alt_1_rounded,
          label: 'Create account',
          onPressed: () {
            _run(
              (client) => client.register(
                _regUserController.text.trim(),
                _regEmailController.text.trim(),
                _regPasswordController.text.trim(),
              ),
            );
          },
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        body: Stack(
          children: [
            Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  colors: [Color(0xFFE4EDF2), Color(0xFFF8FBFC)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
              ),
            ),
            Positioned(
              top: -100,
              right: -90,
              child: Container(
                width: 260,
                height: 260,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: theme.colorScheme.primary.withValues(alpha: 0.08),
                ),
              ),
            ),
            Positioned(
              bottom: -120,
              left: -80,
              child: Container(
                width: 260,
                height: 260,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: theme.colorScheme.secondary.withValues(alpha: 0.09),
                ),
              ),
            ),
            SafeArea(
              child: Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 16,
                  ),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 460),
                    child: Card(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(24, 24, 24, 20),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Container(
                                  width: 56,
                                  height: 56,
                                  decoration: BoxDecoration(
                                    gradient: LinearGradient(
                                      colors: [
                                        theme.colorScheme.primary.withValues(
                                          alpha: 0.22,
                                        ),
                                        theme.colorScheme.secondary.withValues(
                                          alpha: 0.3,
                                        ),
                                      ],
                                      begin: Alignment.topLeft,
                                      end: Alignment.bottomRight,
                                    ),
                                    borderRadius: BorderRadius.circular(16),
                                  ),
                                  child: Icon(
                                    Icons.bolt_rounded,
                                    color: theme.colorScheme.primary,
                                    size: 30,
                                  ),
                                ),
                                const SizedBox(width: 14),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        'AstraLink',
                                        style: theme.textTheme.headlineSmall
                                            ?.copyWith(
                                              fontWeight: FontWeight.w800,
                                              letterSpacing: -0.3,
                                            ),
                                      ),
                                      Text(
                                        'Private messaging, reimagined',
                                        style: theme.textTheme.bodyMedium
                                            ?.copyWith(
                                              color: theme
                                                  .colorScheme
                                                  .onSurfaceVariant,
                                            ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 20),
                            Container(
                              decoration: BoxDecoration(
                                color: const Color(0xFFEAF2F6),
                                borderRadius: BorderRadius.circular(14),
                              ),
                              child: TabBar(
                                indicator: BoxDecoration(
                                  color: theme.colorScheme.primary,
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                indicatorSize: TabBarIndicatorSize.tab,
                                dividerColor: Colors.transparent,
                                labelColor: Colors.white,
                                unselectedLabelColor:
                                    theme.colorScheme.onSurfaceVariant,
                                labelStyle: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                ),
                                tabs: const [
                                  Tab(text: 'Login'),
                                  Tab(text: 'Register'),
                                ],
                              ),
                            ),
                            const SizedBox(height: 16),
                            SizedBox(
                              height: 360,
                              child: TabBarView(
                                children: [
                                  _buildLoginTab(theme),
                                  _buildRegisterTab(theme),
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
          ],
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
  int? _myUserId;
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
      final uidPart = uid == null || uid.isEmpty
          ? ''
          : ' @${uid.toLowerCase()}';
      setState(() {
        _myUserId = id;
        _identity = id == null
            ? '$username$uidPart'
            : '$username$uidPart (#$id)';
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
    final notificationsEnabled =
        prefs.getBool(kPrefUpdateNotifications) ?? true;

    setState(() => _checkingUpdates = true);
    try {
      final info = await PackageInfo.fromPlatform();
      final currentVersion = '${info.version}+${info.buildNumber}';
      final release = await _api.latestRelease(
        platform,
        channel: updateChannel,
      );

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
      ChatsPage(api: _api, currentUserId: _myUserId),
      ContactsPage(api: _api),
      CustomizationPage(api: _api),
      ProfilePage(api: _api),
    ];
    final titles = ['AstraLink', 'Contacts', 'Settings', 'Profile'];

    final theme = Theme.of(context);
    final PreferredSizeWidget? appBar = _tab == 0
        ? null
        : AppBar(
            titleSpacing: 14,
            title: Row(
              children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(11),
                    gradient: const LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [Color(0xFF7A46FA), Color(0xFFB65CFF)],
                    ),
                  ),
                  child: const Icon(
                    Icons.send_rounded,
                    size: 18,
                    color: Color(0xFFEFE2FF),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        titles[_tab],
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      Text(
                        _identity,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
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
              PopupMenuButton<String>(
                color: const Color(0xFF1A1F2A),
                onSelected: (value) {
                  if (value == 'refresh') {
                    _checkForUpdates(force: true);
                  } else if (value == 'logout') {
                    _logout();
                  }
                },
                itemBuilder: (context) => const [
                  PopupMenuItem(value: 'refresh', child: Text('Check updates')),
                  PopupMenuItem(value: 'logout', child: Text('Logout')),
                ],
                icon: const Icon(Icons.more_vert_rounded),
              ),
            ],
          );

    return Scaffold(
      appBar: appBar,
      body: SafeArea(
        child: IndexedStack(index: _tab, children: pages),
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(28),
            child: NavigationBar(
              height: 70,
              selectedIndex: _tab,
              onDestinationSelected: (index) => setState(() => _tab = index),
              destinations: const [
                NavigationDestination(
                  icon: Icon(Icons.chat_bubble_outline),
                  selectedIcon: Icon(Icons.chat_bubble),
                  label: 'Chats',
                ),
                NavigationDestination(
                  icon: Icon(Icons.contacts_outlined),
                  selectedIcon: Icon(Icons.contacts_rounded),
                  label: 'Contacts',
                ),
                NavigationDestination(
                  icon: Icon(Icons.settings_outlined),
                  selectedIcon: Icon(Icons.settings),
                  label: 'Settings',
                ),
                NavigationDestination(
                  icon: Icon(Icons.person_outline_rounded),
                  selectedIcon: Icon(Icons.person_rounded),
                  label: 'Profile',
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class ChatsPage extends StatefulWidget {
  final ApiClient api;
  final int? currentUserId;
  const ChatsPage({super.key, required this.api, required this.currentUserId});

  @override
  State<ChatsPage> createState() => _ChatsPageState();
}

class _ChatsPageState extends State<ChatsPage> {
  final _chatSearchController = TextEditingController();
  final _uidSearchController = TextEditingController();
  final _newChatController = TextEditingController();
  final _newMembersController = TextEditingController();
  final _messageController = TextEditingController();
  final List<DraftAttachment> _draftAttachments = [];
  int _attachmentCounter = 0;
  WebSocketChannel? _globalChannel;

  List<Map<String, dynamic>> _chats = [];
  List<Map<String, dynamic>> _messages = [];
  int? _activeChatId;
  String _chatQuery = '';
  String _chatFilter = 'all';
  bool _mobileThreadOpen = false;
  bool _showChatTools = false;
  Map<String, dynamic>? _uidResult;
  bool _loading = false;
  bool _uidLookupLoading = false;
  bool _realtimeEnabled = true;
  Timer? _realtimeHeartbeatTimer;
  Timer? _realtimeReconnectTimer;
  Timer? _chatsRefreshTimer;
  Timer? _activeThreadSyncTimer;
  Timer? _typingStopTimer;
  int? _messagesNextBeforeId;
  bool _loadingOlderMessages = false;
  final Map<int, DateTime> _typingUsers = {};
  final Set<int> _onlineUsers = {};
  final Map<int, String> _myAckStatusByMessage = {};
  final Map<int, String> _pendingAckStatusByMessage = {};

  @override
  void initState() {
    super.initState();
    _startRealtimeHeartbeat();
    _connectGlobalRealtime();
    _loadChats();
  }

  @override
  void dispose() {
    _realtimeHeartbeatTimer?.cancel();
    _realtimeReconnectTimer?.cancel();
    _chatsRefreshTimer?.cancel();
    _activeThreadSyncTimer?.cancel();
    _typingStopTimer?.cancel();
    _closeGlobalRealtime(disableState: false);
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

  String? _accessToken() {
    final token = widget.api.accessToken;
    if (token == null || token.isEmpty) return null;
    return token;
  }

  Uri _globalWsUri(String token) {
    final normalized = widget.api.baseUrl.endsWith('/')
        ? widget.api.baseUrl.substring(0, widget.api.baseUrl.length - 1)
        : widget.api.baseUrl;
    final httpUri = Uri.parse(normalized);
    final scheme = httpUri.scheme == 'https' ? 'wss' : 'ws';
    return httpUri.replace(
      scheme: scheme,
      path: '/api/realtime/me/ws',
      queryParameters: {'token': token},
    );
  }

  void _startRealtimeHeartbeat() {
    _realtimeHeartbeatTimer?.cancel();
    _realtimeHeartbeatTimer = Timer.periodic(const Duration(seconds: 25), (_) {
      final channel = _globalChannel;
      if (channel == null) return;
      try {
        channel.sink.add(jsonEncode({'type': 'ping'}));
      } catch (_) {
        // Ignore ping failures; reconnect handler covers broken sockets.
      }
    });
  }

  void _closeGlobalRealtime({bool disableState = true}) {
    final channel = _globalChannel;
    _globalChannel = null;
    channel?.sink.close();
    _pendingAckStatusByMessage.clear();
    if (disableState && mounted && _realtimeEnabled) {
      setState(() => _realtimeEnabled = false);
    }
  }

  void _scheduleGlobalReconnect() {
    if (_realtimeReconnectTimer?.isActive == true) return;
    _realtimeReconnectTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted) return;
      _realtimeReconnectTimer = null;
      _connectGlobalRealtime();
    });
  }

  void _connectGlobalRealtime() {
    if (_globalChannel != null) return;
    _pendingAckStatusByMessage.clear();
    final token = _accessToken();
    if (token == null) {
      if (mounted && _realtimeEnabled) {
        setState(() => _realtimeEnabled = false);
      }
      return;
    }

    try {
      final channel = WebSocketChannel.connect(_globalWsUri(token));
      _globalChannel = channel;
      if (mounted && !_realtimeEnabled) {
        setState(() => _realtimeEnabled = true);
      }

      channel.stream.listen(
        _handleRealtimeEvent,
        onError: (_) {
          _closeGlobalRealtime();
          _scheduleGlobalReconnect();
        },
        onDone: () {
          _closeGlobalRealtime();
          _scheduleGlobalReconnect();
        },
        cancelOnError: true,
      );
    } catch (_) {
      _scheduleGlobalReconnect();
    }
  }

  void _upsertMessage(Map<String, dynamic> incoming) {
    final messageId = _asInt(incoming['id']);
    if (messageId == null) return;

    final next = List<Map<String, dynamic>>.from(_messages);
    final existingIndex = next.indexWhere((m) => _asInt(m['id']) == messageId);
    if (existingIndex >= 0) {
      next[existingIndex] = incoming;
    } else {
      next.add(incoming);
    }
    next.sort((a, b) => (_asInt(a['id']) ?? 0).compareTo(_asInt(b['id']) ?? 0));

    if (mounted) {
      setState(() => _messages = next);
    }
  }

  void _removeMessage(int messageId) {
    final next = _messages.where((m) => _asInt(m['id']) != messageId).toList();
    if (mounted) {
      setState(() => _messages = next);
    }
  }

  List<Map<String, dynamic>> _messageReactionRows(
    Map<String, dynamic> message,
  ) {
    final raw = message['reactions'];
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map((entry) => Map<String, dynamic>.from(entry))
        .toList();
  }

  List<Map<String, dynamic>> _messageAttachmentRows(
    Map<String, dynamic> message,
  ) {
    final raw = message['attachments'];
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map((entry) => Map<String, dynamic>.from(entry))
        .toList();
  }

  String _nextAttachmentId() {
    final next = _attachmentCounter++;
    return '${DateTime.now().microsecondsSinceEpoch}-$next';
  }

  String _guessMimeType(String filename) {
    final lower = filename.toLowerCase();
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.gif')) return 'image/gif';
    if (lower.endsWith('.webp')) return 'image/webp';
    if (lower.endsWith('.mp4')) return 'video/mp4';
    if (lower.endsWith('.mov')) return 'video/quicktime';
    if (lower.endsWith('.pdf')) return 'application/pdf';
    if (lower.endsWith('.txt')) return 'text/plain';
    return 'application/octet-stream';
  }

  String _formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    final kb = bytes / 1024;
    if (kb < 1024) return '${kb.toStringAsFixed(1)} KB';
    final mb = kb / 1024;
    if (mb < 1024) return '${mb.toStringAsFixed(1)} MB';
    final gb = mb / 1024;
    return '${gb.toStringAsFixed(1)} GB';
  }

  String _resolveMediaUrl(String raw) {
    final value = raw.trim();
    if (value.isEmpty) return '';
    if (value.startsWith('http://') || value.startsWith('https://')) {
      return value;
    }
    final base = widget.api.baseUrl.endsWith('/')
        ? widget.api.baseUrl.substring(0, widget.api.baseUrl.length - 1)
        : widget.api.baseUrl;
    if (value.startsWith('/')) {
      return '$base$value';
    }
    return '$base/$value';
  }

  Future<void> _openAttachmentUrl(String rawUrl) async {
    final resolved = _resolveMediaUrl(rawUrl);
    if (resolved.isEmpty) return;
    final uri = Uri.tryParse(resolved);
    if (uri == null) {
      _show(ApiException('Invalid attachment URL'));
      return;
    }
    final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!opened) {
      _show(ApiException('Cannot open attachment'));
    }
  }

  DraftAttachment? _findDraftAttachment(String localId) {
    for (final item in _draftAttachments) {
      if (item.localId == localId) return item;
    }
    return null;
  }

  void _updateDraftAttachment(
    String localId,
    void Function(DraftAttachment attachment) updater,
  ) {
    if (!mounted) return;
    setState(() {
      final index = _draftAttachments.indexWhere(
        (attachment) => attachment.localId == localId,
      );
      if (index < 0) return;
      updater(_draftAttachments[index]);
    });
  }

  Future<void> _uploadDraftAttachment(DraftAttachment draft, int chatId) async {
    final bytes = draft.bytes;
    if (bytes == null || bytes.isEmpty) {
      _updateDraftAttachment(draft.localId, (attachment) {
        attachment.uploading = false;
        attachment.error = 'Attachment bytes are unavailable';
      });
      return;
    }

    _updateDraftAttachment(draft.localId, (attachment) {
      attachment.uploading = true;
      attachment.error = null;
      attachment.progress = attachment.progress.clamp(0, 1).toDouble();
    });

    try {
      final uploaded = await widget.api.uploadAttachment(
        chatId,
        fileName: draft.fileName,
        bytes: bytes,
        onProgress: (progress) {
          _updateDraftAttachment(draft.localId, (attachment) {
            attachment.progress = progress;
          });
        },
      );
      final mediaId = _asInt(uploaded['id']);
      final mediaUrl = uploaded['url']?.toString();
      _updateDraftAttachment(draft.localId, (attachment) {
        attachment.uploading = false;
        attachment.progress = 1;
        attachment.mediaId = mediaId;
        attachment.mediaUrl = mediaUrl;
        attachment.error = null;
        attachment.bytes = null;
      });
    } catch (error) {
      final message = error is ApiException ? error.message : error.toString();
      _updateDraftAttachment(draft.localId, (attachment) {
        attachment.uploading = false;
        attachment.error = message;
      });
    }
  }

  Future<void> _pickAttachments() async {
    final chatId = _activeChatId;
    if (chatId == null) return;

    try {
      final picked = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        withData: true,
      );
      if (picked == null || picked.files.isEmpty) return;

      final added = <DraftAttachment>[];
      for (final file in picked.files) {
        final bytes = file.bytes;
        if (bytes == null || bytes.isEmpty) {
          continue;
        }
        added.add(
          DraftAttachment(
            localId: _nextAttachmentId(),
            chatId: chatId,
            fileName: file.name,
            mimeType: _guessMimeType(file.name),
            sizeBytes: file.size,
            bytes: bytes,
            uploading: true,
            progress: 0,
          ),
        );
      }
      if (added.isEmpty) {
        _show(ApiException('Selected files are empty or unsupported'));
        return;
      }

      setState(() => _draftAttachments.addAll(added));
      for (final draft in added) {
        unawaited(_uploadDraftAttachment(draft, chatId));
      }
    } catch (error) {
      _show(error);
    }
  }

  Future<List<int>?> _ensureDraftUploads(int chatId) async {
    final drafts = List<DraftAttachment>.from(_draftAttachments);
    for (final draft in drafts) {
      if (draft.chatId != chatId) {
        _show(ApiException('Attachments belong to another chat'));
        return null;
      }
      if (draft.mediaId != null) continue;
      if (draft.uploading) {
        _show(ApiException('Wait until attachments finish uploading'));
        return null;
      }
      await _uploadDraftAttachment(draft, chatId);
      final updated = _findDraftAttachment(draft.localId);
      if (updated == null || updated.mediaId == null) {
        _show(ApiException(updated?.error ?? 'Attachment upload failed'));
        return null;
      }
    }

    final mediaIds = _draftAttachments
        .where((draft) => draft.chatId == chatId && draft.mediaId != null)
        .map((draft) => draft.mediaId!)
        .toList();
    return mediaIds;
  }

  void _removeDraftAttachment(String localId) {
    if (!mounted) return;
    setState(() {
      _draftAttachments.removeWhere((item) => item.localId == localId);
    });
  }

  void _applyLocalReaction(
    int messageId,
    String emoji, {
    required bool added,
    required bool fromMe,
  }) {
    final next = List<Map<String, dynamic>>.from(_messages);
    final index = next.indexWhere((m) => _asInt(m['id']) == messageId);
    if (index < 0) return;

    final message = Map<String, dynamic>.from(next[index]);
    final reactions = _messageReactionRows(message);
    final existingIndex = reactions.indexWhere(
      (row) => row['emoji']?.toString() == emoji,
    );

    if (added) {
      if (existingIndex >= 0) {
        final row = Map<String, dynamic>.from(reactions[existingIndex]);
        row['count'] = (_asInt(row['count']) ?? 0) + 1;
        if (fromMe) row['reacted_by_me'] = true;
        reactions[existingIndex] = row;
      } else {
        reactions.add({'emoji': emoji, 'count': 1, 'reacted_by_me': fromMe});
      }
    } else if (existingIndex >= 0) {
      final row = Map<String, dynamic>.from(reactions[existingIndex]);
      final nextCount = (_asInt(row['count']) ?? 1) - 1;
      if (fromMe) {
        row['reacted_by_me'] = false;
      }
      if (nextCount <= 0) {
        reactions.removeAt(existingIndex);
      } else {
        row['count'] = nextCount;
        reactions[existingIndex] = row;
      }
    }

    message['reactions'] = reactions;
    next[index] = message;
    if (mounted) {
      setState(() => _messages = next);
    }
  }

  void _scheduleChatsRefresh() {
    _chatsRefreshTimer?.cancel();
    _chatsRefreshTimer = Timer(const Duration(milliseconds: 500), () {
      if (!mounted) return;
      _loadChats(loadActiveMessages: false, silent: true);
    });
  }

  void _scheduleActiveThreadSync(int chatId) {
    _activeThreadSyncTimer?.cancel();
    _activeThreadSyncTimer = Timer(const Duration(milliseconds: 700), () {
      if (!mounted || _activeChatId != chatId) return;
      _loadMessages(chatId, silent: true);
    });
  }

  void _sendRealtimeTyping(int chatId, bool isTyping) {
    final channel = _globalChannel;
    if (channel == null) return;
    try {
      channel.sink.add(
        jsonEncode({
          'type': 'typing',
          'chat_id': chatId,
          'is_typing': isTyping,
        }),
      );
    } catch (_) {
      // Ignore typing send failures.
    }
  }

  int _deliveryRank(String status) {
    switch (status) {
      case 'read':
        return 2;
      case 'delivered':
        return 1;
      default:
        return 0;
    }
  }

  void _rememberMyAckStatus(int messageId, String status) {
    final normalized = status.trim().toLowerCase();
    if (normalized.isEmpty) return;
    final current = _myAckStatusByMessage[messageId];
    if (current == null || _deliveryRank(normalized) > _deliveryRank(current)) {
      _myAckStatusByMessage[messageId] = normalized;
    }

    final pending = _pendingAckStatusByMessage[messageId];
    if (pending != null &&
        _deliveryRank(normalized) >= _deliveryRank(pending)) {
      _pendingAckStatusByMessage.remove(messageId);
    }
  }

  void _rememberStatusesFromMessages(List<Map<String, dynamic>> items) {
    final currentUserId = widget.currentUserId;
    if (currentUserId == null) return;
    for (final row in items) {
      final messageId = _asInt(row['id']);
      final senderId = _asInt(row['sender_id']);
      final status = row['status']?.toString().trim().toLowerCase() ?? '';
      if (messageId == null || senderId == null || senderId == currentUserId) {
        continue;
      }
      if (status == 'delivered' || status == 'read') {
        _rememberMyAckStatus(messageId, status);
      }
    }
  }

  void _sendMessageStatusAck({
    required int chatId,
    required int messageId,
    required String status,
  }) {
    final normalized = status.trim().toLowerCase();
    if (normalized != 'delivered' && normalized != 'read') return;

    final known = _myAckStatusByMessage[messageId];
    if (known != null && _deliveryRank(known) >= _deliveryRank(normalized)) {
      return;
    }
    final pending = _pendingAckStatusByMessage[messageId];
    if (pending != null &&
        _deliveryRank(pending) >= _deliveryRank(normalized)) {
      return;
    }

    final channel = _globalChannel;
    if (channel == null) return;

    try {
      _pendingAckStatusByMessage[messageId] = normalized;
      channel.sink.add(
        jsonEncode({
          'type': 'ack',
          'chat_id': chatId,
          'message_id': messageId,
          'status': normalized,
        }),
      );
      Future<void>.delayed(const Duration(seconds: 5), () {
        final value = _pendingAckStatusByMessage[messageId];
        if (value == normalized) {
          _pendingAckStatusByMessage.remove(messageId);
        }
      });
    } catch (_) {
      if (_pendingAckStatusByMessage[messageId] == normalized) {
        _pendingAckStatusByMessage.remove(messageId);
      }
    }
  }

  void _ackReadForVisibleMessages(
    int chatId,
    List<Map<String, dynamic>> messages,
  ) {
    final currentUserId = widget.currentUserId;
    if (currentUserId == null) return;
    for (final row in messages) {
      final messageId = _asInt(row['id']);
      final senderId = _asInt(row['sender_id']);
      if (messageId == null || senderId == null || senderId == currentUserId) {
        continue;
      }
      _sendMessageStatusAck(
        chatId: chatId,
        messageId: messageId,
        status: 'read',
      );
    }
  }

  void _onComposerChanged(String value) {
    if (mounted) {
      setState(() {});
    }
    final chatId = _activeChatId;
    if (chatId == null) return;
    final hasText = value.trim().isNotEmpty;
    _typingStopTimer?.cancel();
    _sendRealtimeTyping(chatId, hasText);
    if (hasText) {
      _typingStopTimer = Timer(const Duration(seconds: 2), () {
        _sendRealtimeTyping(chatId, false);
      });
    }
  }

  void _setTypingUser(int userId, bool isTyping) {
    if (isTyping) {
      _typingUsers[userId] = DateTime.now();
      return;
    }
    _typingUsers.remove(userId);
  }

  void _purgeStaleTyping() {
    final now = DateTime.now();
    final stale = _typingUsers.entries
        .where((entry) => now.difference(entry.value).inSeconds > 4)
        .map((entry) => entry.key)
        .toList();
    for (final userId in stale) {
      _typingUsers.remove(userId);
    }
  }

  void _handleRealtimeEvent(dynamic rawEvent) {
    dynamic payload;
    if (rawEvent is String) {
      try {
        payload = jsonDecode(rawEvent);
      } catch (_) {
        return;
      }
    } else if (rawEvent is Map) {
      payload = rawEvent;
    } else {
      return;
    }

    if (payload is! Map) return;
    final data = Map<String, dynamic>.from(payload);
    final eventType = data['type']?.toString() ?? '';
    final eventChatId = _asInt(data['chat_id']);

    switch (eventType) {
      case 'ready':
      case 'pong':
        if (mounted && !_realtimeEnabled) {
          setState(() => _realtimeEnabled = true);
        }
        break;
      case 'presence':
        if (eventChatId == null || eventChatId != _activeChatId) break;
        final userId = _asInt(data['user_id']);
        final status = data['status']?.toString() ?? 'offline';
        if (userId != null && userId != widget.currentUserId) {
          if (status == 'online') {
            _onlineUsers.add(userId);
          } else {
            _onlineUsers.remove(userId);
            _typingUsers.remove(userId);
          }
          if (eventChatId == _activeChatId && mounted) {
            setState(() {});
          }
        }
        break;
      case 'typing':
        if (eventChatId == null || eventChatId != _activeChatId) break;
        final userId = _asInt(data['user_id']);
        final isTyping = data['is_typing'] == true;
        if (userId != null && userId != widget.currentUserId) {
          _setTypingUser(userId, isTyping);
          _purgeStaleTyping();
          if (eventChatId == _activeChatId && mounted) {
            setState(() {});
          }
        }
        break;
      case 'message':
      case 'message_updated':
        final messageRaw = data['message'];
        if (messageRaw is! Map) break;
        final message = Map<String, dynamic>.from(messageRaw);
        final messageChatId = _asInt(message['chat_id']) ?? eventChatId;
        final messageId = _asInt(message['id']);
        final senderId = _asInt(message['sender_id']);
        if (eventType == 'message' &&
            messageId != null &&
            messageChatId != null &&
            senderId != null &&
            senderId != widget.currentUserId) {
          _sendMessageStatusAck(
            chatId: messageChatId,
            messageId: messageId,
            status: messageChatId == _activeChatId ? 'read' : 'delivered',
          );
        }
        if (messageChatId != null && messageChatId == _activeChatId) {
          _upsertMessage(message);
          _scheduleActiveThreadSync(messageChatId);
        }
        _scheduleChatsRefresh();
        break;
      case 'message_status':
        final messageId = _asInt(data['message_id']);
        final userId = _asInt(data['user_id']);
        final senderId = _asInt(data['sender_id']);
        final status = data['status']?.toString().trim().toLowerCase() ?? '';
        final senderStatus =
            data['sender_status']?.toString().trim().toLowerCase() ?? '';
        if (messageId == null || eventChatId == null) break;

        if (userId == widget.currentUserId &&
            (status == 'delivered' || status == 'read')) {
          _rememberMyAckStatus(messageId, status);
        }

        final index = _messages.indexWhere((m) => _asInt(m['id']) == messageId);
        if (index >= 0) {
          final row = Map<String, dynamic>.from(_messages[index]);
          final currentUserId = widget.currentUserId;
          if (currentUserId != null && senderId == currentUserId) {
            if (senderStatus.isNotEmpty) {
              row['status'] = senderStatus;
            }
          } else if (currentUserId != null &&
              userId == currentUserId &&
              status.isNotEmpty) {
            row['status'] = status;
          }
          final updated = List<Map<String, dynamic>>.from(_messages);
          updated[index] = row;
          if (mounted) {
            setState(() => _messages = updated);
          }
        }
        if (eventChatId == _activeChatId) {
          _scheduleActiveThreadSync(eventChatId);
        }
        _scheduleChatsRefresh();
        break;
      case 'message_deleted':
        final messageId = _asInt(data['message_id']);
        if (messageId != null &&
            eventChatId != null &&
            eventChatId == _activeChatId) {
          _removeMessage(messageId);
        }
        _scheduleChatsRefresh();
        break;
      case 'reaction_added':
      case 'reaction_removed':
        final messageId = _asInt(data['message_id']);
        final userId = _asInt(data['user_id']);
        final emoji = data['emoji']?.toString();
        if (messageId != null &&
            eventChatId != null &&
            emoji != null &&
            emoji.isNotEmpty) {
          final added = eventType == 'reaction_added';
          _applyLocalReaction(
            messageId,
            emoji,
            added: added,
            fromMe: userId == widget.currentUserId,
          );
          _scheduleActiveThreadSync(eventChatId);
          _scheduleChatsRefresh();
        }
        break;
      default:
        break;
    }
  }

  Future<void> _loadChats({
    bool loadActiveMessages = true,
    bool silent = false,
  }) async {
    _connectGlobalRealtime();
    if (!silent && mounted) {
      setState(() => _loading = true);
    }
    try {
      final chats = await widget.api.chats();
      int? nextActive = _activeChatId;
      if (nextActive != null &&
          !chats.any((chat) => _asInt(chat['id']) == nextActive)) {
        nextActive = null;
      }
      nextActive ??= chats.isNotEmpty ? _asInt(chats.first['id']) : null;

      setState(() {
        _chats = chats;
        _activeChatId = nextActive;
        if (nextActive == null) {
          _mobileThreadOpen = false;
        }
      });

      if (nextActive != null && loadActiveMessages) {
        await _loadMessages(nextActive);
      } else if (nextActive == null) {
        setState(() => _messages = []);
      }
    } catch (error) {
      if (!silent) {
        _show(error);
      }
    } finally {
      if (!silent && mounted) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _loadMessages(
    int chatId, {
    bool silent = false,
    bool openThread = false,
  }) async {
    try {
      final page = await widget.api.messagesCursor(chatId, limit: 40);
      final items = (page['items'] as List? ?? const [])
          .map((row) => Map<String, dynamic>.from(row as Map))
          .toList();
      _rememberStatusesFromMessages(items);
      items.sort(
        (a, b) => (_asInt(a['id']) ?? 0).compareTo(_asInt(b['id']) ?? 0),
      );
      final previousChatId = _activeChatId;
      final switchingChat = _activeChatId != chatId;
      if (switchingChat && previousChatId != null) {
        _sendRealtimeTyping(previousChatId, false);
      }
      setState(() {
        _activeChatId = chatId;
        _messages = items;
        _messagesNextBeforeId = _asInt(page['next_before_id']);
        if (openThread) {
          _mobileThreadOpen = true;
        }
        if (switchingChat) {
          _typingUsers.clear();
          _onlineUsers.clear();
          _draftAttachments.clear();
        }
      });
      _ackReadForVisibleMessages(chatId, items);
    } catch (error) {
      if (!silent) {
        _show(error);
      }
    }
  }

  Future<void> _loadOlderMessages() async {
    final chatId = _activeChatId;
    final beforeId = _messagesNextBeforeId;
    if (chatId == null || beforeId == null || _loadingOlderMessages) return;

    setState(() => _loadingOlderMessages = true);
    try {
      final page = await widget.api.messagesCursor(
        chatId,
        limit: 40,
        beforeId: beforeId,
      );
      final older = (page['items'] as List? ?? const [])
          .map((row) => Map<String, dynamic>.from(row as Map))
          .toList();
      _rememberStatusesFromMessages(older);
      final merged = [...older, ..._messages];
      final byId = <int, Map<String, dynamic>>{};
      for (final row in merged) {
        final id = _asInt(row['id']);
        if (id != null) byId[id] = row;
      }
      final sorted = byId.values.toList()
        ..sort(
          (a, b) => (_asInt(a['id']) ?? 0).compareTo(_asInt(b['id']) ?? 0),
        );
      setState(() {
        _messages = sorted;
        _messagesNextBeforeId = _asInt(page['next_before_id']);
      });
      _ackReadForVisibleMessages(chatId, older);
    } catch (error) {
      _show(error);
    } finally {
      if (mounted) {
        setState(() => _loadingOlderMessages = false);
      }
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
    if (chatId == null) return;

    try {
      final attachmentIds = await _ensureDraftUploads(chatId);
      if (attachmentIds == null) return;
      if (content.isEmpty && attachmentIds.isEmpty) return;

      final sent = await widget.api.sendMessage(
        chatId,
        content,
        attachmentIds: attachmentIds,
      );
      _messageController.clear();
      setState(() => _draftAttachments.clear());
      _typingStopTimer?.cancel();
      _sendRealtimeTyping(chatId, false);
      _upsertMessage(sent);
      _scheduleChatsRefresh();
    } catch (error) {
      _show(error);
    }
  }

  void _show(Object error) {
    if (!mounted) return;
    final message = error is ApiException ? error.message : error.toString();
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  String? _typingBannerText() {
    _purgeStaleTyping();
    if (_typingUsers.isEmpty) return null;
    if (_typingUsers.length == 1) {
      final userId = _typingUsers.keys.first;
      return 'User $userId is typing...';
    }
    return '${_typingUsers.length} users are typing...';
  }

  Future<void> _toggleMessageReaction(
    Map<String, dynamic> message,
    String emoji,
  ) async {
    final messageId = _asInt(message['id']);
    if (messageId == null) return;

    final reactions = _messageReactionRows(message);
    final existing = reactions.cast<Map<String, dynamic>?>().firstWhere(
      (entry) => entry?['emoji']?.toString() == emoji,
      orElse: () => null,
    );
    final reactedByMe = existing?['reacted_by_me'] == true;

    try {
      if (reactedByMe) {
        await widget.api.removeMessageReaction(messageId, emoji);
        _applyLocalReaction(messageId, emoji, added: false, fromMe: true);
      } else {
        await widget.api.addMessageReaction(messageId, emoji);
        _applyLocalReaction(messageId, emoji, added: true, fromMe: true);
      }
      _scheduleChatsRefresh();
    } catch (error) {
      _show(error);
    }
  }

  Future<void> _editMessage(Map<String, dynamic> message) async {
    final messageId = _asInt(message['id']);
    if (messageId == null) return;
    final controller = TextEditingController(
      text: message['content']?.toString() ?? '',
    );
    final updated = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Edit message'),
          content: TextField(
            controller: controller,
            minLines: 1,
            maxLines: 6,
            decoration: const InputDecoration(hintText: 'Message text'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, controller.text.trim()),
              child: const Text('Save'),
            ),
          ],
        );
      },
    );

    if (updated == null || updated.isEmpty) return;
    try {
      final response = await widget.api.updateMessage(messageId, updated);
      _upsertMessage(response);
      _scheduleChatsRefresh();
    } catch (error) {
      _show(error);
    }
  }

  Future<void> _deleteMessage(Map<String, dynamic> message) async {
    final messageId = _asInt(message['id']);
    if (messageId == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Delete message?'),
          content: const Text('This action cannot be undone.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete'),
            ),
          ],
        );
      },
    );
    if (confirmed != true) return;

    try {
      final response = await widget.api.deleteMessage(messageId);
      if (response['removed'] == true) {
        _removeMessage(messageId);
        _scheduleChatsRefresh();
      }
    } catch (error) {
      _show(error);
    }
  }

  Future<void> _openMessageActions(Map<String, dynamic> message) async {
    final senderId = _asInt(message['sender_id']);
    final isOwn =
        widget.currentUserId != null && senderId == widget.currentUserId;
    final reactions = _messageReactionRows(message);
    final quickEmojis = ['рџ‘Ќ', 'рџ”Ґ', 'вќ¤пёЏ', 'рџ‚', 'рџ‘Џ'];

    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (isOwn)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.edit_outlined),
                    title: const Text('Edit'),
                    onTap: () {
                      Navigator.pop(context);
                      _editMessage(message);
                    },
                  ),
                if (isOwn)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.delete_outline_rounded),
                    title: const Text('Delete'),
                    onTap: () {
                      Navigator.pop(context);
                      _deleteMessage(message);
                    },
                  ),
                if (isOwn) const SizedBox(height: 6),
                const Text('Quick reaction'),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: quickEmojis.map((emoji) {
                    final reacted = reactions.any(
                      (row) =>
                          row['emoji']?.toString() == emoji &&
                          row['reacted_by_me'] == true,
                    );
                    return ChoiceChip(
                      selected: reacted,
                      label: Text(emoji),
                      onSelected: (_) {
                        Navigator.pop(context);
                        _toggleMessageReaction(message, emoji);
                      },
                    );
                  }).toList(),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Map<String, dynamic>? get _activeChat {
    final id = _activeChatId;
    if (id == null) return null;
    for (final chat in _chats) {
      if (_asInt(chat['id']) == id) return chat;
    }
    return null;
  }

  List<Map<String, dynamic>> get _visibleChats {
    final query = _chatQuery.trim().toLowerCase();
    final filtered = _chats.where((chat) {
      final type = chat['type']?.toString().toLowerCase() ?? 'group';
      final unread = _asInt(chat['unread_count']) ?? 0;
      if (_chatFilter == 'private' && type != 'private') return false;
      if (_chatFilter == 'groups' && type == 'private') return false;
      if (_chatFilter == 'unread' && unread <= 0) return false;

      if (query.isEmpty) return true;
      final title = chat['title']?.toString().toLowerCase() ?? '';
      final lastMessage =
          chat['last_message_preview']?.toString().toLowerCase() ?? '';
      return title.contains(query) || lastMessage.contains(query);
    });
    return filtered.toList();
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

  IconData _messageStatusIcon(String status) {
    switch (status.toLowerCase()) {
      case 'read':
        return Icons.done_all_rounded;
      case 'delivered':
        return Icons.done_all_rounded;
      default:
        return Icons.done_rounded;
    }
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
      padding: const EdgeInsets.only(top: 2, bottom: 8),
      itemCount: chats.length,
      itemBuilder: (context, index) {
        final chat = chats[index];
        final chatId = _asInt(chat['id']);
        if (chatId == null) return const SizedBox.shrink();
        final selected = _activeChatId == chatId;
        final title = chat['title']?.toString() ?? 'Untitled';
        final preview =
            chat['last_message_preview']?.toString() ??
            chat['description']?.toString() ??
            'No messages yet';
        final unread = _asInt(chat['unread_count']) ?? 0;
        final timeText = _formatLastTime(chat['last_message_at']);
        final type = chat['type']?.toString().toLowerCase() ?? 'group';
        final avatarText = title.isNotEmpty ? title[0].toUpperCase() : '?';
        final muted = chat['is_muted'] == true;
        final pinned = chat['is_pinned'] == true;
        final lastStatus = chat['last_message_status']?.toString() ?? '';

        return InkWell(
          onTap: () => _loadMessages(chatId, openThread: true),
          borderRadius: BorderRadius.circular(14),
          child: Container(
            margin: const EdgeInsets.only(bottom: 2),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
            decoration: BoxDecoration(
              color: selected ? const Color(0xFF1C2330) : Colors.transparent,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 25,
                  backgroundColor: type == 'private'
                      ? const Color(0xFF3241A8)
                      : const Color(0xFF3A2D57),
                  child: Text(
                    avatarText,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
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
                              style: theme.textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          if (muted)
                            const Padding(
                              padding: EdgeInsets.only(right: 6),
                              child: Icon(
                                Icons.notifications_off_rounded,
                                color: Color(0xFF7D8498),
                                size: 16,
                              ),
                            ),
                          if (timeText.isNotEmpty)
                            Text(
                              timeText,
                              style: theme.textTheme.labelMedium?.copyWith(
                                color: const Color(0xFF8D93A8),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 3),
                      Row(
                        children: [
                          if (lastStatus.isNotEmpty && type == 'private') ...[
                            Icon(
                              _messageStatusIcon(lastStatus),
                              size: 15,
                              color: const Color(0xFFA665EE),
                            ),
                            const SizedBox(width: 4),
                          ],
                          Expanded(
                            child: Text(
                              preview,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: const Color(0xFF9EA5B8),
                              ),
                            ),
                          ),
                          if (unread > 0) ...[
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(0xFF8E3FF3),
                                borderRadius: BorderRadius.circular(999),
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
                          ] else if (pinned) ...[
                            const SizedBox(width: 8),
                            const Icon(
                              Icons.push_pin_rounded,
                              color: Color(0xFF7C8396),
                              size: 17,
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildChatTools(BuildContext context) {
    final canCreateGroup =
        _newChatController.text.trim().isNotEmpty &&
        _parseMemberIds().isNotEmpty;
    final canFindUid = _uidSearchController.text.trim().isNotEmpty;

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: const Color(0xFF161A23),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF252B38)),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _uidSearchController,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                    hintText: 'Find by UID',
                    prefixIcon: Icon(Icons.person_search_rounded),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _uidLookupLoading || !canFindUid
                    ? null
                    : _findUserByUid,
                child: const Text('Find'),
              ),
            ],
          ),
          if (_uidResult != null) ...[
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: _startPrivateFromUid,
                icon: const Icon(Icons.chat_bubble_outline_rounded),
                label: Text('Start chat with ${_uidResult!['username']}'),
              ),
            ),
          ],
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _newChatController,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                    hintText: 'Group title',
                    prefixIcon: Icon(Icons.group_outlined),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _newMembersController,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                    hintText: 'Member IDs: 2,3',
                    prefixIcon: Icon(Icons.tag_rounded),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: canCreateGroup ? _createChat : null,
                child: const Text('Create'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildThread(BuildContext context) {
    final theme = Theme.of(context);
    final typingBanner = _typingBannerText();
    final onlineCount = _onlineUsers.length;
    final hasOlder = _messagesNextBeforeId != null;
    final hasUploadingDraft = _draftAttachments.any((item) => item.uploading);
    final canSend =
        _activeChatId != null &&
        (_messageController.text.trim().isNotEmpty ||
            _draftAttachments.isNotEmpty) &&
        !hasUploadingDraft;

    final Widget threadContent;
    if (_activeChatId == null) {
      threadContent = Center(
        child: Text(
          'Select a chat to view messages',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    } else if (_messages.isEmpty) {
      threadContent = Center(
        child: Text(
          'No messages yet',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    } else {
      threadContent = ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: _messages.length + (hasOlder ? 1 : 0),
        itemBuilder: (context, index) {
          if (hasOlder && index == 0) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Center(
                child: OutlinedButton.icon(
                  onPressed: _loadingOlderMessages ? null : _loadOlderMessages,
                  icon: _loadingOlderMessages
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.expand_less_rounded),
                  label: const Text('Load older messages'),
                ),
              ),
            );
          }

          final messageIndex = hasOlder ? index - 1 : index;
          final msg = _messages[messageIndex];
          final content = msg['content']?.toString() ?? '';
          final senderId = _asInt(msg['sender_id']);
          final status = msg['status']?.toString() ?? '';
          final sentAt = _formatLastTime(msg['created_at']);
          final isOwn =
              widget.currentUserId != null && senderId == widget.currentUserId;

          return Align(
            alignment: isOwn ? Alignment.centerRight : Alignment.centerLeft,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 430),
              child: InkWell(
                onLongPress: () => _openMessageActions(msg),
                borderRadius: BorderRadius.circular(14),
                child: Container(
                  margin: EdgeInsets.only(
                    bottom: 8,
                    left: isOwn ? 34 : 0,
                    right: isOwn ? 0 : 34,
                  ),
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
                  decoration: BoxDecoration(
                    gradient: isOwn
                        ? const LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [Color(0xFF933BEE), Color(0xFF7F2FDF)],
                          )
                        : null,
                    color: isOwn ? null : const Color(0xFF1A1E28),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: isOwn
                          ? const Color(0xFFA95CFF)
                          : const Color(0xFF282E3A),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ...() {
                        final attachments = _messageAttachmentRows(msg);
                        if (attachments.isEmpty) {
                          return const <Widget>[];
                        }
                        return [
                          ...attachments.map((attachment) {
                            final rawUrl = attachment['url']?.toString() ?? '';
                            final resolvedUrl = _resolveMediaUrl(rawUrl);
                            final fileName =
                                attachment['file_name']?.toString() ?? 'file';
                            final size = _asInt(attachment['size_bytes']);
                            final isImage =
                                attachment['is_image'] == true ||
                                (attachment['mime_type']?.toString().startsWith(
                                      'image/',
                                    ) ??
                                    false);
                            if (isImage && resolvedUrl.isNotEmpty) {
                              return Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: InkWell(
                                  onTap: () => _openAttachmentUrl(rawUrl),
                                  borderRadius: BorderRadius.circular(12),
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(12),
                                    child: Image.network(
                                      resolvedUrl,
                                      height: 180,
                                      fit: BoxFit.cover,
                                      errorBuilder: (_, _, _) => Container(
                                        height: 70,
                                        alignment: Alignment.center,
                                        color: const Color(0xFFEAF2F6),
                                        child: Text(
                                          fileName,
                                          style: theme.textTheme.bodySmall
                                              ?.copyWith(color: Colors.white),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              );
                            }

                            return Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: InkWell(
                                onTap: () => _openAttachmentUrl(rawUrl),
                                borderRadius: BorderRadius.circular(12),
                                child: Container(
                                  width: double.infinity,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 8,
                                  ),
                                  decoration: BoxDecoration(
                                    color: isOwn
                                        ? const Color(0xFF8637DC)
                                        : const Color(0xFF222836),
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(
                                      color: isOwn
                                          ? const Color(0xFFAB78E9)
                                          : const Color(0xFF2F3644),
                                    ),
                                  ),
                                  child: Row(
                                    children: [
                                      const Icon(
                                        Icons.attach_file_rounded,
                                        size: 18,
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Text(
                                          size == null
                                              ? fileName
                                              : '$fileName (${_formatFileSize(size)})',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: theme.textTheme.bodySmall
                                              ?.copyWith(color: Colors.white),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            );
                          }),
                        ];
                      }(),
                      if (content.isNotEmpty) Text(content),
                      ...() {
                        final reactions = _messageReactionRows(msg);
                        if (reactions.isEmpty) {
                          return const <Widget>[];
                        }
                        return [
                          const SizedBox(height: 6),
                          Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: reactions.map((reaction) {
                              final emoji = reaction['emoji']?.toString() ?? '';
                              final count = _asInt(reaction['count']) ?? 0;
                              final reactedByMe =
                                  reaction['reacted_by_me'] == true;
                              return InkWell(
                                onTap: () => _toggleMessageReaction(msg, emoji),
                                borderRadius: BorderRadius.circular(999),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 4,
                                  ),
                                  decoration: BoxDecoration(
                                    color: reactedByMe
                                        ? const Color(0xFF63318E)
                                        : const Color(0xFF2D3444),
                                    borderRadius: BorderRadius.circular(999),
                                    border: Border.all(
                                      color: reactedByMe
                                          ? const Color(0xFF8D61B8)
                                          : const Color(0xFF3A4354),
                                    ),
                                  ),
                                  child: Text(
                                    '$emoji $count',
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: Colors.white,
                                    ),
                                  ),
                                ),
                              );
                            }).toList(),
                          ),
                        ];
                      }(),
                      const SizedBox(height: 4),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (!isOwn && senderId != null)
                            Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: Text(
                                'User $senderId',
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: const Color(0xFFBDC4D3),
                                ),
                              ),
                            ),
                          if (sentAt.isNotEmpty)
                            Text(
                              sentAt,
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: isOwn
                                    ? const Color(0xFFECD8FF)
                                    : const Color(0xFF8F95AA),
                              ),
                            ),
                          if (isOwn && status.isNotEmpty) ...[
                            const SizedBox(width: 4),
                            Icon(
                              _messageStatusIcon(status),
                              size: 15,
                              color: status.toLowerCase() == 'read'
                                  ? const Color(0xFF99E7FF)
                                  : const Color(0xFFE1CBFF),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      );
    }

    return Column(
      children: [
        if (_activeChatId != null)
          Container(
            width: double.infinity,
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: const Color(0xFF1A1F2A),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFF2C3342)),
            ),
            child: Text(
              typingBanner ??
                  (onlineCount > 0
                      ? '$onlineCount online in this chat'
                      : 'Realtime connected'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              gradient: const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0xFF0C0F15), Color(0xFF111624)],
              ),
            ),
            child: threadContent,
          ),
        ),
        const SizedBox(height: 8),
        Container(
          decoration: BoxDecoration(
            color: const Color(0xFF161B25),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFF2A3140)),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Column(
            children: [
              if (_draftAttachments.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: _draftAttachments.map((draft) {
                      final progressText = draft.uploading
                          ? '${(draft.progress * 100).round()}%'
                          : draft.isUploaded
                          ? 'Uploaded'
                          : (draft.error ?? 'Pending');
                      return Container(
                        constraints: const BoxConstraints(maxWidth: 260),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFF232A37),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: const Color(0xFF333B4D)),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              draft.isImage
                                  ? Icons.image_outlined
                                  : Icons.insert_drive_file_outlined,
                              size: 16,
                            ),
                            const SizedBox(width: 6),
                            Flexible(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    draft.fileName,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.bodySmall,
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    '$progressText - ${_formatFileSize(draft.sizeBytes)}',
                                    style: theme.textTheme.labelSmall,
                                  ),
                                  if (draft.uploading)
                                    Padding(
                                      padding: const EdgeInsets.only(top: 4),
                                      child: LinearProgressIndicator(
                                        value: draft.progress
                                            .clamp(0, 1)
                                            .toDouble(),
                                        minHeight: 4,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                            IconButton(
                              onPressed: draft.uploading
                                  ? null
                                  : () => _removeDraftAttachment(draft.localId),
                              icon: const Icon(Icons.close_rounded, size: 16),
                              splashRadius: 16,
                            ),
                          ],
                        ),
                      );
                    }).toList(),
                  ),
                ),
              Row(
                children: [
                  IconButton(
                    onPressed: _activeChatId == null ? null : _pickAttachments,
                    icon: const Icon(Icons.attach_file_rounded),
                    tooltip: 'Attach file',
                  ),
                  Expanded(
                    child: TextField(
                      controller: _messageController,
                      enabled: _activeChatId != null,
                      onChanged: _onComposerChanged,
                      onSubmitted: (_) => _sendMessage(),
                      minLines: 1,
                      maxLines: 4,
                      decoration: const InputDecoration(
                        border: InputBorder.none,
                        hintText: 'Write a message',
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  FilledButton(
                    onPressed: canSend ? _sendMessage : null,
                    style: FilledButton.styleFrom(
                      shape: const CircleBorder(),
                      padding: const EdgeInsets.all(14),
                      minimumSize: const Size(46, 46),
                    ),
                    child: const Icon(Icons.send_rounded, size: 20),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final wide = MediaQuery.of(context).size.width >= 900;
    final activeChat = _activeChat;
    final activeTitle = activeChat?['title']?.toString() ?? 'Conversation';
    final activeType = activeChat?['type']?.toString().toLowerCase() ?? '';
    final activeSubtitle = activeType == 'private'
        ? (activeChat == null ? '' : 'private chat')
        : 'group chat';

    final showThreadOnly = !wide && _mobileThreadOpen && _activeChatId != null;

    final folderTabs = <(String, String)>[
      ('all', 'All'),
      ('private', 'Private'),
      ('groups', 'Groups'),
      ('unread', 'Unread'),
    ];

    final listPane = Column(
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
          decoration: BoxDecoration(
            color: const Color(0xFF151A24),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: const Color(0xFF262D3A)),
          ),
          child: Column(
            children: [
              Row(
                children: [
                  Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      gradient: const LinearGradient(
                        colors: [Color(0xFF7A46FA), Color(0xFFB65CFF)],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                    ),
                    child: const Icon(
                      Icons.send_rounded,
                      color: Color(0xFFEFE2FF),
                      size: 20,
                    ),
                  ),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Chats',
                          style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -0.2,
                          ),
                        ),
                        Text(
                          'Telegram-style inbox',
                          style: TextStyle(
                            color: Color(0xFF97A0B6),
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Toggle tools',
                    onPressed: () =>
                        setState(() => _showChatTools = !_showChatTools),
                    icon: Icon(
                      _showChatTools
                          ? Icons.edit_note_rounded
                          : Icons.add_comment_outlined,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Refresh chats',
                    onPressed: _loadChats,
                    icon: _loading
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.refresh_rounded),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _chatSearchController,
                onChanged: (value) => setState(() => _chatQuery = value),
                decoration: const InputDecoration(
                  hintText: 'Search chats, people, messages',
                  prefixIcon: Icon(Icons.search_rounded),
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () =>
                          setState(() => _showChatTools = !_showChatTools),
                      icon: const Icon(Icons.group_add_outlined),
                      label: Text(_showChatTools ? 'Hide tools' : 'New chat'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      color: const Color(0xFF1A2130),
                      border: Border.all(color: const Color(0xFF30394A)),
                    ),
                    child: Icon(
                      _realtimeEnabled
                          ? Icons.bolt_rounded
                          : Icons.bolt_outlined,
                      color: _realtimeEnabled
                          ? theme.colorScheme.primary
                          : const Color(0xFF6F7688),
                      size: 20,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              SizedBox(
                height: 36,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemBuilder: (context, index) {
                    final (key, label) = folderTabs[index];
                    final selected = _chatFilter == key;
                    return ChoiceChip(
                      selected: selected,
                      onSelected: (_) => setState(() => _chatFilter = key),
                      label: Text(label),
                      labelStyle: TextStyle(
                        color: selected
                            ? const Color(0xFFF1D9FF)
                            : const Color(0xFFB3BACB),
                        fontWeight: selected
                            ? FontWeight.w700
                            : FontWeight.w500,
                      ),
                      selectedColor: const Color(0xFF4A2C66),
                      backgroundColor: const Color(0xFF1D2330),
                      side: BorderSide(
                        color: selected
                            ? const Color(0xFF8F59C6)
                            : const Color(0xFF303748),
                      ),
                    );
                  },
                  separatorBuilder: (_, _) => const SizedBox(width: 8),
                  itemCount: folderTabs.length,
                ),
              ),
            ],
          ),
        ),
        if (_showChatTools) ...[
          const SizedBox(height: 10),
          _buildChatTools(context),
        ],
        const SizedBox(height: 10),
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              color: const Color(0xFF11151D),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: const Color(0xFF242B38)),
            ),
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 2),
            child: _buildChatList(context),
          ),
        ),
      ],
    );

    final threadPane = Column(
      children: [
        if (!wide)
          Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
            decoration: BoxDecoration(
              color: const Color(0xFF151A24),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0xFF262D3A)),
            ),
            child: Row(
              children: [
                IconButton(
                  onPressed: () => setState(() => _mobileThreadOpen = false),
                  icon: const Icon(Icons.arrow_back_rounded),
                ),
                CircleAvatar(
                  radius: 18,
                  backgroundColor: const Color(0xFF3A2D57),
                  child: Text(
                    activeTitle.isNotEmpty ? activeTitle[0].toUpperCase() : '?',
                    style: const TextStyle(color: Colors.white),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        activeTitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      Text(
                        activeSubtitle,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: const Color(0xFF8F95AA),
                        ),
                      ),
                    ],
                  ),
                ),
                PopupMenuButton<String>(
                  color: const Color(0xFF1A1F2A),
                  itemBuilder: (context) => const [
                    PopupMenuItem(value: 'clear', child: Text('Close chat')),
                  ],
                  onSelected: (value) {
                    if (value == 'clear') {
                      setState(() => _mobileThreadOpen = false);
                    }
                  },
                ),
              ],
            ),
          ),
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              color: const Color(0xFF0C0F15),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: const Color(0xFF242B38)),
            ),
            padding: const EdgeInsets.all(10),
            child: _buildThread(context),
          ),
        ),
      ],
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      child: wide
          ? Row(
              children: [
                Expanded(flex: 42, child: listPane),
                const SizedBox(width: 10),
                Expanded(flex: 58, child: threadPane),
              ],
            )
          : (showThreadOnly ? threadPane : listPane),
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
                  decoration: const InputDecoration(
                    labelText: 'Share an update',
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    DropdownButton<String>(
                      value: _visibility,
                      onChanged: (value) =>
                          setState(() => _visibility = value ?? 'public'),
                      items: const [
                        DropdownMenuItem(
                          value: 'public',
                          child: Text('public'),
                        ),
                        DropdownMenuItem(
                          value: 'followers',
                          child: Text('followers'),
                        ),
                        DropdownMenuItem(
                          value: 'private',
                          child: Text('private'),
                        ),
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
                                'author ${post['author_id']} вЂў ${post['visibility']}',
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

class ContactsPage extends StatefulWidget {
  final ApiClient api;
  const ContactsPage({super.key, required this.api});

  @override
  State<ContactsPage> createState() => _ContactsPageState();
}

class _ContactsPageState extends State<ContactsPage> {
  final _queryController = TextEditingController();
  final _uidController = TextEditingController();
  bool _loading = false;
  List<Map<String, dynamic>> _results = [];
  Map<String, dynamic>? _uidResult;

  @override
  void dispose() {
    _queryController.dispose();
    _uidController.dispose();
    super.dispose();
  }

  void _show(Object message) {
    if (!mounted) return;
    final text = message is ApiException ? message.message : message.toString();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _searchUsers() async {
    final query = _queryController.text.trim();
    if (query.length < 2) return;
    setState(() => _loading = true);
    try {
      final found = await widget.api.searchUsers(query);
      setState(() => _results = found);
    } catch (error) {
      _show(error);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _findByUid() async {
    final uid = _uidController.text.trim();
    if (uid.isEmpty) return;
    setState(() => _loading = true);
    try {
      final user = await widget.api.userByUid(uid);
      setState(() => _uidResult = user);
    } catch (error) {
      _show(error);
      setState(() => _uidResult = null);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _startPrivateChat(int userId, String username) async {
    if (userId <= 0) return;
    try {
      await widget.api.createChat(title: username, memberIds: [userId]);
      _show('Chat created');
    } catch (error) {
      _show(error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFF151A24),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: const Color(0xFF262D3A)),
            ),
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _queryController,
                        onSubmitted: (_) => _searchUsers(),
                        decoration: const InputDecoration(
                          hintText: 'Search contacts',
                          prefixIcon: Icon(Icons.search_rounded),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: _loading ? null : _searchUsers,
                      child: const Text('Search'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _uidController,
                        onSubmitted: (_) => _findByUid(),
                        decoration: const InputDecoration(
                          hintText: 'Find by UID',
                          prefixIcon: Icon(Icons.alternate_email_rounded),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton(
                      onPressed: _loading ? null : _findByUid,
                      child: const Text('Open'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (_uidResult != null) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xFF171C26),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: const Color(0xFF293040)),
              ),
              child: Row(
                children: [
                  CircleAvatar(
                    backgroundColor: const Color(0xFF3342AA),
                    child: Text(() {
                      final value = _uidResult!['username']?.toString() ?? '?';
                      return value.isEmpty ? '?' : value[0].toUpperCase();
                    }()),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '${_uidResult!['username']} (@${_uidResult!['uid'] ?? '-'})',
                    ),
                  ),
                  FilledButton(
                    onPressed: () => _startPrivateChat(
                      _asInt(_uidResult!['id']) ?? 0,
                      _uidResult!['username']?.toString() ?? 'Direct chat',
                    ),
                    child: const Text('Message'),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 10),
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: const Color(0xFF11151D),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: const Color(0xFF242B38)),
              ),
              child: _loading && _results.isEmpty
                  ? const Center(child: CircularProgressIndicator())
                  : _results.isEmpty
                  ? Center(
                      child: Text(
                        'Search users to display contacts',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: const Color(0xFF9EA5B8),
                        ),
                      ),
                    )
                  : ListView.builder(
                      itemCount: _results.length,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 8,
                      ),
                      itemBuilder: (context, index) {
                        final user = _results[index];
                        final userId = _asInt(user['id']) ?? 0;
                        final username = user['username']?.toString() ?? 'User';
                        final uid = user['uid']?.toString() ?? '-';
                        return ListTile(
                          leading: CircleAvatar(
                            backgroundColor: const Color(0xFF3342AA),
                            child: Text(
                              username.isNotEmpty
                                  ? username[0].toUpperCase()
                                  : '?',
                            ),
                          ),
                          title: Text(username),
                          subtitle: Text('@$uid'),
                          trailing: FilledButton(
                            onPressed: () =>
                                _startPrivateChat(userId, username),
                            child: const Text('Chat'),
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

class ProfilePage extends StatefulWidget {
  final ApiClient api;
  const ProfilePage({super.key, required this.api});

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  final _uidController = TextEditingController();
  final _bioController = TextEditingController();
  bool _loading = false;
  Map<String, dynamic>? _profile;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _uidController.dispose();
    _bioController.dispose();
    super.dispose();
  }

  void _show(Object message) {
    if (!mounted) return;
    final text = message is ApiException ? message.message : message.toString();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final me = await widget.api.me();
      _uidController.text = me['uid']?.toString() ?? '';
      _bioController.text = me['bio']?.toString() ?? '';
      setState(() => _profile = me);
    } catch (error) {
      _show(error);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _save() async {
    setState(() => _loading = true);
    try {
      final updated = await widget.api.updateProfile(
        uid: _uidController.text.trim().isEmpty
            ? null
            : _uidController.text.trim(),
        bio: _bioController.text.trim(),
      );
      setState(() => _profile = updated);
      _show('Profile updated');
    } catch (error) {
      _show(error);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final profile = _profile;
    final username = profile?['username']?.toString() ?? 'User';
    final uid = profile?['uid']?.toString() ?? '';
    final id = _asInt(profile?['id']);
    final bio = profile?['bio']?.toString() ?? '';
    final phone = profile?['phone']?.toString() ?? '+7 (000) 000-00-00';
    final status = (_loading && profile != null) ? 'updating...' : 'online';

    Widget actionButton({
      required IconData icon,
      required String label,
      required VoidCallback onPressed,
    }) {
      return Expanded(
        child: OutlinedButton.icon(
          onPressed: onPressed,
          icon: Icon(icon, size: 18),
          label: Text(label),
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 12),
          ),
        ),
      );
    }

    Widget infoRow(String label, String value) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(value, style: theme.textTheme.titleLarge),
            const SizedBox(height: 2),
            Text(label, style: const TextStyle(color: Color(0xFF8A92A7))),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      child: _loading && profile == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                Container(
                  padding: const EdgeInsets.fromLTRB(16, 20, 16, 16),
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [Color(0xFF42556A), Color(0xFF303A47)],
                    ),
                    borderRadius: BorderRadius.circular(22),
                    border: Border.all(color: const Color(0xFF4A566A)),
                  ),
                  child: Column(
                    children: [
                      CircleAvatar(
                        radius: 46,
                        backgroundColor: const Color(0xFF9553E8),
                        child: Text(
                          username.isNotEmpty ? username[0].toUpperCase() : '?',
                          style: const TextStyle(
                            fontSize: 30,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        username,
                        style: const TextStyle(
                          fontSize: 36,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        uid.isEmpty ? '@user$id' : '@$uid',
                        style: const TextStyle(color: Color(0xFFD3DAE8)),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        status,
                        style: const TextStyle(color: Color(0xFFB9E8C1)),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    actionButton(
                      icon: Icons.add_a_photo_outlined,
                      label: 'Photo',
                      onPressed: () =>
                          _show('Avatar upload will be added next'),
                    ),
                    const SizedBox(width: 8),
                    actionButton(
                      icon: Icons.edit_outlined,
                      label: 'Edit',
                      onPressed: () => _show('Edit mode enabled below'),
                    ),
                    const SizedBox(width: 8),
                    actionButton(
                      icon: Icons.settings_outlined,
                      label: 'Settings',
                      onPressed: () =>
                          _show('Open Settings tab for full controls'),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: const Color(0xFF151A24),
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: const Color(0xFF262D3A)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      infoRow('Phone', phone),
                      infoRow('About', bio.isEmpty ? 'No bio yet' : bio),
                      infoRow('Username', uid.isEmpty ? 'not set' : '@$uid'),
                      infoRow('User ID', id == null ? 'unknown' : '$id'),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF151A24),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: const Color(0xFF262D3A)),
                  ),
                  child: Column(
                    children: [
                      TextField(
                        controller: _uidController,
                        decoration: const InputDecoration(
                          labelText: 'Username UID',
                          prefixIcon: Icon(Icons.alternate_email_rounded),
                        ),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: _bioController,
                        minLines: 3,
                        maxLines: 5,
                        decoration: const InputDecoration(
                          labelText: 'About',
                          prefixIcon: Icon(Icons.info_outline_rounded),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          FilledButton.icon(
                            onPressed: _loading ? null : _save,
                            icon: const Icon(Icons.save_outlined),
                            label: const Text('Save'),
                          ),
                          const SizedBox(width: 8),
                          OutlinedButton.icon(
                            onPressed: _loading ? null : _load,
                            icon: const Icon(Icons.refresh_rounded),
                            label: const Text('Reload'),
                          ),
                        ],
                      ),
                    ],
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
    final text = message is ApiException ? message.message : message.toString();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Color? _parseAccentColor(String raw) {
    final normalized = raw.trim().replaceAll('#', '');
    if (normalized.length != 6 && normalized.length != 8) return null;
    final prefixed = normalized.length == 6 ? 'FF$normalized' : normalized;
    final value = int.tryParse(prefixed, radix: 16);
    if (value == null) return null;
    return Color(value);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accentPreview = _parseAccentColor(_accentController.text);

    Widget sectionCard(Widget child) {
      return Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: const Color(0xFF151A24),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: const Color(0xFF262D3A)),
        ),
        child: child,
      );
    }

    Widget settingsTile({
      required IconData icon,
      required Color color,
      required String title,
      required String subtitle,
    }) {
      return ListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        leading: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, color: Colors.white, size: 19),
        ),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(
          subtitle,
          style: const TextStyle(color: Color(0xFF9098AC)),
        ),
        trailing: const Icon(
          Icons.chevron_right_rounded,
          color: Color(0xFF7F879A),
        ),
        onTap: () => _show('$title screen is coming soon'),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      child: _loading && _settings == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                sectionCard(
                  Row(
                    children: [
                      const CircleAvatar(
                        radius: 30,
                        backgroundColor: Color(0xFF9553E8),
                        child: Icon(Icons.settings_rounded, size: 28),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Settings',
                              style: theme.textTheme.headlineSmall?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const Text(
                              'Chats, privacy, devices, updates',
                              style: TextStyle(color: Color(0xFF9FA7BA)),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                sectionCard(
                  Column(
                    children: [
                      settingsTile(
                        icon: Icons.person_outline_rounded,
                        color: const Color(0xFF2A89F5),
                        title: 'Account',
                        subtitle: 'Phone, username, bio',
                      ),
                      settingsTile(
                        icon: Icons.chat_bubble_outline_rounded,
                        color: const Color(0xFFF2A323),
                        title: 'Chat settings',
                        subtitle: 'Theme, wallpaper, animations',
                      ),
                      settingsTile(
                        icon: Icons.lock_outline_rounded,
                        color: const Color(0xFF37B24A),
                        title: 'Privacy',
                        subtitle: 'Sessions, key access, visibility',
                      ),
                      settingsTile(
                        icon: Icons.notifications_none_rounded,
                        color: const Color(0xFFE6465F),
                        title: 'Notifications',
                        subtitle: 'Sounds, badges, message alerts',
                      ),
                      settingsTile(
                        icon: Icons.folder_outlined,
                        color: const Color(0xFF2A8DE0),
                        title: 'Chat folders',
                        subtitle: 'Sort chats by custom tabs',
                      ),
                      settingsTile(
                        icon: Icons.devices_outlined,
                        color: const Color(0xFF45A8C4),
                        title: 'Devices',
                        subtitle: 'Manage active sessions',
                      ),
                      settingsTile(
                        icon: Icons.battery_saver_outlined,
                        color: const Color(0xFFF48D2B),
                        title: 'Power saving',
                        subtitle: 'Reduce background activity',
                      ),
                      settingsTile(
                        icon: Icons.language_rounded,
                        color: const Color(0xFF9D62F7),
                        title: 'Language',
                        subtitle: 'Russian',
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                sectionCard(
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Appearance and profile',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: _uidController,
                        decoration: const InputDecoration(
                          labelText: 'Username UID',
                          prefixIcon: Icon(Icons.alternate_email_rounded),
                        ),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: _themeController,
                        onChanged: (_) => setState(() {}),
                        decoration: const InputDecoration(
                          labelText: 'Theme name',
                          prefixIcon: Icon(Icons.brush_outlined),
                        ),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: _accentController,
                        onChanged: (_) => setState(() {}),
                        decoration: InputDecoration(
                          labelText: 'Accent color (#B35DFF)',
                          prefixIcon: const Icon(Icons.palette_outlined),
                          suffixIcon: accentPreview == null
                              ? null
                              : Container(
                                  width: 18,
                                  height: 18,
                                  margin: const EdgeInsets.all(12),
                                  decoration: BoxDecoration(
                                    color: accentPreview,
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          FilledButton.icon(
                            onPressed: _loading ? null : _save,
                            icon: const Icon(Icons.save_outlined),
                            label: const Text('Save'),
                          ),
                          const SizedBox(width: 8),
                          OutlinedButton.icon(
                            onPressed: _loading ? null : _load,
                            icon: const Icon(Icons.refresh_rounded),
                            label: const Text('Reload'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                sectionCard(
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'App updates',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 10),
                      DropdownButtonFormField<String>(
                        initialValue: _updateChannel,
                        decoration: const InputDecoration(
                          labelText: 'Update channel',
                        ),
                        items: const [
                          DropdownMenuItem(
                            value: 'stable',
                            child: Text('stable'),
                          ),
                          DropdownMenuItem(value: 'beta', child: Text('beta')),
                        ],
                        onChanged: (value) {
                          if (value == null) return;
                          setState(() => _updateChannel = value);
                        },
                      ),
                      const SizedBox(height: 6),
                      SwitchListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Auto-check updates on startup'),
                        value: _autoUpdateCheck,
                        onChanged: (value) =>
                            setState(() => _autoUpdateCheck = value),
                      ),
                      SwitchListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Show update notifications'),
                        value: _updateNotifications,
                        onChanged: (value) =>
                            setState(() => _updateNotifications = value),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                sectionCard(
                  Theme(
                    data: theme.copyWith(dividerColor: Colors.transparent),
                    child: ExpansionTile(
                      tilePadding: EdgeInsets.zero,
                      childrenPadding: EdgeInsets.zero,
                      title: const Text('Advanced payload'),
                      subtitle: const Text(
                        'Server customization JSON',
                        style: TextStyle(color: Color(0xFF8F97AB)),
                      ),
                      children: [
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: const Color(0xFF11151D),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: const Color(0xFF283040)),
                          ),
                          child: SelectableText(
                            const JsonEncoder.withIndent(
                              '  ',
                            ).convert(_settings ?? {}),
                            style: theme.textTheme.bodySmall,
                          ),
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
      child: Padding(padding: padding, child: child),
    );
  }
}
