import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../api.dart';
import '../../../core/ui/adaptive_size.dart';
import '../../../models.dart';

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

