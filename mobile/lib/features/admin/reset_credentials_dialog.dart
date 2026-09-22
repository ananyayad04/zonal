import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api_client.dart';
import '../../core/palette.dart';
import '../../shared/ui.dart';

/// Admin-only: change an officer's, warden's, or worker supervisor's email
/// and/or password without touching their account, zone/hostel assignment,
/// or history - the alternative to removing and recreating someone just to
/// get them new login details.
///
/// Shows its own error inline and reports success via a snackbar, so callers
/// only need to `await` this and, if it returns true, refresh their list.
Future<bool> showResetCredentialsDialog(
  BuildContext context, {
  required String userId,
  required String name,
}) async {
  final changed = await showDialog<bool>(
    context: context,
    builder: (_) => _ResetCredentialsDialog(userId: userId, name: name),
  );
  return changed ?? false;
}

class _ResetCredentialsDialog extends StatefulWidget {
  final String userId;
  final String name;

  const _ResetCredentialsDialog({required this.userId, required this.name});

  @override
  State<_ResetCredentialsDialog> createState() => _ResetCredentialsDialogState();
}

class _ResetCredentialsDialogState extends State<_ResetCredentialsDialog> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final email = _email.text.trim();
    final password = _password.text.trim();
    if (email.isEmpty && password.isEmpty) {
      setState(() => _error = 'Enter a new email or password');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      final res = await context.read<ApiClient>().put(
        '/admin/personnel/${widget.userId}/credentials',
        {
          if (email.isNotEmpty) 'email': email,
          if (password.isNotEmpty) 'password': password,
        },
      );
      if (mounted) {
        Navigator.of(context).pop(true);
        showSnack(context, res['message'] as String? ?? 'Login details updated');
      }
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Reset ${widget.name}\'s login'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Leave a field blank to keep it as-is. The account, its '
            'assignment, and its history are untouched.',
            style: TextStyle(fontSize: 12.5, color: Palette.inkSecondary, height: 1.35),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _email,
            keyboardType: TextInputType.emailAddress,
            decoration: const InputDecoration(labelText: 'New email (optional)'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _password,
            decoration: const InputDecoration(labelText: 'New password (optional)'),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: const TextStyle(color: Palette.critical, fontSize: 12.5)),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: _busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2.2, color: Colors.white),
                )
              : const Text('Save'),
        ),
      ],
    );
  }
}
