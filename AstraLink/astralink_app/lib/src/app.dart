import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'api.dart';
import 'core/ui/adaptive_size.dart';
import 'core/ui/app_theme.dart';
import 'features/auth/presentation/auth_screen.dart';
import 'features/home/presentation/home_shell.dart';
import 'features/settings/application/app_preferences.dart';
import 'models.dart';
import 'session.dart';

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
    return Consumer(
      builder: (context, ref, _) {
        final appearance = ref.watch(appPreferencesProvider).appearance;
        return MaterialApp(
          title: 'AstraLink',
          debugShowCheckedModeBanner: false,
          theme: buildAstraTheme(appearance),
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
      },
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
