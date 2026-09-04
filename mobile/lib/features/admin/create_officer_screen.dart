import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api_client.dart';
import '../../core/models.dart';
import '../../core/palette.dart';
import '../../core/theme.dart';
import '../../shared/ui.dart';

/// Admin-only: a zone officer account is created and assigned to a zone in
/// one step, same as Warden and Worker Supervisor - no self-registration, no
/// approval queue. Zone officers are fixed faculty appointments.
class CreateOfficerScreen extends StatefulWidget {
  const CreateOfficerScreen({super.key});

  @override
  State<CreateOfficerScreen> createState() => _CreateOfficerScreenState();
}

class _CreateOfficerScreenState extends State<CreateOfficerScreen> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _phone = TextEditingController();
  final _password = TextEditingController();

  List<Zone> _zones = const [];
  int? _zoneCode;
  bool _loadingZones = true;
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
      final res = await context.read<ApiClient>().get('/admin/dashboard');
      final all = (res['zones'] as List).cast<Map<String, dynamic>>();
      final open = all.where((z) => z['officer'] == null);
      final list = open
          .map((z) => Zone(
                id: z['code'].toString(),
                code: z['code'] as int,
                name: z['name'] as String,
                label: z['label'] as String,
                colorHex: z['colorHex'] as String? ?? '#4F86C6',
              ))
          .toList();
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
      setState(() => _error = 'Choose which zone this officer runs');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      final res = await context.read<ApiClient>().post('/admin/zones/officers', {
        'name': _name.text.trim(),
        'email': _email.text.trim(),
        if (_phone.text.trim().isNotEmpty) 'phone': _phone.text.trim(),
        'password': _password.text,
        'zoneCode': _zoneCode,
      });
      if (mounted) {
        Navigator.of(context).pop(true);
        showSnack(context, res['message'] as String? ?? 'Officer created');
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
      appBar: AppBar(title: const Text('New zone officer')),
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
                      'Runs one zone: complaints from it come to them, and they '
                      'allot them to their workers.',
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
                        helperText: 'At least 6 characters',
                      ),
                      validator: (v) => (v == null || v.length < 6) ? 'Use at least 6 characters' : null,
                    ),
                    const SizedBox(height: 24),
                    const Text(
                      'WHICH ZONE',
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
                        padding: EdgeInsets.symmetric(vertical: 20),
                        child: Center(child: CircularProgressIndicator()),
                      )
                    else if (_zones.isEmpty)
                      const Text(
                        'Every zone already has an officer. Reassign one from '
                        'Set up zones first.',
                        style: TextStyle(fontSize: 12.5, color: Palette.inkSecondary),
                      )
                    else
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final z in _zones)
                            _ZoneOption(
                              zone: z,
                              selected: _zoneCode == z.code,
                              onTap: () => setState(() => _zoneCode = z.code),
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

class _ZoneOption extends StatelessWidget {
  final Zone zone;
  final bool selected;
  final VoidCallback onTap;

  const _ZoneOption({required this.zone, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final color = colorFromHex(zone.colorHex);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: selected ? color.withValues(alpha: 0.16) : Colors.white,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: selected ? color : Colors.black.withValues(alpha: 0.12),
              width: selected ? 2 : 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 11,
                height: 11,
                decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(3)),
              ),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(zone.name, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
                  Text(zone.label, style: const TextStyle(fontSize: 11, color: Palette.inkSecondary)),
                ],
              ),
              if (selected) ...[
                const SizedBox(width: 8),
                Icon(Icons.check_circle, size: 17, color: color),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
