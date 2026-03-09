class AppUser {
  final int id;
  final String? username;
  final String? phone;
  final String firstName;
  final String lastName;
  final String bio;
  final String? avatarUrl;

  const AppUser({
    required this.id,
    required this.username,
    required this.phone,
    required this.firstName,
    required this.lastName,
    required this.bio,
    required this.avatarUrl,
  });

  String get displayName {
    final full = [
      firstName,
      lastName,
    ].where((part) => part.trim().isNotEmpty).join(' ').trim();
    if (full.isNotEmpty) return full;
    final handle = username?.trim();
    if (handle != null && handle.isNotEmpty) return handle;
    final phoneValue = phone?.trim();
    if (phoneValue != null && phoneValue.isNotEmpty) return phoneValue;
    return 'Unknown User';
  }

  bool get hasProfileName => firstName.trim().isNotEmpty;

  bool get usernameLooksGenerated {
    final normalized = (username ?? '').trim().toLowerCase();
    final digitsOnlyTail = normalized.replaceFirst(RegExp(r'^user'), '');
    return normalized.startsWith('user') &&
        digitsOnlyTail.isNotEmpty &&
        RegExp(r'^[0-9]+$').hasMatch(digitsOnlyTail);
  }

  String? get publicHandle {
    final value = username?.trim();
    if (value == null || value.isEmpty) return null;
    return '@$value';
  }

  factory AppUser.fromJson(Map<String, dynamic> json) {
    return AppUser(
      id: json['id'] as int,
      username: json['username']?.toString(),
      phone: json['phone']?.toString(),
      firstName: (json['first_name'] ?? '').toString(),
      lastName: (json['last_name'] ?? '').toString(),
      bio: (json['bio'] ?? '').toString(),
      avatarUrl: json['avatar_url']?.toString(),
    );
  }
}

class AuthTokens {
  final String accessToken;
  final String refreshToken;

  const AuthTokens({required this.accessToken, required this.refreshToken});
}

class AuthResult {
  final AuthTokens tokens;
  final AppUser user;
  final bool needsProfileSetup;

  const AuthResult({
    required this.tokens,
    required this.user,
    required this.needsProfileSetup,
  });
}

class PhoneCodeSession {
  final String phone;
  final String codeToken;
  final int expiresInSeconds;
  final bool isRegistered;

  const PhoneCodeSession({
    required this.phone,
    required this.codeToken,
    required this.expiresInSeconds,
    required this.isRegistered,
  });

  factory PhoneCodeSession.fromJson(Map<String, dynamic> json) {
    return PhoneCodeSession(
      phone: (json['phone'] ?? '').toString(),
      codeToken: (json['code_token'] ?? '').toString(),
      expiresInSeconds: (json['expires_in_seconds'] ?? 0) as int,
      isRegistered: (json['is_registered'] ?? false) as bool,
    );
  }
}

class UsernameCheckResult {
  final String username;
  final bool available;

  const UsernameCheckResult({required this.username, required this.available});

  factory UsernameCheckResult.fromJson(Map<String, dynamic> json) {
    return UsernameCheckResult(
      username: (json['username'] ?? '').toString(),
      available: (json['available'] ?? false) == true,
    );
  }
}

class ChatItem {
  final int id;
  final String title;
  final String type;
  final String? lastMessagePreview;
  final DateTime? lastMessageAt;
  final int unreadCount;
  final bool isArchived;
  final bool isPinned;
  final String? folder;

  const ChatItem({
    required this.id,
    required this.title,
    required this.type,
    required this.lastMessagePreview,
    required this.lastMessageAt,
    required this.unreadCount,
    required this.isArchived,
    required this.isPinned,
    required this.folder,
  });

  factory ChatItem.fromJson(Map<String, dynamic> json) {
    final rawDate = json['last_message_at']?.toString();
    return ChatItem(
      id: json['id'] as int,
      title: (json['title'] ?? '').toString(),
      type: (json['type'] ?? '').toString(),
      lastMessagePreview: json['last_message_preview']?.toString(),
      lastMessageAt: rawDate == null || rawDate.isEmpty
          ? null
          : DateTime.tryParse(rawDate),
      unreadCount: (json['unread_count'] ?? 0) as int,
      isArchived: (json['is_archived'] ?? false) as bool,
      isPinned: (json['is_pinned'] ?? false) as bool,
      folder: json['folder']?.toString(),
    );
  }
}

class MessageSearchHit {
  final int chatId;
  final int messageId;
  final String chatTitle;
  final int senderId;
  final String content;
  final DateTime createdAt;

  const MessageSearchHit({
    required this.chatId,
    required this.messageId,
    required this.chatTitle,
    required this.senderId,
    required this.content,
    required this.createdAt,
  });

  factory MessageSearchHit.fromJson(Map<String, dynamic> json) {
    return MessageSearchHit(
      chatId: json['chat_id'] as int,
      messageId: json['message_id'] as int,
      chatTitle: (json['chat_title'] ?? '').toString(),
      senderId: json['sender_id'] as int,
      content: (json['content'] ?? '').toString(),
      createdAt: DateTime.parse((json['created_at'] ?? '').toString()),
    );
  }
}

class MessageItem {
  final int id;
  final int chatId;
  final int senderId;
  final String content;
  final DateTime createdAt;
  final String status;
  final DateTime? editedAt;

  const MessageItem({
    required this.id,
    required this.chatId,
    required this.senderId,
    required this.content,
    required this.createdAt,
    required this.status,
    required this.editedAt,
  });

  factory MessageItem.fromJson(Map<String, dynamic> json) {
    return MessageItem(
      id: json['id'] as int,
      chatId: json['chat_id'] as int,
      senderId: json['sender_id'] as int,
      content: (json['content'] ?? '').toString(),
      createdAt: DateTime.parse((json['created_at'] ?? '').toString()),
      status: (json['status'] ?? 'sent').toString(),
      editedAt: json['edited_at'] == null
          ? null
          : DateTime.tryParse(json['edited_at'].toString()),
    );
  }
}

class ReleaseInfo {
  final String platform;
  final String channel;
  final String latestVersion;
  final String minimumSupportedVersion;
  final bool mandatory;
  final String downloadUrl;
  final String notes;

  const ReleaseInfo({
    required this.platform,
    required this.channel,
    required this.latestVersion,
    required this.minimumSupportedVersion,
    required this.mandatory,
    required this.downloadUrl,
    required this.notes,
  });

  factory ReleaseInfo.fromJson(Map<String, dynamic> json) {
    return ReleaseInfo(
      platform: (json['platform'] ?? '').toString(),
      channel: (json['channel'] ?? 'stable').toString(),
      latestVersion: (json['latest_version'] ?? '').toString(),
      minimumSupportedVersion: (json['minimum_supported_version'] ?? '')
          .toString(),
      mandatory: (json['mandatory'] ?? false) as bool,
      downloadUrl: (json['download_url'] ?? '').toString(),
      notes: (json['notes'] ?? '').toString(),
    );
  }
}
