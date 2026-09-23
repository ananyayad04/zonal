import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api_client.dart';
import '../../core/models.dart';
import '../../core/palette.dart';
import '../../core/theme.dart';
import '../../shared/ui.dart';

/// Supervisor/Admin-only: a Worker account created directly, zone-wise -
/// unlike self-registration, there is no PENDING queue to sit in. This is
/// for the campus workers who have no smartphone or will never install the
/// app: the supervisor who actually knows them sets them up here, active
/// and on duty immediately.
class CreateWorkerScreen extends StatefulWidget {
  const CreateWorkerScreen({super.key});

  @override
  State<CreateWorkerScreen> createState() => _CreateWorkerScreenState();
}

class _CreateWorkerScreenState extends State<CreateWorkerScreen> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _phone = TextEditingController();
  final _password = TextEditingController();

  List<Zone> _zones = const [];
  bool _loadingZones = true;
  int? _zoneCode;

  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadZones();
  }

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _phone.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _loadZones() async {
    try {
      final res = await context.read<ApiClient>().get('/zones');
      final list = (res['zones'] as List).map((z) => Zone.fromJson(z as Map<String, dynamic>)).toList();
      if (mounted) setState(() => _zones = list);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loadingZones = false);
    }
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    if (_zoneCode == null) {
      setState(() => _error = 'Choose which zone this worker covers');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      final res = await context.read<ApiClient>().post('/admin/workers', {
        'name': _name.text.trim(),
        'email': _email.text.trim(),
        if (_phone.text.trim().isNotEmpty) 'phone': _phone.text.trim(),
        'password': _password.text,
        'zoneCode': _zoneCode,
      });
      if (mounted) {
        Navigator.of(context).pop(true);
        showSnack(context, res['message'] as String? ?? 'Worker created');
      }
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('New worker')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text(
                      'For a worker who has no smartphone, or will not install the '
                      'app - the account is usable for allotment right away. You can '
                      'start and finish their tasks on their behalf from the '
                      'allotted-work screen.',
                      style: TextStyle(fontSize: 12.5, color: Palette.inkSecondary, height: 1.4),
                    ),
                    const SizedBox(height: 20),
                    TextFormField(
                      controller: _name,
                      textCapitalization: TextCapitalization.words,
                      decoration: const InputDecoration(
                        labelText: 'Full name',
                        prefixIcon: Icon(Icons.badge_outlined),
                      ),
                      validator: (v) => (v == null || v.trim().length < 2) ? 'Enter a full name' : null,
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _email,
                      keyboardType: TextInputType.emailAddress,
                      decoration: const InputDecoration(
                        labelText: 'Email',
                        prefixIcon: Icon(Icons.alternate_email),
                        helperText: 'Used only as their login - a made-up address is fine',
                      ),
                      validator: (v) => (v == null || !v.contains('@')) ? 'Enter a valid email' : null,
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _phone,
                      keyboardType: TextInputType.phone,
                      decoration: const InputDecoration(
                        labelText: 'Phone (optional)',
                        prefixIcon: Icon(Icons.phone_outlined),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _password,
                      obscureText: true,
                      decoration: const InputDecoration(
                        labelText: 'Password',
                        prefixIcon: Icon(Icons.lock_outline),
                        helperText: 'At least 6 characters - they will likely never use it themselves',
                      ),
                      validator: (v) => (v == null || v.length < 6) ? 'Use at least 6 characters' : null,
                    ),
                    const SizedBox(height: 20),
                    const Text(
                      'ZONE',
                      style: TextStyle(
                        fontSize: 10.5,
                        letterSpacing: 1.8,
                        fontWeight: FontWeight.w700,
                        color: Palette.inkMuted,
                      ),
                    ),
                    const SizedBox(height: 10),
                    if (_loadingZones)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 12),
                        child: Center(child: CircularProgressIndicator()),
                      )
                    else
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final z in _zones)
                            ChoiceChip(
                              selected: _zoneCode == z.code,
                              onSelected: (_) => setState(() => _zoneCode = z.code),
                              label: Text('${z.name} · ${z.label}', style: const TextStyle(fontSize: 13)),
                              selectedColor: AppTheme.seed,
                              labelStyle: TextStyle(
                                color: _zoneCode == z.code ? Colors.white : Palette.inkPrimary,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                        ],
                      ),
                    if (_error != null) ...[
                      const SizedBox(height: 18),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Palette.critical.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: Palette.critical.withValues(alpha: 0.3)),
                        ),
                        child: Text(
                          _error!,
                          style: const TextStyle(color: Palette.critical, height: 1.35, fontSize: 13.5),
                        ),
                      ),
                    ],
                    const SizedBox(height: 24),
                    FilledButton(
                      onPressed: _busy ? null : _submit,
                      child: _busy
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2.2, color: Colors.white),
                            )
                          : const Text('Create account'),
                    ),
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
