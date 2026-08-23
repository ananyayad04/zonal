import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api_client.dart';
import '../../core/models.dart';
import '../../core/palette.dart';
import '../../shared/ui.dart';

/// The tick-OK step. Confirming closes the complaint; sending it back returns
/// it to the same worker once, after which it goes to the admin instead of
/// bouncing back and forth.
class SatisfactionSheet extends StatefulWidget {
  final Complaint complaint;
  final bool satisfied;

  const SatisfactionSheet({
    super.key,
    required this.complaint,
    required this.satisfied,
  });

  static Future<bool?> show(
    BuildContext context, {
    required Complaint complaint,
    required bool satisfied,
  }) {
    return showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: SatisfactionSheet(complaint: complaint, satisfied: satisfied),
      ),
    );
  }

  @override
  State<SatisfactionSheet> createState() => _SatisfactionSheetState();
}

class _SatisfactionSheetState extends State<SatisfactionSheet> {
  final _note = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    // Required either way. Signing off is the only moment anyone hears from
    // the person the work was actually for, and a bare tick tells the officer
    // nothing about whether the fix will hold.
    if (_note.text.trim().length < 3) {
      setState(() => _error = widget.satisfied
          ? 'Say a few words about the work'
          : 'Tell the worker what is still wrong');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      final res = await context.read<ApiClient>().post(
        '/complaints/${widget.complaint.id}/satisfaction',
        {
          'satisfied': widget.satisfied,
          'note': _note.text.trim(),
        },
      );

      if (mounted) {
        Navigator.of(context).pop(true);
        showSnack(context, res['message'] as String? ?? 'Done');
      }
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isLastChance = widget.complaint.reopenCount >= 1;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 24),
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
          Row(
            children: [
              Icon(
                widget.satisfied ? Icons.check_circle : Icons.replay_circle_filled,
                color: widget.satisfied ? Palette.good : Palette.serious,
                size: 26,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  widget.satisfied ? 'Close this complaint' : 'Send it back',
                  style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            widget.satisfied
                ? 'The area is clean and this complaint is finished. '
                    '${widget.complaint.worker?.name ?? 'The worker'} gets credit for it.'
                : isLastChance
                    ? 'You have already sent this back once. Sending it back again '
                        'passes it to the campus admin.'
                    : '${widget.complaint.worker?.name ?? 'The worker'} will be asked '
                        'to do it again.',
            style: const TextStyle(
                fontSize: 13.5, height: 1.45, color: Palette.inkSecondary),
          ),
          const SizedBox(height: 18),
          TextField(
            controller: _note,
            maxLines: 3,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(
              labelText: widget.satisfied
                  ? 'How was the work?'
                  : 'What is still wrong?',
              hintText: widget.satisfied
                  ? 'Cleaned properly, no complaints now'
                  : null,
              alignLabelWithHint: true,
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(
              _error!,
              style: const TextStyle(color: Palette.critical, fontSize: 13),
            ),
          ],
          const SizedBox(height: 20),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: widget.satisfied ? Palette.good : Palette.serious,
            ),
            onPressed: _busy ? null : _submit,
            child: _busy
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2.2, color: Colors.white),
                  )
                : Text(widget.satisfied ? 'Confirm and close' : 'Send back to worker'),
          ),
        ],
      ),
    );
  }
}
