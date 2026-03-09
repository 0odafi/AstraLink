import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../api.dart';
import '../../../core/ui/adaptive_size.dart';
import '../../../core/ui/app_appearance.dart';
import '../../../models.dart';
import '../application/app_preferences.dart';

class SettingsTab extends ConsumerStatefulWidget {
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
  ConsumerState<SettingsTab> createState() => _SettingsTabState();
}

class _SettingsTabState extends ConsumerState<SettingsTab> {
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
                    if (_latest!.notes.trim().isNotEmpty)
                      Padding(
                        padding: EdgeInsets.only(top: context.sp(4)),
                        child: Text('Notes: ${_latest!.notes}'),
                      ),
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
              subtitle: const Text('Keep local appearance settings'),
              onTap: widget.onLogout,
            ),
          ),
        ],
      ),
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
