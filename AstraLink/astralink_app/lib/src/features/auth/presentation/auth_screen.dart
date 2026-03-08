import 'package:flutter/material.dart';

import '../../../api.dart';
import '../../../core/ui/adaptive_size.dart';
import '../../../models.dart';

class AuthScreen extends StatefulWidget {
  final AstraApi api;
  final Future<void> Function(AuthResult result) onAuthorized;

  const AuthScreen({super.key, required this.api, required this.onAuthorized});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final _phoneController = TextEditingController();
  final _codeController = TextEditingController();
  final _firstNameController = TextEditingController();
  final _lastNameController = TextEditingController();

  bool _loading = false;
  PhoneCodeSession? _session;

  @override
  void dispose() {
    _phoneController.dispose();
    _codeController.dispose();
    _firstNameController.dispose();
    _lastNameController.dispose();
    super.dispose();
  }

  bool get _isPhoneStep => _session == null;

  bool get _canSendCode {
    final digits = _phoneController.text.replaceAll(RegExp(r'[^0-9]'), '');
    return digits.length >= 10;
  }

  bool get _canVerify {
    final codeOk = _codeController.text.trim().length >= 4;
    if (!codeOk) return false;
    if (_session == null) return false;
    if (_session!.isRegistered) return true;
    return _firstNameController.text.trim().isNotEmpty;
  }

  Future<void> _requestCode() async {
    if (!_canSendCode || _loading) return;
    setState(() => _loading = true);
    try {
      final session = await widget.api.requestPhoneCode(_phoneController.text);
      if (!mounted) return;
      setState(() {
        _session = session;
      });
      _showSnack('Code sent to ${session.phone}');
    } catch (error) {
      _showSnack(error.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _verifyCode() async {
    if (!_canVerify || _loading || _session == null) return;
    setState(() => _loading = true);
    try {
      final result = await widget.api.verifyPhoneCode(
        phone: _session!.phone,
        codeToken: _session!.codeToken,
        code: _codeController.text.trim(),
        firstName: _session!.isRegistered
            ? null
            : _firstNameController.text.trim(),
        lastName: _session!.isRegistered
            ? null
            : _lastNameController.text.trim(),
      );
      await widget.onAuthorized(result);
    } catch (error) {
      _showSnack(error.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
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
    final horizontalPadding = context.sp(22);
    final titleStyle = TextStyle(
      fontSize: context.sp(32),
      fontWeight: FontWeight.w800,
      height: 1.1,
    );

    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: context.sp(520)),
          child: SingleChildScrollView(
            padding: EdgeInsets.symmetric(
              horizontal: horizontalPadding,
              vertical: context.sp(28),
            ),
            child: Card(
              child: Padding(
                padding: EdgeInsets.all(context.sp(20)),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.send_rounded,
                      color: Theme.of(context).colorScheme.primary,
                      size: context.sp(42),
                    ),
                    SizedBox(height: context.sp(12)),
                    Text('AstraLink', style: titleStyle),
                    SizedBox(height: context.sp(6)),
                    Text(
                      'Phone-first messenger',
                      style: TextStyle(
                        fontSize: context.sp(16),
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                    SizedBox(height: context.sp(22)),
                    if (_isPhoneStep) ...[
                      TextField(
                        controller: _phoneController,
                        keyboardType: TextInputType.phone,
                        decoration: const InputDecoration(
                          labelText: 'Phone number',
                          hintText: '+7 900 000 00 00',
                        ),
                        onChanged: (_) => setState(() {}),
                      ),
                      SizedBox(height: context.sp(16)),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: _canSendCode && !_loading
                              ? _requestCode
                              : null,
                          icon: _loading
                              ? SizedBox(
                                  width: context.sp(18),
                                  height: context.sp(18),
                                  child: const CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.sms_rounded),
                          label: const Text('Send code'),
                        ),
                      ),
                    ] else ...[
                      Text(
                        'Code sent to ${_session!.phone}',
                        style: TextStyle(
                          fontSize: context.sp(14),
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                      SizedBox(height: context.sp(10)),
                      TextField(
                        controller: _codeController,
                        keyboardType: TextInputType.number,
                        maxLength: 6,
                        decoration: const InputDecoration(
                          labelText: 'Verification code',
                        ),
                        onChanged: (_) => setState(() {}),
                      ),
                      if (!_session!.isRegistered) ...[
                        SizedBox(height: context.sp(6)),
                        TextField(
                          controller: _firstNameController,
                          decoration: const InputDecoration(
                            labelText: 'First name',
                          ),
                          onChanged: (_) => setState(() {}),
                        ),
                        SizedBox(height: context.sp(10)),
                        TextField(
                          controller: _lastNameController,
                          decoration: const InputDecoration(
                            labelText: 'Last name (optional)',
                          ),
                          onChanged: (_) => setState(() {}),
                        ),
                      ],
                      SizedBox(height: context.sp(16)),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              onPressed: _loading
                                  ? null
                                  : () {
                                      setState(() {
                                        _session = null;
                                        _codeController.clear();
                                      });
                                    },
                              child: const Text('Change number'),
                            ),
                          ),
                          SizedBox(width: context.sp(10)),
                          Expanded(
                            child: FilledButton(
                              onPressed: _canVerify && !_loading
                                  ? _verifyCode
                                  : null,
                              child: _loading
                                  ? SizedBox(
                                      width: context.sp(18),
                                      height: context.sp(18),
                                      child: const CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Text('Continue'),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
