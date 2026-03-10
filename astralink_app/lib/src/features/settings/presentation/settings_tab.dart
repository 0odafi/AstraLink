import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:open_file/open_file.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../api.dart';
import '../../../core/cache/attachment_cache.dart';
import '../../../core/ui/adaptive_size.dart';
import '../../../core/ui/app_appearance.dart';
import '../../../models.dart';
import '../application/app_preferences.dart';
import '../data/update_downloader.dart';

class SettingsTab extends ConsumerStatefulWidget {
  final AstraApi api;
  final AuthTokens? Function() getTokens;
  final String appVersion;
  final String updateChannel;
  final Future<void> Function(String channel) onUpdateChannelChanged;
  final Future<void> Function() onLogout;

  const SettingsTab({
    super.key,
    required this.api,
    required this.getTokens,
    required this.appVersion,
    required this.updateChannel,
    required this.onUpdateChannelChanged,
    required this.onLogout,
  });

  @override
  ConsumerState<SettingsTab> createState() => _SettingsTabState();
}

class _SettingsTabState extends ConsumerState<SettingsTab> {
  bool _loadingSettings = false;
  bool _checkingUpdate = false;
  bool _downloadingUpdate = false;
  double? _downloadProgress;
  ReleaseInfo? _latest;
  UserSettingsBundle? _settings;
  String? _downloadedUpdatePath;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final tokens = widget.getTokens();
    if (tokens == null || _loadingSettings) return;
    setState(() => _loadingSettings = true);
    try {
      final bundle = await widget.api.mySettings(
        accessToken: tokens.accessToken,
        refreshToken: tokens.refreshToken,
      );
      if (!mounted) return;
      setState(() => _settings = bundle);
    } catch (error) {
      _showSnack(error.toString());
    } finally {
      if (mounted) {
        setState(() => _loadingSettings = false);
      }
    }
  }

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

  Future<void> _openDownloadExternally() async {
    final link = _latest?.downloadUrl;
    if (link == null || link.isEmpty) return;
    final uri = Uri.parse(widget.api.resolveUrl(link));
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && mounted) {
      _showSnack('Cannot open download link');
    }
  }

  Future<void> _downloadUpdateInApp() async {
    final release = _latest;
    if (release == null || _downloadingUpdate) return;

    if (kIsWeb) {
      await _openDownloadExternally();
      return;
    }

    final downloadUrl = widget.api.resolveUrl(release.downloadUrl);
    final uri = Uri.parse(downloadUrl);
    final fileName = uri.pathSegments.isEmpty
        ? 'astralink_update_${release.latestVersion}'
        : uri.pathSegments.last;

    setState(() {
      _downloadingUpdate = true;
      _downloadProgress = 0;
      _downloadedUpdatePath = null;
    });

    try {
      final path = await downloadUpdatePackage(
        downloadUrl: downloadUrl,
        fileName: fileName,
        onProgress: (progress) {
          if (!mounted) return;
          setState(() => _downloadProgress = progress);
        },
      );
      if (!mounted) return;
      setState(() {
        _downloadProgress = 1;
        _downloadedUpdatePath = path;
      });
      _showSnack('Update downloaded inside the app');
    } catch (error) {
      _showSnack(error.toString());
    } finally {
      if (mounted) {
        setState(() => _downloadingUpdate = false);
      }
    }
  }

  Future<void> _installDownloadedUpdate() async {
    final path = _downloadedUpdatePath;
    if (path == null || path.isEmpty) return;
    final result = await OpenFile.open(path);
    if (result.type != ResultType.done && mounted) {
      _showSnack('Could not open downloaded package');
    }
  }

  Future<void> _updatePrivacy({
    String? phoneVisibility,
    String? phoneSearchVisibility,
    String? lastSeenVisibility,
    bool? showApproximateLastSeen,
    String? allowGroupInvites,
  }) async {
    final tokens = widget.getTokens();
    final current = _settings;
    if (tokens == null || current == null) return;
    try {
      final updated = await widget.api.updateMyPrivacySettings(
        accessToken: tokens.accessToken,
        refreshToken: tokens.refreshToken,
        phoneVisibility: phoneVisibility,
        phoneSearchVisibility: phoneSearchVisibility,
        lastSeenVisibility: lastSeenVisibility,
        showApproximateLastSeen: showApproximateLastSeen,
        allowGroupInvites: allowGroupInvites,
      );
      if (!mounted) return;
      setState(() {
        _settings = UserSettingsBundle(
          privacy: updated,
          dataStorage: current.dataStorage,
          blockedUsersCount: current.blockedUsersCount,
        );
      });
    } catch (error) {
      _showSnack(error.toString());
    }
  }

  Future<void> _updateDataStorage({
    int? keepMediaDays,
    int? storageLimitMb,
    bool? autoDownloadPhotos,
    bool? autoDownloadVideos,
    bool? autoDownloadMusic,
    bool? autoDownloadFiles,
    int? defaultAutoDeleteSeconds,
  }) async {
    final tokens = widget.getTokens();
    final current = _settings;
    if (tokens == null || current == null) return;
    try {
      final updated = await widget.api.updateMyDataStorageSettings(
        accessToken: tokens.accessToken,
        refreshToken: tokens.refreshToken,
        keepMediaDays: keepMediaDays,
        storageLimitMb: storageLimitMb,
        autoDownloadPhotos: autoDownloadPhotos,
        autoDownloadVideos: autoDownloadVideos,
        autoDownloadMusic: autoDownloadMusic,
        autoDownloadFiles: autoDownloadFiles,
        defaultAutoDeleteSeconds: defaultAutoDeleteSeconds,
      );
      if (!mounted) return;
      setState(() {
        _settings = UserSettingsBundle(
          privacy: current.privacy,
          dataStorage: updated,
          blockedUsersCount: current.blockedUsersCount,
        );
      });
    } catch (error) {
      _showSnack(error.toString());
    }
  }

  Future<void> _clearAttachmentCache() async {
    try {
      await AstraAttachmentCache.instance.clear();
      _showSnack('Downloaded media cache cleared');
    } catch (error) {
      _showSnack(error.toString());
    }
  }

  Future<void> _showBlockedUsersSheet() async {
    final tokens = widget.getTokens();
    if (tokens == null) {
      _showSnack('Session expired');
      return;
    }

    List<BlockedUserItem> blocked;
    try {
      blocked = await widget.api.blockedUsers(
        accessToken: tokens.accessToken,
        refreshToken: tokens.refreshToken,
      );
    } catch (error) {
      _showSnack(error.toString());
      return;
    }

    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) {
        final rows = List<BlockedUserItem>.from(blocked);
        return StatefulBuilder(
          builder: (context, setSheetState) {
            return SafeArea(
              child: Padding(
                padding: EdgeInsets.only(
                  left: context.sp(12),
                  right: context.sp(12),
                  top: context.sp(12),
                  bottom: context.sp(12),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Blocked users',
                      style: TextStyle(
                        fontSize: context.sp(18),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    SizedBox(height: context.sp(10)),
                    if (rows.isEmpty)
                      Padding(
                        padding: EdgeInsets.all(context.sp(20)),
                        child: const Text('No blocked users'),
                      )
                    else
                      Flexible(
                        child: ListView.separated(
                          shrinkWrap: true,
                          itemCount: rows.length,
                          separatorBuilder: (_, _) => const Divider(height: 1),
                          itemBuilder: (context, index) {
                            final row = rows[index];
                            return ListTile(
                              leading: CircleAvatar(
                                child: Text(
                                  (row.user.displayName.trim().isEmpty
                                          ? '?'
                                          : row
                                                .user
                                                .displayName
                                                .characters
                                                .first)
                                      .toUpperCase(),
                                ),
                              ),
                              title: Text(row.user.displayName),
                              subtitle: Text(
                                row.user.publicHandle ?? row.user.phone ?? '',
                              ),
                              trailing: TextButton(
                                onPressed: () async {
                                  final removed = await widget.api.unblockUser(
                                    accessToken: tokens.accessToken,
                                    refreshToken: tokens.refreshToken,
                                    userId: row.user.id,
                                  );
                                  if (!removed || !context.mounted) return;
                                  setSheetState(() => rows.removeAt(index));
                                  if (mounted && _settings != null) {
                                    setState(() {
                                      _settings = UserSettingsBundle(
                                        privacy: _settings!.privacy,
                                        dataStorage: _settings!.dataStorage,
                                        blockedUsersCount:
                                            ((_settings!.blockedUsersCount - 1)
                                                    .clamp(0, 1 << 31))
                                                .toInt(),
                                      );
                                    });
                                  }
                                },
                                child: const Text('Unblock'),
                              ),
                            );
                          },
                        ),
                      ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
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
    final prefs = ref.watch(appPreferencesProvider);
    final appearance = prefs.appearance;
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
                    'Appearance',
                    style: TextStyle(
                      fontSize: context.sp(18),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  SizedBox(height: context.sp(6)),
                  Text(
                    'Chat palette, message scale, and list density.',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  SizedBox(height: context.sp(12)),
                  _AppearancePreview(appearance: appearance),
                  SizedBox(height: context.sp(16)),
                  Text(
                    'Surface',
                    style: TextStyle(
                      fontSize: context.sp(14),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  SizedBox(height: context.sp(8)),
                  Wrap(
                    spacing: context.sp(8),
                    runSpacing: context.sp(8),
                    children: [
                      for (final preset in ChatSurfacePreset.values)
                        ChoiceChip(
                          label: Text(preset.label),
                          selected: appearance.chatSurfacePreset == preset,
                          onSelected: (_) {
                            ref
                                .read(appPreferencesProvider)
                                .setChatSurfacePreset(preset);
                          },
                        ),
                    ],
                  ),
                  SizedBox(height: context.sp(16)),
                  Text(
                    'Accent',
                    style: TextStyle(
                      fontSize: context.sp(14),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  SizedBox(height: context.sp(8)),
                  Wrap(
                    spacing: context.sp(8),
                    runSpacing: context.sp(8),
                    children: [
                      for (final preset in ChatAccentPreset.values)
                        ChoiceChip(
                          avatar: CircleAvatar(
                            radius: context.sp(9),
                            backgroundColor: AppAppearanceData(
                              chatSurfacePreset: appearance.chatSurfacePreset,
                              chatAccentPreset: preset,
                              messageTextScale: appearance.messageTextScale,
                              compactChatList: appearance.compactChatList,
                            ).accentColor,
                          ),
                          label: Text(preset.label),
                          selected: appearance.chatAccentPreset == preset,
                          onSelected: (_) {
                            ref
                                .read(appPreferencesProvider)
                                .setChatAccentPreset(preset);
                          },
                        ),
                    ],
                  ),
                  SizedBox(height: context.sp(16)),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Message text size',
                          style: TextStyle(
                            fontSize: context.sp(14),
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      Text(
                        '${(appearance.messageTextScale * 100).round()}%',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                  Slider(
                    min: 0.9,
                    max: 1.3,
                    divisions: 8,
                    value: appearance.messageTextScale,
                    onChanged: (value) {
                      ref
                          .read(appPreferencesProvider)
                          .setMessageTextScale(value);
                    },
                  ),
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Compact chat list'),
                    subtitle: const Text(
                      'Reduce vertical space in the chat inbox.',
                    ),
                    value: appearance.compactChatList,
                    onChanged: (value) {
                      ref
                          .read(appPreferencesProvider)
                          .setCompactChatList(value);
                    },
                  ),
                ],
              ),
            ),
          ),
          SizedBox(height: context.sp(10)),
          _PrivacySettingsCard(
            settings: _settings,
            loading: _loadingSettings,
            onReload: _loadSettings,
            onPrivacyChanged: _updatePrivacy,
            onShowBlockedUsers: _showBlockedUsersSheet,
          ),
          SizedBox(height: context.sp(10)),
          _DataStorageSettingsCard(
            settings: _settings,
            loading: _loadingSettings,
            onReload: _loadSettings,
            onDataChanged: _updateDataStorage,
            onClearCache: _clearAttachmentCache,
          ),
          SizedBox(height: context.sp(10)),
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
                    onChanged: (value) async {
                      if (value == null) return;
                      await widget.onUpdateChannelChanged(value);
                      if (mounted) setState(() {});
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
                    if (_latest!.generatedAt != null &&
                        _latest!.generatedAt!.trim().isNotEmpty)
                      Padding(
                        padding: EdgeInsets.only(top: context.sp(4)),
                        child: Text('Manifest: ${_latest!.generatedAt}'),
                      ),
                    Padding(
                      padding: EdgeInsets.only(top: context.sp(4)),
                      child: Text(
                        'Package: ${_latest!.packageKind} • install: ${_latest!.installStrategy}',
                      ),
                    ),
                    if (_latest!.notes.trim().isNotEmpty)
                      Padding(
                        padding: EdgeInsets.only(top: context.sp(4)),
                        child: Text('Notes: ${_latest!.notes}'),
                      ),
                    if (_downloadProgress != null) ...[
                      SizedBox(height: context.sp(10)),
                      LinearProgressIndicator(value: _downloadProgress),
                      SizedBox(height: context.sp(6)),
                      Text(
                        _downloadingUpdate
                            ? 'Downloading ${(100 * (_downloadProgress ?? 0)).round()}%'
                            : _downloadedUpdatePath != null
                            ? 'Downloaded package is ready'
                            : 'Download progress is unavailable',
                      ),
                    ],
                    SizedBox(height: context.sp(8)),
                    Wrap(
                      spacing: context.sp(8),
                      runSpacing: context.sp(8),
                      children: [
                        FilledButton.tonal(
                          onPressed: hasUpdate && !_downloadingUpdate
                              ? (_latest!.inAppDownloadSupported
                                    ? _downloadUpdateInApp
                                    : _openDownloadExternally)
                              : null,
                          child: Text(
                            _latest!.inAppDownloadSupported
                                ? 'Download inside app'
                                : 'Open download link',
                          ),
                        ),
                        OutlinedButton(
                          onPressed: _downloadedUpdatePath == null
                              ? null
                              : _installDownloadedUpdate,
                          child: const Text('Install downloaded update'),
                        ),
                      ],
                    ),
                    if (_downloadedUpdatePath != null)
                      Padding(
                        padding: EdgeInsets.only(top: context.sp(8)),
                        child: Text(
                          'Installer: $_downloadedUpdatePath',
                          style: TextStyle(
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurfaceVariant,
                          ),
                        ),
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
              subtitle: const Text('Keep local appearance settings'),
              onTap: widget.onLogout,
            ),
          ),
        ],
      ),
    );
  }
}

class _PrivacySettingsCard extends StatelessWidget {
  final UserSettingsBundle? settings;
  final bool loading;
  final Future<void> Function() onReload;
  final Future<void> Function({
    String? phoneVisibility,
    String? phoneSearchVisibility,
    String? lastSeenVisibility,
    bool? showApproximateLastSeen,
    String? allowGroupInvites,
  })
  onPrivacyChanged;
  final Future<void> Function() onShowBlockedUsers;

  const _PrivacySettingsCard({
    required this.settings,
    required this.loading,
    required this.onReload,
    required this.onPrivacyChanged,
    required this.onShowBlockedUsers,
  });

  @override
  Widget build(BuildContext context) {
    final bundle = settings;
    return Card(
      child: Padding(
        padding: EdgeInsets.all(context.sp(14)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Privacy & Security',
              style: TextStyle(
                fontSize: context.sp(18),
                fontWeight: FontWeight.w700,
              ),
            ),
            SizedBox(height: context.sp(6)),
            Text(
              'Phone number visibility, searchability, last seen mode, group invites, and block list.',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            SizedBox(height: context.sp(10)),
            if (loading && bundle == null)
              const Center(child: CircularProgressIndicator())
            else if (bundle == null)
              FilledButton.tonal(
                onPressed: onReload,
                child: const Text('Load settings'),
              )
            else ...[
              _AudienceSelector(
                label: 'Who can see my phone number',
                subtitle: 'Matches Telegram-style phone visibility control.',
                value: bundle.privacy.phoneVisibility,
                onChanged: (value) => onPrivacyChanged(phoneVisibility: value),
              ),
              SizedBox(height: context.sp(10)),
              _AudienceSelector(
                label: 'Who can find me by my number',
                subtitle: 'Controls phone lookup and search by number.',
                value: bundle.privacy.phoneSearchVisibility,
                onChanged: (value) =>
                    onPrivacyChanged(phoneSearchVisibility: value),
              ),
              SizedBox(height: context.sp(10)),
              _AudienceSelector(
                label: 'Last seen & online',
                subtitle:
                    'Choose visibility for exact or approximate last seen.',
                value: bundle.privacy.lastSeenVisibility,
                onChanged: (value) =>
                    onPrivacyChanged(lastSeenVisibility: value),
              ),
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: const Text('Show approximate last seen'),
                subtitle: const Text(
                  'Expose “recently / within a week / within a month” instead of exact time.',
                ),
                value: bundle.privacy.showApproximateLastSeen,
                onChanged: (value) =>
                    onPrivacyChanged(showApproximateLastSeen: value),
              ),
              SizedBox(height: context.sp(6)),
              _AudienceSelector(
                label: 'Who can add me to groups',
                subtitle: 'Foundation for invite and anti-spam controls.',
                value: bundle.privacy.allowGroupInvites,
                onChanged: (value) =>
                    onPrivacyChanged(allowGroupInvites: value),
              ),
              SizedBox(height: context.sp(10)),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.block_rounded),
                title: const Text('Blocked users'),
                subtitle: Text('${bundle.blockedUsersCount} user(s)'),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: onShowBlockedUsers,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _DataStorageSettingsCard extends StatelessWidget {
  final UserSettingsBundle? settings;
  final bool loading;
  final Future<void> Function() onReload;
  final Future<void> Function({
    int? keepMediaDays,
    int? storageLimitMb,
    bool? autoDownloadPhotos,
    bool? autoDownloadVideos,
    bool? autoDownloadMusic,
    bool? autoDownloadFiles,
    int? defaultAutoDeleteSeconds,
  })
  onDataChanged;
  final Future<void> Function() onClearCache;

  const _DataStorageSettingsCard({
    required this.settings,
    required this.loading,
    required this.onReload,
    required this.onDataChanged,
    required this.onClearCache,
  });

  @override
  Widget build(BuildContext context) {
    final bundle = settings;
    return Card(
      child: Padding(
        padding: EdgeInsets.all(context.sp(14)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Data & Storage',
              style: TextStyle(
                fontSize: context.sp(18),
                fontWeight: FontWeight.w700,
              ),
            ),
            SizedBox(height: context.sp(6)),
            Text(
              'Auto-download, media retention, default auto-delete timer, and local cache cleanup.',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            SizedBox(height: context.sp(10)),
            if (loading && bundle == null)
              const Center(child: CircularProgressIndicator())
            else if (bundle == null)
              FilledButton.tonal(
                onPressed: onReload,
                child: const Text('Load settings'),
              )
            else ...[
              DropdownButtonFormField<int>(
                initialValue: bundle.dataStorage.keepMediaDays,
                decoration: const InputDecoration(labelText: 'Keep media for'),
                items: const [
                  DropdownMenuItem(value: 7, child: Text('7 days')),
                  DropdownMenuItem(value: 30, child: Text('30 days')),
                  DropdownMenuItem(value: 90, child: Text('90 days')),
                  DropdownMenuItem(value: 365, child: Text('1 year')),
                ],
                onChanged: (value) {
                  if (value != null) {
                    onDataChanged(keepMediaDays: value);
                  }
                },
              ),
              SizedBox(height: context.sp(10)),
              DropdownButtonFormField<int>(
                initialValue: bundle.dataStorage.defaultAutoDeleteSeconds ?? 0,
                decoration: const InputDecoration(
                  labelText: 'Default auto-delete timer',
                ),
                items: const [
                  DropdownMenuItem(value: 0, child: Text('Off')),
                  DropdownMenuItem(value: 86400, child: Text('1 day')),
                  DropdownMenuItem(value: 604800, child: Text('1 week')),
                  DropdownMenuItem(value: 2592000, child: Text('1 month')),
                ],
                onChanged: (value) {
                  if (value != null) {
                    onDataChanged(
                      defaultAutoDeleteSeconds: value == 0 ? 0 : value,
                    );
                  }
                },
              ),
              SizedBox(height: context.sp(10)),
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: const Text('Auto-download photos'),
                value: bundle.dataStorage.autoDownloadPhotos,
                onChanged: (value) => onDataChanged(autoDownloadPhotos: value),
              ),
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: const Text('Auto-download videos'),
                value: bundle.dataStorage.autoDownloadVideos,
                onChanged: (value) => onDataChanged(autoDownloadVideos: value),
              ),
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: const Text('Auto-download music & voice'),
                value: bundle.dataStorage.autoDownloadMusic,
                onChanged: (value) => onDataChanged(autoDownloadMusic: value),
              ),
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: const Text('Auto-download files'),
                value: bundle.dataStorage.autoDownloadFiles,
                onChanged: (value) => onDataChanged(autoDownloadFiles: value),
              ),
              SizedBox(height: context.sp(8)),
              OutlinedButton.icon(
                onPressed: onClearCache,
                icon: const Icon(Icons.delete_sweep_outlined),
                label: const Text('Clear downloaded media cache'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _AudienceSelector extends StatelessWidget {
  final String label;
  final String subtitle;
  final String value;
  final ValueChanged<String?> onChanged;

  const _AudienceSelector({
    required this.label,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<String>(
      initialValue: value,
      decoration: InputDecoration(labelText: label, helperText: subtitle),
      items: const [
        DropdownMenuItem(value: 'everyone', child: Text('Everybody')),
        DropdownMenuItem(value: 'contacts', child: Text('My contacts')),
        DropdownMenuItem(value: 'nobody', child: Text('Nobody')),
      ],
      onChanged: onChanged,
    );
  }
}

class _AppearancePreview extends StatelessWidget {
  final AppAppearanceData appearance;

  const _AppearancePreview({required this.appearance});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(context.sp(12)),
      decoration: BoxDecoration(
        gradient: appearance.chatBackgroundGradient,
        borderRadius: BorderRadius.circular(context.sp(18)),
        border: Border.all(color: appearance.outlineColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Preview',
            style: TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: context.sp(14),
            ),
          ),
          SizedBox(height: context.sp(12)),
          Align(
            alignment: Alignment.centerLeft,
            child: Container(
              constraints: BoxConstraints(maxWidth: context.sp(180)),
              padding: EdgeInsets.symmetric(
                horizontal: context.sp(12),
                vertical: context.sp(8),
              ),
              decoration: BoxDecoration(
                color: appearance.incomingBubbleColor,
                borderRadius: BorderRadius.circular(context.sp(14)),
                border: Border.all(color: appearance.incomingBubbleBorderColor),
              ),
              child: Text(
                'Incoming bubble',
                style: TextStyle(fontSize: context.sp(14)),
              ),
            ),
          ),
          SizedBox(height: context.sp(8)),
          Align(
            alignment: Alignment.centerRight,
            child: Container(
              constraints: BoxConstraints(maxWidth: context.sp(190)),
              padding: EdgeInsets.symmetric(
                horizontal: context.sp(12),
                vertical: context.sp(8),
              ),
              decoration: BoxDecoration(
                color: appearance.outgoingBubbleColor,
                borderRadius: BorderRadius.circular(context.sp(14)),
                border: Border.all(color: appearance.outgoingBubbleBorderColor),
              ),
              child: Text(
                'Accent bubble ${appearance.chatAccentPreset.label}',
                textAlign: TextAlign.right,
                style: TextStyle(fontSize: context.sp(14)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
