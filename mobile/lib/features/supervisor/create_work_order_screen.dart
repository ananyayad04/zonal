import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api_client.dart';
import '../../core/models.dart';
import '../../core/palette.dart';
import '../../core/theme.dart';
import '../../shared/allotment_details_sheet.dart';
import '../../shared/pick_any_worker_sheet.dart';
import '../../shared/ui.dart';

/// Worker Supervisor creates a work order directly - no citizen complaint
/// behind it. Four simple steps: which zone, what type of work, describe the
/// area and what needs doing in plain language, then allot a worker.
class CreateWorkOrderScreen extends StatefulWidget {
  const CreateWorkOrderScreen({super.key});

  @override
  State<CreateWorkOrderScreen> createState() => _CreateWorkOrderScreenState();
}

class _CreateWorkOrderScreenState extends State<CreateWorkOrderScreen> {
  final _description = TextEditingController();

  List<Zone> _zones = const [];
  bool _loadingZones = true;
  int? _zoneCode;
  String _category = 'GARBAGE';

  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadZones();
  }

  @override
  void dispose() {
    _description.dispose();
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

  bool get _canSubmit => _zoneCode != null && _description.text.trim().length >= 3 && !_busy;

  Future<void> _submit() async {
    if (_zoneCode == null) {
      setState(() => _error = 'Choose which zone this work is in');
      return;
    }
    if (_description.text.trim().length < 3) {
      setState(() => _error = 'Describe the work - which area, and what needs doing');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });

    // Allotting a worker is the last step, but it is not compulsory here -
    // if nobody is free right now the work order is still worth saving; it
    // simply waits in the unallotted queue like any other.
    String? workerUserId;
    AllotmentDetails? details;

    try {
      final res = await context.read<ApiClient>().get('/admin/free-workers');
      final options = flattenFreeWorkers((res['zones'] as List).cast<Map<String, dynamic>>());

      if (!mounted) return;

      if (options.isEmpty) {
        showSnack(context, 'No worker is free right now - saving it to allot later', error: false);
      } else {
        workerUserId = await PickAnyWorkerSheet.show(context, options);
        if (!mounted) return;
        if (workerUserId != null) {
          details = await AllotmentDetailsSheet.show(context);
          if (!mounted) return;
          // Consistent with every other allotment flow in the app: dismissing
          // this sheet (rather than tapping Skip) cancels the action, not
          // just this step - it must not silently allot with no details.
          if (details == null) return;
        }
      }

      final result = await context.read<ApiClient>().post('/admin/complaints', {
        'zoneCode': _zoneCode,
        'category': _category,
        'description': _description.text.trim(),
        if (workerUserId != null) 'workerUserId': workerUserId,
        if (details?.instructions != null) 'instructions': details!.instructions,
        if (details?.durationHours != null) 'durationHours': details!.durationHours,
      });

      if (mounted) {
        Navigator.of(context).pop(true);
        showSnack(context, result['message'] as String? ?? 'Work order created');
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
      appBar: AppBar(title: const Text('Create work')),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
          child: FilledButton(
            onPressed: _canSubmit ? _submit : null,
            child: _busy
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2.2, color: Colors.white),
                  )
                : const Text('Save and allot a worker'),
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 20),
        children: [
          const _SectionLabel('1  ·  WHICH ZONE'),
          const SizedBox(height: 10),
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

          const SizedBox(height: 22),
          const _SectionLabel('2  ·  TYPE OF WORK'),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final entry in categoryLabels.entries)
                ChoiceChip(
                  selected: _category == entry.key,
                  onSelected: (_) => setState(() => _category = entry.key),
                  avatar: Icon(
                    categoryIcons[entry.key],
                    size: 17,
                    color: _category == entry.key ? Colors.white : Palette.inkSecondary,
                  ),
                  label: Text(entry.value),
                  selectedColor: AppTheme.seed,
                  labelStyle: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: _category == entry.key ? Colors.white : Palette.inkPrimary,
                  ),
                  backgroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(9),
                    side: BorderSide(
                      color: _category == entry.key ? AppTheme.seed : Colors.black.withValues(alpha: 0.12),
                    ),
                  ),
                ),
            ],
          ),

          const SizedBox(height: 22),
          const _SectionLabel('3  ·  DESCRIBE THE WORK'),
          const SizedBox(height: 4),
          const Text(
            'Plain language - which area it covers, and what needs doing.',
            style: TextStyle(fontSize: 12.5, height: 1.35, color: Palette.inkSecondary),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _description,
            // _canSubmit reads this field's length, so the Save button must
            // re-evaluate as the user types, not only when a chip is tapped.
            onChanged: (_) => setState(() {}),
            maxLines: 4,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              hintText: 'e.g. Sweep the road from the main gate to the canteen, '
                  'clear all leaves and litter',
            ),
          ),

          const SizedBox(height: 18),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppTheme.seed.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.person_add_alt, size: 18, color: AppTheme.seed),
                SizedBox(width: 9),
                Expanded(
                  child: Text(
                    '4  ·  Next, pick a free worker to allot this to - or save it '
                    'to allot later if nobody is free right now.',
                    style: TextStyle(fontSize: 12.5, height: 1.35, color: AppTheme.seed),
                  ),
                ),
              ],
            ),
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
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) => Text(
        text,
        style: const TextStyle(
          fontSize: 10.5,
          letterSpacing: 1.8,
          fontWeight: FontWeight.w700,
          color: Palette.inkMuted,
        ),
      );
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
