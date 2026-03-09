import 'package:flutter/material.dart';

import '../../../api.dart';
import '../../../core/ui/adaptive_size.dart';
import '../../../models.dart';

class ProfileSetupScreen extends StatefulWidget {
  final AstraApi api;
  final AuthTokens? Function() getTokens;
  final AppUser user;
  final Future<void> Function(AppUser user) onCompleted;
  final Future<void> Function() onLogout;

  const ProfileSetupScreen({
    super.key,
    required this.api,
    required this.getTokens,
    required this.user,
    required this.onCompleted,
    required this.onLogout,
  });

  @override
  State<ProfileSetupScreen> createState() => _ProfileSetupScreenState();
}

class _ProfileSetupScreenState extends State<ProfileSetupScreen> {
  static final RegExp _usernamePattern = RegExp(r'^[a-z][a-z0-9_]{4,31}$');

  late final TextEditingController _firstNameController;
  late final TextEditingController _lastNameController;
  late final TextEditingController _usernameController;

  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _firstNameController = TextEditingController(text: widget.user.firstName);
    _lastNameController = TextEditingController(text: widget.user.lastName);
    _usernameController = TextEditingController(
      text: widget.user.usernameLooksGenerated ? '' : widget.user.username,
    );
  }

  @override
  void dispose() {
    _firstNameController.dispose();
    _lastNameController.dispose();
    _usernameController.dispose();
    super.dispose();
  }

  String get _normalizedUsername =>
      _usernameController.text.trim().toLowerCase();

  bool get _usernameValid => _usernamePattern.hasMatch(_normalizedUsername);

  bool get _canContinue =>
      _firstNameController.text.trim().isNotEmpty && _usernameValid;

  Future<void> _save() async {
    if (!_canContinue || _saving) return;
    final tokens = widget.getTokens();
    if (tokens == null) return;

    setState(() => _saving = true);
    try {
      final updated = await widget.api.updateMe(
        accessToken: tokens.accessToken,
        refreshToken: tokens.refreshToken,
        username: _normalizedUsername,
        firstName: _firstNameController.text.trim(),
        lastName: _lastNameController.text.trim(),
      );
      await widget.onCompleted(updated);
    } catch (error) {
      _showSnack(error.toString());
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
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
    final theme = Theme.of(context);
    return Scaffold(
      body: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              theme.colorScheme.surface,
              theme.colorScheme.surfaceContainerLow,
              theme.colorScheme.surface,
            ],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: context.sp(560)),
              child: SingleChildScrollView(
                padding: EdgeInsets.all(context.sp(22)),
                child: Card(
                  child: Padding(
                    padding: EdgeInsets.all(context.sp(22)),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        CircleAvatar(
                          radius: context.sp(30),
                          backgroundColor: theme.colorScheme.primaryContainer,
                          child: Text(
                            (widget.user.phone ?? widget.user.username)
                                .replaceAll('+', '')
                                .characters
                                .take(1)
                                .toString()
                                .toUpperCase(),
                            style: TextStyle(
                              fontSize: context.sp(24),
                              fontWeight: FontWeight.w700,
                              color: theme.colorScheme.primary,
                            ),
                          ),
                        ),
                        SizedBox(height: context.sp(16)),
                        Text(
                          'Finish profile setup',
                          style: TextStyle(
                            fontSize: context.sp(28),
                            fontWeight: FontWeight.w800,
                            letterSpacing: -0.6,
                          ),
                        ),
                        SizedBox(height: context.sp(8)),
                        Text(
                          'Choose the name and username that other people will see when they search for you or open a chat.',
                          style: TextStyle(
                            fontSize: context.sp(15),
                            height: 1.45,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        SizedBox(height: context.sp(16)),
                        if (widget.user.phone != null)
                          Container(
                            padding: EdgeInsets.symmetric(
                              horizontal: context.sp(14),
                              vertical: context.sp(12),
                            ),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(
                                context.sp(16),
                              ),
                              color: theme.colorScheme.surfaceContainerHighest,
                              border: Border.all(
                                color: theme.colorScheme.outlineVariant,
                              ),
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  Icons.smartphone_rounded,
                                  color: theme.colorScheme.primary,
                                ),
                                SizedBox(width: context.sp(10)),
                                Expanded(
                                  child: Text(
                                    widget.user.phone!,
                                    style: TextStyle(
                                      fontSize: context.sp(14),
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        SizedBox(height: context.sp(18)),
                        TextField(
                          controller: _firstNameController,
                          textCapitalization: TextCapitalization.words,
                          decoration: const InputDecoration(
                            labelText: 'First name',
                            prefixIcon: Icon(Icons.badge_outlined),
                          ),
                          onChanged: (_) => setState(() {}),
                        ),
                        SizedBox(height: context.sp(12)),
                        TextField(
                          controller: _lastNameController,
                          textCapitalization: TextCapitalization.words,
                          decoration: const InputDecoration(
                            labelText: 'Last name (optional)',
                            prefixIcon: Icon(Icons.person_outline_rounded),
                          ),
                          onChanged: (_) => setState(() {}),
                        ),
                        SizedBox(height: context.sp(12)),
                        TextField(
                          controller: _usernameController,
                          autocorrect: false,
                          decoration: InputDecoration(
                            labelText: 'Username',
                            prefixText: '@',
                            prefixIcon: const Icon(Icons.alternate_email_rounded),
                            helperText:
                                '5-32 chars, start with a letter, then letters, numbers or underscore.',
                            errorText: _usernameController.text.isEmpty ||
                                    _usernameValid
                                ? null
                                : 'Invalid username format',
                          ),
                          onChanged: (_) => setState(() {}),
                        ),
                        SizedBox(height: context.sp(18)),
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton(
                                onPressed: _saving ? null : widget.onLogout,
                                child: const Text('Log out'),
                              ),
                            ),
                            SizedBox(width: context.sp(10)),
                            Expanded(
                              child: FilledButton(
                                onPressed: _canContinue && !_saving
                                    ? _save
                                    : null,
                                child: _saving
                                    ? SizedBox(
                                        width: context.sp(18),
                                        height: context.sp(18),
                                        child:
                                            const CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      )
                                    : const Text('Continue'),
                              ),
                            ),
                          ],
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
    );
  }
}
