import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api_client.dart';
import '../../core/palette.dart';
import '../../core/theme.dart';
import '../../shared/ui.dart';

const _categoryOptions = <String, String>{
  'DEPARTMENT': 'Department / academic',
  'BOYS_HOSTEL': 'Boys hostel',
  'GIRLS_HOSTEL': 'Girls hostel',
  'FACILITY': 'Facility',
  'RESIDENCE': 'Residence',
};

/// Admin-only: adds one named place to the picker every complaint form uses.
///
/// A fresh production install has none of these - seed-production.js
/// deliberately creates only the admin account, nothing else - so this is
/// the only way a hostel (or any other place) becomes selectable without
/// someone hand-calling the API.
class AddLandmarkScreen extends StatefulWidget {
  const AddLandmarkScreen({super.key});

  @override
  State<AddLandmarkScreen> createState() => _AddLandmarkScreenState();
}

class _AddLandmarkScreenState extends State<AddLandmarkScreen> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();

  String _category = 'DEPARTMENT';
  int? _zoneCode;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      final res = await context.read<ApiClient>().post('/landmarks', {
        'name': _name.text.trim(),
        'category': _category,
        if (_zoneCode != null) 'zoneCode': _zoneCode,
      });
      if (mounted) {
        Navigator.of(context).pop(true);
        showSnack(context, res['message'] as String? ?? 'Landmark added');
      }
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isHostel = _category == 'BOYS_HOSTEL' || _category == 'GIRLS_HOSTEL';

    return Scaffold(
      appBar: AppBar(title: const Text('New landmark')),
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
                      'A named place every complaint form picker offers - the '
                      'zone says which part of campus, this says which building.',
                      style: TextStyle(fontSize: 12.5, color: Palette.inkSecondary, height: 1.4),
                    ),
                    const SizedBox(height: 20),
                    TextFormField(
                      controller: _name,
                      textCapitalization: TextCapitalization.words,
                      decoration: const InputDecoration(
                        labelText: 'Name',
                        hintText: 'e.g. Raman Bhawan',
                        prefixIcon: Icon(Icons.place_outlined),
                      ),
                      validator: (v) =>
                          (v == null || v.trim().length < 2) ? 'Enter a name' : null,
                    ),
                    const SizedBox(height: 20),
                    const Text(
                      'CATEGORY',
                      style: TextStyle(
                        fontSize: 10.5,
                        letterSpacing: 1.8,
                        fontWeight: FontWeight.w700,
                        color: Palette.inkMuted,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final entry in _categoryOptions.entries)
                          ChoiceChip(
                            selected: _category == entry.key,
                            onSelected: (_) => setState(() => _category = entry.key),
                            label: Text(entry.value, style: const TextStyle(fontSize: 13)),
                            selectedColor: AppTheme.seed,
                            labelStyle: TextStyle(
                              color: _category == entry.key ? Colors.white : Palette.inkPrimary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                      ],
                    ),
                    if (isHostel) ...[
                      const SizedBox(height: 10),
                      Container(
                        padding: const EdgeInsets.all(11),
                        decoration: BoxDecoration(
                          color: AppTheme.seed.withValues(alpha: 0.07),
                          borderRadius: BorderRadius.circular(9),
                        ),
                        child: const Text(
                          'Hostel-category landmarks are what students can file a '
                          '"from inside a hostel" complaint against. Assign a '
                          'warden to it afterwards from Hostels & wardens.',
                          style: TextStyle(fontSize: 12, height: 1.35, color: AppTheme.seed),
                        ),
                      ),
                    ],
                    const SizedBox(height: 20),
                    const Text(
                      'ZONE (OPTIONAL)',
                      style: TextStyle(
                        fontSize: 10.5,
                        letterSpacing: 1.8,
                        fontWeight: FontWeight.w700,
                        color: Palette.inkMuted,
                      ),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'Only used to sanity-check a GPS fix against what the '
                      'reporter picked - never to override it. Leave blank if '
                      'unsure.',
                      style: TextStyle(fontSize: 12, color: Palette.inkSecondary, height: 1.35),
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        ChoiceChip(
                          selected: _zoneCode == null,
                          onSelected: (_) => setState(() => _zoneCode = null),
                          label: const Text('None', style: TextStyle(fontSize: 13)),
                        ),
                        for (var code = 1; code <= 8; code++)
                          ChoiceChip(
                            selected: _zoneCode == code,
                            onSelected: (_) => setState(() => _zoneCode = code),
                            label: Text('Zone $code', style: const TextStyle(fontSize: 13)),
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
                          : const Text('Add landmark'),
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
