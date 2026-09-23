import 'package:flutter/material.dart';

import '../core/palette.dart';

enum DurationUnit { hours, days, weeks, months }

extension DurationUnitLabel on DurationUnit {
  String get label => switch (this) {
        DurationUnit.hours => 'Hours',
        DurationUnit.days => 'Days',
        DurationUnit.weeks => 'Weeks',
        DurationUnit.months => 'Months',
      };

  /// Months is a calendar-fuzzy unit; 30 days is close enough for a work
  /// deadline, which nobody is going to dispute to the hour.
  double get toHours => switch (this) {
        DurationUnit.hours => 1,
        DurationUnit.days => 24,
        DurationUnit.weeks => 24 * 7,
        DurationUnit.months => 24 * 30,
      };
}

/// What an officer or admin optionally attaches at the moment of allotment:
/// free-text instructions (any language) and a duration for this specific
/// task. Both are optional - skipping keeps the allotment as fast as it was
/// before this existed, applying the system's default SLA with no note.
class AllotmentDetails {
  final String? instructions;
  final double? durationHours;

  const AllotmentDetails({this.instructions, this.durationHours});
}

/// Returns the details to send with the allotment, or null if the whole
/// allotment should be cancelled (back/dismiss) - not just this sheet.
class AllotmentDetailsSheet extends StatefulWidget {
  const AllotmentDetailsSheet({super.key});

  static Future<AllotmentDetails?> show(BuildContext context) {
    return showModalBottomSheet<AllotmentDetails>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => const AllotmentDetailsSheet(),
    );
  }

  @override
  State<AllotmentDetailsSheet> createState() => _AllotmentDetailsSheetState();
}

class _AllotmentDetailsSheetState extends State<AllotmentDetailsSheet> {
  final _instructions = TextEditingController();
  final _amount = TextEditingController();
  DurationUnit _unit = DurationUnit.hours;

  @override
  void dispose() {
    _instructions.dispose();
    _amount.dispose();
    super.dispose();
  }

  void _confirm() {
    final amount = double.tryParse(_amount.text.trim());
    Navigator.of(context).pop(AllotmentDetails(
      instructions: _instructions.text.trim().isEmpty ? null : _instructions.text.trim(),
      durationHours: amount != null && amount > 0 ? amount * _unit.toHours : null,
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Palette.grid,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              const Text(
                'Anything to tell the worker?',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 4),
              const Text(
                'Optional. Skip this to allot right away with the usual deadline.',
                style: TextStyle(fontSize: 13, color: Palette.inkSecondary),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _instructions,
                maxLines: 3,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  labelText: 'Instructions',
                  hintText: 'e.g. Poore corridor ko saaf karo, dono taraf se',
                ),
              ),
              const SizedBox(height: 14),
              const Text(
                'HOW LONG DO THEY HAVE',
                style: TextStyle(
                  fontSize: 10.5,
                  letterSpacing: 1.6,
                  fontWeight: FontWeight.w700,
                  color: Palette.inkMuted,
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _amount,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(hintText: 'e.g. 3'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    flex: 2,
                    child: DropdownButtonFormField<DurationUnit>(
                      initialValue: _unit,
                      items: [
                        for (final u in DurationUnit.values)
                          DropdownMenuItem(value: u, child: Text(u.label)),
                      ],
                      onChanged: (u) => setState(() => _unit = u ?? _unit),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              const Text(
                'Leave blank to keep the default deadline.',
                style: TextStyle(fontSize: 11.5, color: Palette.inkMuted),
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(context)
                          .pop(const AllotmentDetails()),
                      child: const Text('Skip'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton(
                      onPressed: _confirm,
                      child: const Text('Confirm'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
