import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'models.dart';

const String kDefaultApiBaseUrl = String.fromEnvironment(
  'ASTRALINK_API_BASE_URL',
  defaultValue: 'https://volds.ru',
);

class ApiException implements Exception {
  final String message;
  final int? statusCode;

  const ApiException(this.message, {this.statusCode});

  @override
  String toString() => message;
}

String normalizeBaseUrl(String input) {
  final trimmed = input.trim();
  if (trimmed.isEmpty) return kDefaultApiBaseUrl;
  return trimmed.endsWith('/')
      ? trimmed.substring(0, trimmed.length - 1)
      : trimmed;
}

String webSocketBase(String baseUrl) {
  if (baseUrl.startsWith('https://')) {
    return 'wss://${baseUrl.substring(8)}';
  }
  if (baseUrl.startsWith('http://')) {
    return 'ws://${baseUrl.substring(7)}';
  }
  return 'wss://$baseUrl';
}

String resolveApiUrl(String baseUrl, String pathOrUrl) {
  final trimmed = pathOrUrl.trim();
  if (trimmed.isEmpty) return normalizeBaseUrl(baseUrl);
  final parsed = Uri.tryParse(trimmed);
  if (parsed != null && parsed.hasScheme) return trimmed;

  final normalizedBase = normalizeBaseUrl(baseUrl);
  if (trimmed.startsWith('/')) {
    return '$normalizedBase$trimmed';
  }
  return '$normalizedBase/$trimmed';
}

String normalizePublicUsername(String value) {
  return value.trim().replaceFirst(RegExp(r'^@+'), '').toLowerCase();
}

String? publicProfileUsernameFromUri(Uri uri) {
  final pathSegments = uri.pathSegments
      .where((segment) => segment.isNotEmpty)
      .toList();
  if (uri.scheme == 'astralink') {
    if (uri.host.toLowerCase() == 'u' && pathSegments.isNotEmpty) {
      final username = normalizePublicUsername(pathSegments.first);
      return username.isEmpty ? null : username;
    }
    if (pathSegments.length >= 2 && pathSegments.first.toLowerCase() == 'u') {
      final username = normalizePublicUsername(pathSegments[1]);
      return username.isEmpty ? null : username;
    }
    return null;
  }

  if ((uri.scheme == 'https' || uri.scheme == 'http') &&
      pathSegments.length >= 2 &&
      pathSegments.first.toLowerCase() == 'u') {
    final username = normalizePublicUsername(pathSegments[1]);
    return username.isEmpty ? null : username;
  }
  return null;
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

typedef RefreshTokenHandler = Future<AuthTokens?> Function(String refreshToken);

class AstraApi {
  final String baseUrl;
  final RefreshTokenHandler? onRefreshToken;

  const AstraApi({required this.baseUrl, this.onRefreshToken});

  String publicProfileUrl(String username) {
    final normalized = normalizePublicUsername(username);
    final uri = Uri.parse(baseUrl);
    return uri
        .replace(path: '/u/$normalized', queryParameters: null, fragment: null)
        .toString();
  }

  String resolveUrl(String pathOrUrl) {
    return resolveApiUrl(baseUrl, pathOrUrl);
  }

  Future<PhoneCodeSession> requestPhoneCode(String phone) async {
    final response = await _request(
      'POST',
      '/api/auth/request-code',
      body: {'phone': phone},
    );
    return PhoneCodeSession.fromJson(_jsonMap(response));
  }

  Future<AuthResult> verifyPhoneCode({
    required String phone,
    required String codeToken,
    required String code,
    String? firstName,
    String? lastName,
  }) async {
    final payload = <String, dynamic>{
      'phone': phone,
      'code_token': codeToken,
      'code': code,
    };
    if (firstName != null && firstName.trim().isNotEmpty) {
      payload['first_name'] = firstName.trim();
    }
    if (lastName != null && lastName.trim().isNotEmpty) {
      payload['last_name'] = lastName.trim();
    }

    final response = await _request(
      'POST',
      '/api/auth/verify-code',
      body: payload,
    );
    final json = _jsonMap(response);
    return _authResultFromJson(json);
  }

  Future<AuthResult> refreshSession(String refreshToken) async {
    final response = await _request(
      'POST',
      '/api/auth/refresh',
      body: {'refresh_token': refreshToken},
    );
    return _authResultFromJson(_jsonMap(response));
  }

  Future<AppUser> me({
    required String accessToken,
    String? refreshToken,
  }) async {
    final response = await _authorizedRequest(
      'GET',
      '/api/users/me',
      accessToken: accessToken,
      refreshToken: refreshToken,
    );
    return AppUser.fromJson(_jsonMap(response));
  }

  Future<AppUser> updateMe({
    required String accessToken,
    String? refreshToken,
    String? username,
    String? firstName,
    String? lastName,
    String? bio,
  }) async {
    final payload = <String, dynamic>{};
    if (username != null) payload['username'] = username;
    if (firstName != null) payload['first_name'] = firstName;
    if (lastName != null) payload['last_name'] = lastName;
    if (bio != null) payload['bio'] = bio;

    final response = await _authorizedRequest(
      'PATCH',
      '/api/users/me',
      accessToken: accessToken,
      refreshToken: refreshToken,
      body: payload,
    );
    return AppUser.fromJson(_jsonMap(response));
  }

  Future<UsernameCheckResult> checkUsername({
    required String accessToken,
    String? refreshToken,
    required String username,
  }) async {
    final response = await _authorizedRequest(
      'GET',
      '/api/users/username-check?username=${Uri.encodeQueryComponent(username)}',
      accessToken: accessToken,
      refreshToken: refreshToken,
    );
    return UsernameCheckResult.fromJson(_jsonMap(response));
  }

  Future<List<ChatItem>> listChats({
    required String accessToken,
    String? refreshToken,
    bool includeArchived = false,
    bool archivedOnly = false,
    bool pinnedOnly = false,
    String? folder,
  }) async {
    final params = <String, String>{
      if (includeArchived) 'include_archived': 'true',
      if (archivedOnly) 'archived_only': 'true',
      if (pinnedOnly) 'pinned_only': 'true',
      if (folder != null && folder.trim().isNotEmpty) 'folder': folder.trim(),
    };
    final query = params.entries
        .map(
          (entry) =>
              '${Uri.encodeQueryComponent(entry.key)}=${Uri.encodeQueryComponent(entry.value)}',
        )
        .join('&');
    final response = await _authorizedRequest(
      'GET',
      '/api/chats${query.isEmpty ? '' : '?$query'}',
      accessToken: accessToken,
      refreshToken: refreshToken,
    );
    return _jsonList(response).map((item) => ChatItem.fromJson(item)).toList();
  }

  Future<ChatItem> openPrivateChat({
    required String accessToken,
    String? refreshToken,
    required String query,
  }) async {
    final encodedQuery = Uri.encodeQueryComponent(query);
    final response = await _authorizedRequest(
      'POST',
      '/api/chats/private?query=$encodedQuery',
      accessToken: accessToken,
      refreshToken: refreshToken,
    );
    return ChatItem.fromJson(_jsonMap(response));
  }

  Future<List<MessageItem>> listMessages({
    required String accessToken,
    String? refreshToken,
    required int chatId,
    int limit = 100,
  }) async {
    final response = await _authorizedRequest(
      'GET',
      '/api/chats/$chatId/messages?limit=$limit',
      accessToken: accessToken,
      refreshToken: refreshToken,
    );
    return _jsonList(
      response,
    ).map((item) => MessageItem.fromJson(item)).toList();
  }

  Future<MessageCursorPage> listMessagesCursor({
    required String accessToken,
    String? refreshToken,
    required int chatId,
    int limit = 50,
    int? beforeId,
  }) async {
    final query = StringBuffer('limit=$limit');
    if (beforeId != null) {
      query.write('&before_id=$beforeId');
    }
    final response = await _authorizedRequest(
      'GET',
      '/api/chats/$chatId/messages/cursor?$query',
      accessToken: accessToken,
      refreshToken: refreshToken,
    );
    return MessageCursorPage.fromJson(_jsonMap(response));
  }

  Future<void> updateChatState({
    required String accessToken,
    String? refreshToken,
    required int chatId,
    bool? isArchived,
    bool? isPinned,
    String? folder,
  }) async {
    final payload = <String, dynamic>{};
    if (isArchived != null) payload['is_archived'] = isArchived;
    if (isPinned != null) payload['is_pinned'] = isPinned;
    if (folder != null) payload['folder'] = folder;

    await _authorizedRequest(
      'PATCH',
      '/api/chats/$chatId/state',
      accessToken: accessToken,
      refreshToken: refreshToken,
      body: payload,
    );
  }

  Future<MessageItem> sendMessage({
    required String accessToken,
    String? refreshToken,
    required int chatId,
    required String content,
    int? replyToMessageId,
    List<int> attachmentIds = const [],
  }) async {
    final payload = <String, dynamic>{'content': content};
    if (replyToMessageId != null) {
      payload['reply_to_message_id'] = replyToMessageId;
    }
    if (attachmentIds.isNotEmpty) {
      payload['attachment_ids'] = attachmentIds;
    }
    final response = await _authorizedRequest(
      'POST',
      '/api/chats/$chatId/messages',
      accessToken: accessToken,
      refreshToken: refreshToken,
      body: payload,
    );
    return MessageItem.fromJson(_jsonMap(response));
  }

  Future<MessageItem> updateMessage({
    required String accessToken,
    String? refreshToken,
    required int messageId,
    required String content,
  }) async {
    final response = await _authorizedRequest(
      'PATCH',
      '/api/chats/messages/$messageId',
      accessToken: accessToken,
      refreshToken: refreshToken,
      body: {'content': content},
    );
    return MessageItem.fromJson(_jsonMap(response));
  }

  Future<bool> deleteMessage({
    required String accessToken,
    String? refreshToken,
    required int messageId,
  }) async {
    final response = await _authorizedRequest(
      'DELETE',
      '/api/chats/messages/$messageId',
      accessToken: accessToken,
      refreshToken: refreshToken,
    );
    final json = _jsonMap(response);
    return (json['removed'] ?? false) == true;
  }

  Future<void> pinMessage({
    required String accessToken,
    String? refreshToken,
    required int chatId,
    required int messageId,
  }) async {
    await _authorizedRequest(
      'POST',
      '/api/chats/$chatId/messages/$messageId/pin',
      accessToken: accessToken,
      refreshToken: refreshToken,
    );
  }

  Future<void> unpinMessage({
    required String accessToken,
    String? refreshToken,
    required int chatId,
    required int messageId,
  }) async {
    await _authorizedRequest(
      'DELETE',
      '/api/chats/$chatId/messages/$messageId/pin',
      accessToken: accessToken,
      refreshToken: refreshToken,
    );
  }

  Future<MessageAttachmentItem> uploadChatMedia({
    required String accessToken,
    String? refreshToken,
    required int chatId,
    required String fileName,
    String? filePath,
    Uint8List? bytes,
  }) async {
    final firstTry = await _uploadChatMediaRequest(
      accessToken: accessToken,
      chatId: chatId,
      fileName: fileName,
      filePath: filePath,
      bytes: bytes,
    );
    if (firstTry.statusCode != 401) {
      return MessageAttachmentItem.fromJson(_jsonMap(firstTry));
    }

    if (refreshToken == null ||
        refreshToken.isEmpty ||
        onRefreshToken == null) {
      throw const ApiException('Session expired', statusCode: 401);
    }

    final nextTokens = await onRefreshToken!.call(refreshToken);
    if (nextTokens == null) {
      throw const ApiException('Session expired', statusCode: 401);
    }

    final retried = await _uploadChatMediaRequest(
      accessToken: nextTokens.accessToken,
      chatId: chatId,
      fileName: fileName,
      filePath: filePath,
      bytes: bytes,
    );
    return MessageAttachmentItem.fromJson(_jsonMap(retried));
  }

  Future<List<AppUser>> searchUsers({
    required String accessToken,
    String? refreshToken,
    required String query,
  }) async {
    final response = await _authorizedRequest(
      'GET',
      '/api/users/search?q=${Uri.encodeQueryComponent(query)}',
      accessToken: accessToken,
      refreshToken: refreshToken,
    );
    return _jsonList(response).map((item) => AppUser.fromJson(item)).toList();
  }

  Future<AppUser> lookupUser({
    required String accessToken,
    String? refreshToken,
    required String query,
  }) async {
    final response = await _authorizedRequest(
      'GET',
      '/api/users/lookup?q=${Uri.encodeQueryComponent(query)}',
      accessToken: accessToken,
      refreshToken: refreshToken,
    );
    return AppUser.fromJson(_jsonMap(response));
  }

  Future<AppUser> publicProfile(String username) async {
    final response = await _request(
      'GET',
      '/api/public/users/${Uri.encodeComponent(normalizePublicUsername(username))}',
    );
    return AppUser.fromJson(_jsonMap(response));
  }

  Future<List<MessageSearchHit>> searchMessages({
    required String accessToken,
    String? refreshToken,
    required String query,
    int limit = 30,
  }) async {
    final response = await _authorizedRequest(
      'GET',
      '/api/chats/messages/search?q=${Uri.encodeQueryComponent(query)}&limit=$limit',
      accessToken: accessToken,
      refreshToken: refreshToken,
    );
    return _jsonList(
      response,
    ).map((item) => MessageSearchHit.fromJson(item)).toList();
  }

  Future<ReleaseInfo?> latestRelease({
    required String platform,
    required String channel,
  }) async {
    final response = await _request(
      'GET',
      '/api/releases/latest/$platform?channel=${Uri.encodeQueryComponent(channel)}',
      allowedStatusCodes: {404},
    );
    if (response.statusCode == 404) return null;
    return ReleaseInfo.fromJson(_jsonMap(response));
  }

  Future<http.Response> _authorizedRequest(
    String method,
    String path, {
    required String accessToken,
    String? refreshToken,
    Map<String, dynamic>? body,
  }) async {
    final firstTry = await _request(
      method,
      path,
      body: body,
      headers: {'Authorization': 'Bearer $accessToken'},
      allowedStatusCodes: {401},
    );
    if (firstTry.statusCode != 401) return firstTry;

    if (refreshToken == null ||
        refreshToken.isEmpty ||
        onRefreshToken == null) {
      throw const ApiException('Session expired', statusCode: 401);
    }

    final nextTokens = await onRefreshToken!.call(refreshToken);
    if (nextTokens == null) {
      throw const ApiException('Session expired', statusCode: 401);
    }

    return _request(
      method,
      path,
      body: body,
      headers: {'Authorization': 'Bearer ${nextTokens.accessToken}'},
    );
  }

  Future<http.Response> _uploadChatMediaRequest({
    required String accessToken,
    required int chatId,
    required String fileName,
    String? filePath,
    Uint8List? bytes,
  }) async {
    http.MultipartFile multipartFile;
    if (!kIsWeb && filePath != null && filePath.trim().isNotEmpty) {
      multipartFile = await http.MultipartFile.fromPath(
        'file',
        filePath,
        filename: fileName,
      );
    } else if (bytes != null) {
      multipartFile = http.MultipartFile.fromBytes(
        'file',
        bytes,
        filename: fileName,
      );
    } else {
      throw const ApiException('Selected file is unavailable');
    }

    final request = http.MultipartRequest(
      'POST',
      Uri.parse('$baseUrl/api/media/upload?chat_id=$chatId'),
    )
      ..headers['Accept'] = 'application/json'
      ..headers['Authorization'] = 'Bearer $accessToken'
      ..files.add(multipartFile);

    final streamed = await request.send();
    final response = await http.Response.fromStream(streamed);
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return response;
    }
    if (response.statusCode == 401) {
      return response;
    }
    throw ApiException(
      _extractErrorMessage(response),
      statusCode: response.statusCode,
    );
  }

  Future<http.Response> _request(
    String method,
    String path, {
    Map<String, dynamic>? body,
    Map<String, String>? headers,
    Set<int> allowedStatusCodes = const {},
  }) async {
    final uri = Uri.parse('$baseUrl$path');
    final mergedHeaders = <String, String>{
      'Accept': 'application/json',
      if (body != null) 'Content-Type': 'application/json',
      ...?headers,
    };

    late http.Response response;
    switch (method) {
      case 'GET':
        response = await http.get(uri, headers: mergedHeaders);
        break;
      case 'POST':
        response = await http.post(
          uri,
          headers: mergedHeaders,
          body: body == null ? null : jsonEncode(body),
        );
        break;
      case 'PATCH':
        response = await http.patch(
          uri,
          headers: mergedHeaders,
          body: body == null ? null : jsonEncode(body),
        );
        break;
      case 'DELETE':
        response = await http.delete(
          uri,
          headers: mergedHeaders,
          body: body == null ? null : jsonEncode(body),
        );
        break;
      default:
        throw ApiException('Unsupported method: $method');
    }

    if (response.statusCode >= 200 && response.statusCode < 300) {
      return response;
    }
    if (allowedStatusCodes.contains(response.statusCode)) {
      return response;
    }

    throw ApiException(
      _extractErrorMessage(response),
      statusCode: response.statusCode,
    );
  }

  AuthResult _authResultFromJson(Map<String, dynamic> json) {
    return AuthResult(
      tokens: AuthTokens(
        accessToken: (json['access_token'] ?? '').toString(),
        refreshToken: (json['refresh_token'] ?? '').toString(),
      ),
      needsProfileSetup: (json['needs_profile_setup'] ?? false) == true,
      user: AppUser.fromJson((json['user'] as Map).cast<String, dynamic>()),
    );
  }

  Map<String, dynamic> _jsonMap(http.Response response) {
    final decoded = jsonDecode(response.body);
    if (decoded is Map<String, dynamic>) return decoded;
    if (decoded is Map) return decoded.cast<String, dynamic>();
    throw const ApiException('Invalid API response');
  }

  List<Map<String, dynamic>> _jsonList(http.Response response) {
    final decoded = jsonDecode(response.body);
    if (decoded is! List) {
      throw const ApiException('Invalid API response');
    }
    return decoded
        .map((item) => (item as Map).cast<String, dynamic>())
        .toList();
  }

  String _extractErrorMessage(http.Response response) {
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) {
        final detail = decoded['detail'];
        if (detail is String && detail.trim().isNotEmpty) return detail;
        if (detail is List && detail.isNotEmpty) {
          return detail.first.toString();
        }
      }
    } catch (_) {
      // ignore parse errors
    }

    if (response.statusCode == 404) return 'Not found';
    if (response.statusCode == 401) return 'Session expired';
    return 'Request failed (${response.statusCode})';
  }
}
