import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api_client.dart';
import '../../core/models.dart';
import '../../core/palette.dart';
import '../../core/theme.dart';
import '../../shared/authed_image.dart';
import '../../shared/ui.dart';
import '../shared/complaint_detail_screen.dart';

/// The first gate. A complaint is not routed to any zone officer until an
/// admin confirms it is genuine.
class VerifyComplaintsScreen extends StatefulWidget {
  const VerifyComplaintsScreen({super.key});

  @override
  State<VerifyComplaintsScreen> createState() => _VerifyComplaintsScreenState();
}

class _VerifyComplaintsScreenState extends State<VerifyComplaintsScreen> {
  late Future<List<Complaint>> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<List<Complaint>> _load() async {
    final res = await context.read<ApiClient>().get('/admin/complaints/pending');
    return (res['complaints'] as List)
        .map((c) => Complaint.fromJson(c as Map<String, dynamic>))
        .toList();
  }

  Future<void> _refresh() async {
    setState(() => _future = _load());
    await _future;
  }

  /// Zone the admin has corrected this complaint to, keyed by complaint id.
  final Map<String, int> _zoneOverrides = {};

  /// Complaints already decided in this session. Removed from the list the
  /// instant the server confirms, rather than waiting for the refetch - a
  /// card that lingers for a second after you act on it reads as "nothing
  /// happened".
  final Set<String> _decided = {};

  Future<void> _decide(Complaint c, bool approve) async {
    String? reason;

    if (!approve) {
      reason = await showDialog<String>(
        context: context,
        builder: (_) => const _RejectComplaintDialog(),
      );
      if (reason == null) return;
    }

    // The dialog was awaited, so this screen may have been disposed by now.
    if (!mounted) return;

    try {
      final res = await context.read<ApiClient>().post(
        '/admin/complaints/${c.id}/review',
        {
          'approve': approve,
          if (reason != null) 'reason': reason,
          if (approve && _zoneOverrides[c.id] != null) 'zoneCode': _zoneOverrides[c.id],
        },
      );
      if (mounted) {
        setState(() => _decided.add(c.id));
        showSnack(
          context,
          res['message'] as String? ?? (approve ? 'Verified' : 'Rejected'),
        );
        await _refresh();
      }
    } on ApiException catch (e) {
      if (mounted) showSnack(context, e.message, error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Verify complaints')),
      body: FutureBuilder<List<Complaint>>(
        future: _future,
        builder: (context, snapshot) => AsyncBody<List<Complaint>>(
          snapshot: snapshot,
          onRetry: _refresh,
          builder: (all) {
            // Drop anything decided in this session, so an acted-on card
            // disappears immediately instead of lingering until the refetch.
            final complaints = all.where((c) => !_decided.contains(c.id)).toList();

            if (complaints.isEmpty) {
              return const EmptyState(
                icon: Icons.done_all,
                title: 'Queue is clear',
                subtitle: 'New complaints land here before they go to a zone officer.',
              );
            }

            return RefreshIndicator(
              onRefresh: _refresh,
              child: ListView.builder(
                padding: const EdgeInsets.symmetric(vertical: 8),
                itemCount: complaints.length,
                itemBuilder: (_, i) => _ReviewCard(
                  complaint: complaints[i],
                  overrideZoneCode: _zoneOverrides[complaints[i].id],
                  onOverrideZone: (code) => setState(() {
                    if (code == null) {
                      _zoneOverrides.remove(complaints[i].id);
                    } else {
                      _zoneOverrides[complaints[i].id] = code;
                    }
                  }),
                  onApprove: () => _decide(complaints[i], true),
                  onReject: () => _decide(complaints[i], false),
                  onOpen: () async {
                    await Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) =>
                            ComplaintDetailScreen(complaintId: complaints[i].id),
                      ),
                    );
                    await _refresh();
                  },
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _ReviewCard extends StatelessWidget {
  final Complaint complaint;
  final int? overrideZoneCode;
  final void Function(int? code) onOverrideZone;
  final VoidCallback onApprove;
  final VoidCallback onReject;
  final VoidCallback onOpen;

  const _ReviewCard({
    required this.complaint,
    required this.overrideZoneCode,
    required this.onOverrideZone,
    required this.onApprove,
    required this.onReject,
    required this.onOpen,
  });

  String get _boundaryExplanation => switch (complaint.zoneResolvedBy) {
        'NEAREST_EDGE' =>
          'The GPS fix landed ${complaint.zoneDistanceM?.round() ?? 0}m outside every '
              'boundary — a road, the park, or a rough fix. Routed to the closest zone.',
        'OVERLAP_SMALLEST' =>
          'This spot is inside two overlapping zones. The smaller one was chosen.',
        'OUT_OF_BOUNDS' =>
          'This is ${complaint.zoneDistanceM?.round() ?? 0}m from the nearest zone, '
              'which looks off campus. Check before routing it.',
        _ => 'The zone could not be determined cleanly.',
      };

  @override
  Widget build(BuildContext context) {
    final zoneColor = colorFromHex(complaint.zone?.colorHex ?? '#0072B2');
    final photos = complaint.beforeMedia.where((m) => m.type == 'PHOTO').toList();
    final others = complaint.beforeMedia.where((m) => m.type != 'PHOTO').toList();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(15),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: zoneColor.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: zoneColor.withValues(alpha: 0.55)),
                  ),
                  child: Text(
                    complaint.zone?.name ?? 'Zone',
                    style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  complaint.ref,
                  style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w800,
                    color: Palette.inkSecondary,
                  ),
                ),
                const Spacer(),
                Text(
                  timeAgo(complaint.submittedAt),
                  style: const TextStyle(fontSize: 11, color: Palette.inkMuted),
                ),
              ],
            ),
            const SizedBox(height: 11),
            Text(
              categoryLabels[complaint.category] ?? complaint.category,
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
            ),
            if (complaint.description?.isNotEmpty ?? false) ...[
              const SizedBox(height: 4),
              Text(
                complaint.description!,
                style: const TextStyle(
                    fontSize: 13.5, height: 1.4, color: Palette.inkSecondary),
              ),
            ],
            const SizedBox(height: 6),
            Text(
              // Which community reported it is part of judging the report:
              // the same spot means something different when it comes from a
              // hostel resident than from staff quarters.
              'Reported by ${complaint.reporter?.name ?? 'someone'}'
              '${switch (complaint.reporterRole) {
                Role.student => ' · Student',
                Role.resident => ' · Resident',
                _ => '',
              }}',
              style: const TextStyle(fontSize: 12.5, color: Palette.inkMuted),
            ),

            if (photos.isNotEmpty) ...[
              const SizedBox(height: 13),
              SizedBox(
                height: 145,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: photos.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 9),
                  itemBuilder: (_, i) => AuthedImage(
                    path: photos[i].url,
                    width: 185,
                    height: 145,
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),
            ],

            if (others.isNotEmpty) ...[
              const SizedBox(height: 10),
              Wrap(
                spacing: 7,
                children: [
                  for (final m in others)
                    Chip(
                      avatar: Icon(
                        m.type == 'VIDEO' ? Icons.videocam : Icons.mic,
                        size: 15,
                      ),
                      label: Text(
                        m.type == 'VIDEO'
                            ? 'Video${m.durationSec != null ? ' ${m.durationSec}s' : ''}'
                            : 'Voice${m.durationSec != null ? ' ${m.durationSec}s' : ''}',
                        style: const TextStyle(fontSize: 11.5),
                      ),
                      visualDensity: VisualDensity.compact,
                      backgroundColor: Palette.grid,
                    ),
                ],
              ),
            ],

            const SizedBox(height: 10),
            Row(
              children: [
                const Icon(Icons.place_outlined, size: 15, color: Palette.inkMuted),
                const SizedBox(width: 5),
                Text(
                  '${complaint.lat.toStringAsFixed(5)}, ${complaint.lng.toStringAsFixed(5)}',
                  style: const TextStyle(fontSize: 11.5, color: Palette.inkMuted),
                ),
                const Spacer(),
                TextButton(
                  onPressed: onOpen,
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                  ),
                  child: const Text('Full detail', style: TextStyle(fontSize: 12.5)),
                ),
              ],
            ),

            // A complaint whose zone was not a clean polygon hit gets a human
            // decision here, before it reaches any officer.
            if (complaint.isBoundaryCase) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Palette.warning.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Palette.warning.withValues(alpha: 0.45)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(Icons.wrong_location_outlined,
                            size: 19, color: Palette.warning),
                        const SizedBox(width: 9),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Filed between zones',
                                style: TextStyle(
                                    fontSize: 13.5, fontWeight: FontWeight.w800),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                _boundaryExplanation,
                                style: const TextStyle(
                                    fontSize: 12, height: 1.35, color: Palette.inkSecondary),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        const Text(
                          'Route to',
                          style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: DropdownButtonFormField<int>(
                            initialValue: overrideZoneCode ?? complaint.zone?.code,
                            isExpanded: true,
                            decoration: const InputDecoration(
                              isDense: true,
                              contentPadding:
                                  EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                            ),
                            items: [
                              for (var code = 1; code <= 8; code++)
                                DropdownMenuItem(
                                  value: code,
                                  child: Text('Zone $code',
                                      style: const TextStyle(fontSize: 13)),
                                ),
                            ],
                            onChanged: (code) => onOverrideZone(
                              code == complaint.zone?.code ? null : code,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],

            const SizedBox(height: 13),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: Palette.good,
                      minimumSize: const Size.fromHeight(44),
                    ),
                    onPressed: onApprove,
                    icon: const Icon(Icons.check, size: 19),
                    label: Text(
                      overrideZoneCode != null
                          ? 'Verify → Zone $overrideZoneCode'
                          : 'Verify & route',
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Palette.critical,
                      side: const BorderSide(color: Palette.critical),
                      minimumSize: const Size.fromHeight(44),
                    ),
                    onPressed: onReject,
                    icon: const Icon(Icons.close, size: 19),
                    label: const Text('Reject'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _RejectComplaintDialog extends StatefulWidget {
  const _RejectComplaintDialog();

  @override
  State<_RejectComplaintDialog> createState() => _RejectComplaintDialogState();
}

class _RejectComplaintDialogState extends State<_RejectComplaintDialog> {
  final _reason = TextEditingController();

  static const _presets = [
    'Not a cleanliness issue',
    'Photo is unclear',
    'Duplicate of another complaint',
    'Outside campus',
  ];

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Reject this complaint'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'The person who reported it sees this reason.',
            style: TextStyle(fontSize: 13, color: Palette.inkSecondary),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final p in _presets)
                ActionChip(
                  label: Text(p, style: const TextStyle(fontSize: 11.5)),
                  onPressed: () => setState(() => _reason.text = p),
                  visualDensity: VisualDensity.compact,
                ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _reason,
            maxLines: 2,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(hintText: 'Reason'),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: Palette.critical),
          onPressed: () => Navigator.of(context).pop(
            _reason.text.trim().isEmpty ? 'Rejected by admin' : _reason.text.trim(),
          ),
          child: const Text('Reject'),
        ),
      ],
    );
  }
}
