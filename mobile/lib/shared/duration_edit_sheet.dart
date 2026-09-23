import 'package:flutter/material.dart';

import '../core/palette.dart';
// Unnamed extensions (DurationUnit.label/toHours) can't be selectively
// `show`n, so this is a full import rather than `show DurationUnit`.
import 'allotment_details_sheet.dart';

/// Edits the deadline on a task that is already out with a worker - the
/// counterpart to AllotmentDetailsSheet's duration picker, but standalone:
/// no instructions field, because the task is already allotted and running.
class DurationEditSheet extends StatefulWidget {
  const DurationEditSheet({super.key});

  static Future<double?> show(BuildContext context) {
    return showModalBottomSheet<double>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => const DurationEditSheet(),
    );
  }

  @override
  State<DurationEditSheet> createState() => _DurationEditSheetState();
}

class _DurationEditSheetState extends State<DurationEditSheet> {
  final _amount = TextEditingController();
  DurationUnit _unit = DurationUnit.hours;
  String? _error;

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  void _confirm() {
    final amount = double.tryParse(_amount.text.trim());
    if (amount == null || amount <= 0) {
      setState(() => _error = 'Enter how much time they should have');
      return;
    }
    Navigator.of(context).pop(amount * _unit.toHours);
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
                'New deadline',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 4),
              const Text(
                'Counted from now, not from when they started.',
                style: TextStyle(fontSize: 13, color: Palette.inkSecondary),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _amount,
                      autofocus: true,
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
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(_error!, style: const TextStyle(color: Palette.critical, fontSize: 12.5)),
              ],
              const SizedBox(height: 18),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Cancel'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton(
                      onPressed: _confirm,
                      child: const Text('Update'),
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
