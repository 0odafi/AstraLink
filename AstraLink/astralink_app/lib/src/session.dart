import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'models.dart';

class SessionSnapshot {
  final String baseUrl;
  final String? accessToken;
  final String? refreshToken;
  final String updateChannel;

  const SessionSnapshot({
    required this.baseUrl,
    required this.accessToken,
    required this.refreshToken,
    required this.updateChannel,
  });

  bool get isAuthenticated => accessToken != null && accessToken!.isNotEmpty;
}

class SessionStore {
  static const _kBaseUrl = 'astralink_base_url';
  static const _kAccessToken = 'astralink_access_token';
  static const _kRefreshToken = 'astralink_refresh_token';
  static const _kUpdateChannel = 'astralink_update_channel';

  Future<SessionSnapshot> load() async {
    final prefs = await SharedPreferences.getInstance();
    final baseUrl = normalizeBaseUrl(
      prefs.getString(_kBaseUrl) ?? kDefaultApiBaseUrl,
    );
    final accessToken = prefs.getString(_kAccessToken);
    final refreshToken = prefs.getString(_kRefreshToken);
    final updateChannel = prefs.getString(_kUpdateChannel) ?? 'stable';
    await prefs.setString(_kBaseUrl, baseUrl);

    return SessionSnapshot(
      baseUrl: baseUrl,
      accessToken: accessToken,
      refreshToken: refreshToken,
      updateChannel: updateChannel,
    );
  }

  Future<void> saveSession({
    required String baseUrl,
    required AuthTokens? tokens,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kBaseUrl, normalizeBaseUrl(baseUrl));
    if (tokens == null) {
      await prefs.remove(_kAccessToken);
      await prefs.remove(_kRefreshToken);
      return;
    }
    await prefs.setString(_kAccessToken, tokens.accessToken);
    await prefs.setString(_kRefreshToken, tokens.refreshToken);
  }

  Future<void> saveUpdateChannel(String channel) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kUpdateChannel, channel);
  }
}
