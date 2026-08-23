import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../../core/api_client.dart';
import '../../core/models.dart';
import '../../core/palette.dart';
import '../../core/session.dart';
import '../../core/theme.dart';
import '../../shared/ui.dart';

class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _phone = TextEditingController();
  final _password = TextEditingController();

  Role _role = Role.resident;
  int? _zoneCode;

  /// Workers and officers both pick a zone and both wait on the admin. Only
  /// what the zone means to them differs.
  bool get _needsZone => _role == Role.worker || _role == Role.officer;
  File? _idProof;

  List<Zone> _zones = const [];
  bool _loadingZones = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _phone.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _loadZones() async {
    if (_zones.isNotEmpty || _loadingZones) return;
    setState(() => _loadingZones = true);
    try {
      final res = await context.read<ApiClient>().get('/zones');
      final list = (res['zones'] as List)
          .map((z) => Zone.fromJson(z as Map<String, dynamic>))
          .toList();
      if (mounted) setState(() => _zones = list);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loadingZones = false);
    }
  }

  Future<void> _pickIdProof() async {
    final picked = await ImagePicker().pickImage(
      source: ImageSource.camera,
      imageQuality: 70,
      maxWidth: 1600,
    );
    if (picked != null && mounted) setState(() => _idProof = File(picked.path));
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;

    if (_needsZone && _zoneCode == null) {
      setState(() => _error = _role == Role.worker
          ? 'Choose the zone you will work in'
          : 'Choose the zone you want to run');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      final message = await context.read<Session>().register(
            name: _name.text.trim(),
            email: _email.text.trim(),
            password: _password.text,
            phone: _phone.text.trim(),
            role: _role,
            zoneCode: _zoneCode,
            idProof: _idProof,
          );
      if (mounted) {
        Navigator.of(context).popUntil((r) => r.isFirst);
        showSnack(context, message);
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
      appBar: AppBar(title: const Text('Create an account')),
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
                      'I AM A',
                      style: TextStyle(
                        fontSize: 10.5,
                        letterSpacing: 1.8,
                        fontWeight: FontWeight.w700,
                        color: Palette.inkMuted,
                      ),
                    ),
                    const SizedBox(height: 10),
                    // A 2x2 grid rather than a segmented control: four roles
                    // will not fit across a phone, and each one needs a line of
                    // explanation anyway - "Resident" and "Student" are not
                    // self-explanatory when both can file complaints.
                    GridView.count(
                      crossAxisCount: 2,
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      mainAxisSpacing: 10,
                      crossAxisSpacing: 10,
                      childAspectRatio: 2.5,
                      children: [
                        for (final option in _roleOptions)
                          _RoleCard(
                            option: option,
                            selected: _role == option.role,
                            onTap: () {
                              setState(() {
                                _role = option.role;
                                // A zone chosen as a worker means something
                                // different as an officer, so never carry the
                                // choice across.
                                _zoneCode = null;
                              });
                              if (_needsZone) _loadZones();
                            },
                          ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Text(
                      _roleOptions.firstWhere((o) => o.role == _role).blurb,
                      style: const TextStyle(
                          fontSize: 12.5, color: Palette.inkSecondary, height: 1.35),
                    ),

                    const SizedBox(height: 22),
                    TextFormField(
                      controller: _name,
                      textCapitalization: TextCapitalization.words,
                      decoration: const InputDecoration(
                        labelText: 'Full name',
                        prefixIcon: Icon(Icons.badge_outlined),
                      ),
                      validator: (v) =>
                          (v == null || v.trim().length < 2) ? 'Enter your full name' : null,
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _email,
                      keyboardType: TextInputType.emailAddress,
                      decoration: const InputDecoration(
                        labelText: 'Email',
                        prefixIcon: Icon(Icons.alternate_email),
                      ),
                      validator: (v) =>
                          (v == null || !v.contains('@')) ? 'Enter a valid email' : null,
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _phone,
                      keyboardType: TextInputType.phone,
                      decoration: const InputDecoration(
                        labelText: 'Phone',
                        prefixIcon: Icon(Icons.phone_outlined),
                      ),
                      validator: (v) => (v == null || v.trim().length < 10)
                          ? 'Enter a 10-digit phone number'
                          : null,
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
                      validator: (v) =>
                          (v == null || v.length < 6) ? 'Use at least 6 characters' : null,
                    ),

                    if (_needsZone) ...[
                      const SizedBox(height: 24),
                      Text(
                        _role == Role.worker ? 'YOUR ZONE' : 'ZONE YOU WANT TO RUN',
                        style: const TextStyle(
                          fontSize: 10.5,
                          letterSpacing: 1.8,
                          fontWeight: FontWeight.w700,
                          color: Palette.inkMuted,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _role == Role.worker
                            ? 'You will be given work in this zone, and can be lent '
                                'to a nearby zone when it needs help.'
                            : 'A zone has one officer. If someone already runs the '
                                'one you pick, you will be told straight away.',
                        style: const TextStyle(
                            fontSize: 12.5, color: Palette.inkSecondary, height: 1.35),
                      ),
                      const SizedBox(height: 12),
                      if (_loadingZones)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 20),
                          child: Center(child: CircularProgressIndicator()),
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
                      const SizedBox(height: 18),
                      OutlinedButton.icon(
                        onPressed: _pickIdProof,
                        icon: Icon(_idProof == null
                            ? Icons.add_a_photo_outlined
                            : Icons.check_circle_outline),
                        label: Text(_idProof == null
                            ? (_role == Role.worker
                                ? 'Add a photo of your ID'
                                : 'Add a photo of your staff ID')
                            : 'ID photo added — tap to retake'),
                      ),
                      if (_idProof != null) ...[
                        const SizedBox(height: 10),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: Image.file(_idProof!, height: 130, fit: BoxFit.cover),
                        ),
                      ],
                    ],

                    if (_error != null) ...[
                      const SizedBox(height: 18),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Palette.critical.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: Palette.critical.withValues(alpha: 0.3)),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Icon(Icons.error_outline,
                                color: Palette.critical, size: 19),
                            const SizedBox(width: 9),
                            Expanded(
                              child: Text(
                                _error!,
                                style: const TextStyle(
                                    color: Palette.critical, height: 1.35, fontSize: 13.5),
                              ),
                            ),
                          ],
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
                              child: CircularProgressIndicator(
                                  strokeWidth: 2.2, color: Colors.white),
                            )
                          : const Text('Create account'),
                    ),
                    const SizedBox(height: 24),
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

/// One choice on the signup screen.
class _RoleOption {
  const _RoleOption(this.role, this.label, this.icon, this.blurb);

  final Role role;
  final String label;
  final IconData icon;
  final String blurb;
}

const _roleOptions = <_RoleOption>[
  _RoleOption(
    Role.resident,
    'Resident',
    Icons.home_outlined,
    'Faculty, staff and families living on campus. Your complaints are '
        'visible to other residents.',
  ),
  _RoleOption(
    Role.student,
    'Student',
    Icons.school_outlined,
    'Students living in the hostels or attending classes. Your complaints '
        'are visible to other students.',
  ),
  _RoleOption(
    Role.worker,
    'Worker',
    Icons.cleaning_services_outlined,
    'Cleaning staff. An admin verifies your account before you can be given '
        'any work.',
  ),
  _RoleOption(
    Role.officer,
    'Officer',
    Icons.shield_outlined,
    'You run one zone: complaints from it come to you, and you allot them to '
        'your workers. An admin approves you before the zone is yours.',
  ),
];

class _RoleCard extends StatelessWidget {
  const _RoleCard({
    required this.option,
    required this.selected,
    required this.onTap,
  });

  final _RoleOption option;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;

    return Material(
      color: selected ? accent.withValues(alpha: 0.10) : Colors.transparent,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected ? accent : Palette.grid,
              width: selected ? 1.8 : 1,
            ),
          ),
          child: Row(
            children: [
              Icon(
                option.icon,
                size: 20,
                color: selected ? accent : Palette.inkSecondary,
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  option.label,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                    color: selected ? accent : Palette.inkPrimary,
                  ),
                ),
              ),
            ],
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
                decoration:
                    BoxDecoration(color: color, borderRadius: BorderRadius.circular(3)),
              ),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    zone.name,
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
                  ),
                  Text(
                    zone.label,
                    style: const TextStyle(fontSize: 11, color: Palette.inkSecondary),
                  ),
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
