import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api_client.dart';
import '../../core/palette.dart';
import '../../shared/ui.dart';

class _Hostel {
  final String id;
  final String name;
  final String category;
  final Map<String, dynamic>? warden;

  const _Hostel({required this.id, required this.name, required this.category, this.warden});

  factory _Hostel.fromJson(Map<String, dynamic> j) => _Hostel(
        id: j['id'] as String,
        name: j['name'] as String,
        category: j['category'] as String,
        warden: j['warden'] as Map<String, dynamic>?,
      );
}

/// Admin-only: a Warden account is created and assigned to a hostel in one
/// step, unlike Worker/Officer which self-register and wait for approval -
/// there is no "unassigned warden" state to handle.
class CreateWardenScreen extends StatefulWidget {
  const CreateWardenScreen({super.key});

  @override
  State<CreateWardenScreen> createState() => _CreateWardenScreenState();
}

class _CreateWardenScreenState extends State<CreateWardenScreen> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _phone = TextEditingController();
  final _password = TextEditingController();

  List<_Hostel> _hostels = const [];
  String? _hostelId;
  bool _loadingHostels = true;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadHostels();
  }

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _phone.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _loadHostels() async {
    try {
      final res = await context.read<ApiClient>().get('/admin/hostels');
      final list = (res['hostels'] as List)
          .map((h) => _Hostel.fromJson(h as Map<String, dynamic>))
          .where((h) => h.warden == null) // only hostels that still need one
          .toList();
      if (mounted) setState(() => _hostels = list);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loadingHostels = false);
    }
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    if (_hostelId == null) {
      setState(() => _error = 'Choose which hostel this warden runs');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      final res = await context.read<ApiClient>().post('/admin/hostels/wardens', {
        'name': _name.text.trim(),
        'email': _email.text.trim(),
        if (_phone.text.trim().isNotEmpty) 'phone': _phone.text.trim(),
        'password': _password.text,
        'landmarkId': _hostelId,
      });
      if (mounted) {
        Navigator.of(context).pop(true);
        showSnack(context, res['message'] as String? ?? 'Warden created');
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
      appBar: AppBar(title: const Text('New warden')),
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
                      'Owns hostel-internal complaints for exactly one hostel. '
                      'Complaints filed from inside it come straight to them.',
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
                      'WHICH HOSTEL',
                      style: TextStyle(
                        fontSize: 10.5,
                        letterSpacing: 1.8,
                        fontWeight: FontWeight.w700,
                        color: Palette.inkMuted,
                      ),
                    ),
                    const SizedBox(height: 10),
                    if (_loadingHostels)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 20),
                        child: Center(child: CircularProgressIndicator()),
                      )
                    else if (_hostels.isEmpty)
                      const Text(
                        'Every hostel already has a warden. Reassign one from the '
                        'Hostels screen first.',
                        style: TextStyle(fontSize: 12.5, color: Palette.inkSecondary),
                      )
                    else
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final h in _hostels)
                            ChoiceChip(
                              selected: _hostelId == h.id,
                              onSelected: (_) => setState(() => _hostelId = h.id),
                              label: Text(h.name, style: const TextStyle(fontSize: 13)),
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
