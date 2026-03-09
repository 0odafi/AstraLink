import 'package:flutter/material.dart';

import '../../../api.dart';
import '../../../core/ui/adaptive_size.dart';
import '../../../models.dart';

class ProfileTab extends StatefulWidget {
  final AstraApi api;
  final AuthTokens? Function() getTokens;
  final AppUser me;
  final Future<void> Function(AppUser user) onUserUpdated;

  const ProfileTab({
    super.key,
    required this.api,
    required this.getTokens,
    required this.me,
    required this.onUserUpdated,
  });

  @override
  State<ProfileTab> createState() => _ProfileTabState();
}

class _ProfileTabState extends State<ProfileTab> {
  late TextEditingController _usernameController;
  late TextEditingController _firstNameController;
  late TextEditingController _lastNameController;
  late TextEditingController _bioController;

  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _usernameController = TextEditingController(text: widget.me.username);
    _firstNameController = TextEditingController(text: widget.me.firstName);
    _lastNameController = TextEditingController(text: widget.me.lastName);
    _bioController = TextEditingController(text: widget.me.bio);
  }

  @override
  void didUpdateWidget(covariant ProfileTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.me.id != widget.me.id ||
        oldWidget.me.username != widget.me.username ||
        oldWidget.me.firstName != widget.me.firstName ||
        oldWidget.me.lastName != widget.me.lastName ||
        oldWidget.me.bio != widget.me.bio) {
      _usernameController.text = widget.me.username;
      _firstNameController.text = widget.me.firstName;
      _lastNameController.text = widget.me.lastName;
      _bioController.text = widget.me.bio;
    }
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _firstNameController.dispose();
    _lastNameController.dispose();
    _bioController.dispose();
    super.dispose();
  }

  Future<void> _saveProfile() async {
    if (_saving) return;
    final tokens = widget.getTokens();
    if (tokens == null) return;

    setState(() => _saving = true);
    try {
      final updated = await widget.api.updateMe(
        accessToken: tokens.accessToken,
        refreshToken: tokens.refreshToken,
        username: _usernameController.text.trim(),
        firstName: _firstNameController.text.trim(),
        lastName: _lastNameController.text.trim(),
        bio: _bioController.text.trim(),
      );
      await widget.onUserUpdated(updated);
      if (!mounted) return;
      _showSnack('Profile updated');
    } catch (error) {
      _showSnack(error.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Profile')),
      body: ListView(
        padding: EdgeInsets.all(context.sp(12)),
        children: [
          Card(
            child: Padding(
              padding: EdgeInsets.all(context.sp(14)),
              child: Column(
                children: [
                  CircleAvatar(
                    radius: context.sp(34),
                    child: Text(
                      widget.me.displayName.characters.first.toUpperCase(),
                      style: TextStyle(
                        fontSize: context.sp(24),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  SizedBox(height: context.sp(10)),
                  Text(
                    widget.me.displayName,
                    style: TextStyle(
                      fontSize: context.sp(22),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (widget.me.phone != null)
                    Text(
                      widget.me.phone!,
                      style: TextStyle(
                        fontSize: context.sp(14),
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
          ),
          SizedBox(height: context.sp(10)),
          TextField(
            controller: _usernameController,
            decoration: const InputDecoration(labelText: 'Username'),
            onChanged: (_) => setState(() {}),
          ),
          SizedBox(height: context.sp(10)),
          TextField(
            controller: _firstNameController,
            decoration: const InputDecoration(labelText: 'First name'),
            onChanged: (_) => setState(() {}),
          ),
          SizedBox(height: context.sp(10)),
          TextField(
            controller: _lastNameController,
            decoration: const InputDecoration(labelText: 'Last name'),
            onChanged: (_) => setState(() {}),
          ),
          SizedBox(height: context.sp(10)),
          TextField(
            controller: _bioController,
            minLines: 2,
            maxLines: 4,
            decoration: const InputDecoration(labelText: 'Bio'),
            onChanged: (_) => setState(() {}),
          ),
          SizedBox(height: context.sp(14)),
          FilledButton(
            onPressed: _saving ? null : _saveProfile,
            child: _saving
                ? SizedBox(
                    width: context.sp(16),
                    height: context.sp(16),
                    child: const CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Save'),
          ),
        ],
      ),
    );
  }
}

