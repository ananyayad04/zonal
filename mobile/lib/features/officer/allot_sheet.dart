import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api_client.dart';
import '../../core/models.dart';
import '../../core/palette.dart';
import '../../core/theme.dart';
import '../../shared/allotment_details_sheet.dart';
import '../../shared/ui.dart';

/// Allotment.
///
/// The engine does the picking - least-loaded free worker in the zone - and
/// the officer confirms or overrides. When the officer has nobody free, the
/// only path forward is asking a nearby zone, and that is what this sheet
/// offers instead.
class AllotSheet extends StatefulWidget {
  final Complaint complaint;

  const AllotSheet({super.key, required this.complaint});

  static Future<bool?> show(BuildContext context, {required Complaint complaint}) {
    return showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => AllotSheet(complaint: complaint),
    );
  }

  @override
  State<AllotSheet> createState() => _AllotSheetState();
}

class _AllotSheetState extends State<AllotSheet> {
  late Future<Map<String, dynamic>> _future;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<Map<String, dynamic>> _load() => context
      .read<ApiClient>()
      .get('/officer/complaints/${widget.complaint.id}/candidates');

  Future<void> _allot(String workerUserId) async {
    final details = await AllotmentDetailsSheet.show(context);
    if (details == null || !mounted) return;

    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      final res = await context.read<ApiClient>().post(
        '/officer/complaints/${widget.complaint.id}/allot',
        {
          'workerUserId': workerUserId,
          if (details.instructions != null) 'instructions': details.instructions,
          if (details.durationHours != null) 'durationHours': details.durationHours,
        },
      );
      if (mounted) {
        Navigator.of(context).pop(true);
        showSnack(context, res['message'] as String? ?? 'Worker allotted');
      }
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _askForHelp() async {
    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      final res = await context
          .read<ApiClient>()
          .post('/officer/complaints/${widget.complaint.id}/ask-help');

      if (mounted) {
        Navigator.of(context).pop(true);
        showSnack(
          context,
          res['message'] as String? ?? 'Help requested',
          error: res['escalated'] == true,
        );
      }
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      maxChildSize: 0.92,
      builder: (context, scrollController) => FutureBuilder<Map<String, dynamic>>(
        future: _future,
        builder: (context, snapshot) => AsyncBody<Map<String, dynamic>>(
          snapshot: snapshot,
          onRetry: () async => setState(() => _future = _load()),
          builder: (data) {
            final suggested = data['suggested'] as Map<String, dynamic>?;
            final free = (data['freeWorkers'] as List).cast<Map<String, dynamic>>();
            final canHelp = (data['canHelp'] as List).cast<Map<String, dynamic>>();
            final mustAsk = data['mustAskForHelp'] == true;

            return ListView(
              controller: scrollController,
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 28),
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
                Text(
                  mustAsk ? 'No free worker in your zone' : 'Allot a worker',
                  style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 5),
                Text(
                  mustAsk
                      ? 'Every worker in your zone is busy or off duty. Ask the '
                          'nearest zones that do have someone free.'
                      : '${widget.complaint.ref} · '
                          '${categoryLabels[widget.complaint.category] ?? widget.complaint.category}',
                  style: const TextStyle(
                      fontSize: 13.5, height: 1.4, color: Palette.inkSecondary),
                ),

                if (suggested != null) ...[
                  const SizedBox(height: 20),
                  const Text(
                    'SUGGESTED',
                    style: TextStyle(
                      fontSize: 10.5,
                      letterSpacing: 1.8,
                      fontWeight: FontWeight.w700,
                      color: Palette.good,
                    ),
                  ),
                  const SizedBox(height: 8),
                  _WorkerRow(
                    name: suggested['name'] as String,
                    subtitle: suggested['reason'] as String? ?? '',
                    highlighted: true,
                    busy: _busy,
                    onTap: () => _allot(suggested['userId'] as String),
                  ),
                ],

                if (free.length > 1) ...[
                  const SizedBox(height: 22),
                  const Text(
                    'OR CHOOSE SOMEONE ELSE',
                    style: TextStyle(
                      fontSize: 10.5,
                      letterSpacing: 1.8,
                      fontWeight: FontWeight.w700,
                      color: Palette.inkMuted,
                    ),
                  ),
                  const SizedBox(height: 8),
                  for (final w in free.skip(1))
                    _WorkerRow(
                      name: w['name'] as String,
                      subtitle: '${w['tasksCompletedToday'] ?? 0} done today',
                      busy: _busy,
                      onTap: () => _allot(w['userId'] as String),
                    ),
                ],

                if (mustAsk) ...[
                  const SizedBox(height: 22),
                  if (canHelp.isEmpty)
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: Palette.critical.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(11),
                        border:
                            Border.all(color: Palette.critical.withValues(alpha: 0.3)),
                      ),
                      child: const Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(Icons.report_problem_outlined,
                              color: Palette.critical, size: 20),
                          SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              'No worker is free anywhere on campus right now. '
                              'Asking will send this straight to the admin.',
                              style: TextStyle(
                                  fontSize: 13, height: 1.4, color: Palette.critical),
                            ),
                          ),
                        ],
                      ),
                    )
                  else ...[
                    const Text(
                      'THESE ZONES HAVE SOMEONE FREE',
                      style: TextStyle(
                        fontSize: 10.5,
                        letterSpacing: 1.8,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF7A52CC),
                      ),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'Nearest first. All of them are asked at once, and whoever '
                      'answers first lends the worker.',
                      style: TextStyle(
                          fontSize: 12.5, height: 1.35, color: Palette.inkSecondary),
                    ),
                    const SizedBox(height: 12),
                    for (final z in canHelp)
                      Container(
                        margin: const EdgeInsets.only(bottom: 9),
                        padding: const EdgeInsets.all(13),
                        decoration: BoxDecoration(
                          color: const Color(0xFF7A52CC).withValues(alpha: 0.07),
                          borderRadius: BorderRadius.circular(11),
                          border: Border.all(
                              color: const Color(0xFF7A52CC).withValues(alpha: 0.3)),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.location_on_outlined,
                                size: 19, color: Color(0xFF7A52CC)),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '${(z['zone'] as Map)['name']} · '
                                    '${(z['zone'] as Map)['label']}',
                                    style: const TextStyle(
                                        fontSize: 13.5, fontWeight: FontWeight.w700),
                                  ),
                                  Text(
                                    'Officer ${(z['officer'] as Map?)?['name'] ?? '-'}',
                                    style: const TextStyle(
                                        fontSize: 12, color: Palette.inkSecondary),
                                  ),
                                ],
                              ),
                            ),
                            Text(
                              '${z['freeWorkerCount']} free',
                              style: const TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w700,
                                color: Color(0xFF7A52CC),
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: canHelp.isEmpty
                          ? Palette.critical
                          : const Color(0xFF7A52CC),
                    ),
                    onPressed: _busy ? null : _askForHelp,
                    icon: const Icon(Icons.handshake_outlined, size: 20),
                    label: Text(canHelp.isEmpty
                        ? 'Send to the admin'
                        : 'Ask ${canHelp.length} zone${canHelp.length == 1 ? '' : 's'} for help'),
                  ),
                ],

                if (_error != null) ...[
                  const SizedBox(height: 16),
                  Text(
                    _error!,
                    style: const TextStyle(color: Palette.critical, fontSize: 13),
                  ),
                ],
              ],
            );
          },
        ),
      ),
    );
  }
}

class _WorkerRow extends StatelessWidget {
  final String name;
  final String subtitle;
  final bool highlighted;
  final bool busy;
  final VoidCallback onTap;

  const _WorkerRow({
    required this.name,
    required this.subtitle,
    this.highlighted = false,
    required this.busy,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 9),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: busy ? null : onTap,
          borderRadius: BorderRadius.circular(11),
          child: Container(
            padding: const EdgeInsets.all(13),
            decoration: BoxDecoration(
              color: highlighted ? Palette.good.withValues(alpha: 0.08) : Colors.white,
              borderRadius: BorderRadius.circular(11),
              border: Border.all(
                color: highlighted
                    ? Palette.good.withValues(alpha: 0.5)
                    : Colors.black.withValues(alpha: 0.12),
                width: highlighted ? 1.6 : 1,
              ),
            ),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 18,
                  backgroundColor: highlighted
                      ? Palette.good.withValues(alpha: 0.16)
                      : Palette.grid,
                  child: Text(
                    name.isEmpty ? '?' : name[0].toUpperCase(),
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                      color: highlighted ? Palette.good : Palette.inkSecondary,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        style: const TextStyle(
                            fontSize: 15, fontWeight: FontWeight.w700),
                      ),
                      if (subtitle.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          subtitle,
                          style: const TextStyle(
                              fontSize: 12, color: Palette.inkSecondary),
                        ),
                      ],
                    ],
                  ),
                ),
                Icon(
                  Icons.arrow_forward_ios,
                  size: 15,
                  color: highlighted ? Palette.good : Palette.inkMuted,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
