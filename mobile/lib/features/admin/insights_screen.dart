import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api_client.dart';
import '../../core/palette.dart';
import '../../core/theme.dart';
import '../../shared/ui.dart';

/// What the system noticed on its own.
///
/// Every other screen answers a question somebody asked. This one volunteers
/// three things nobody did: places that are probably broken rather than dirty,
/// a zone that needs another pair of hands, and spots that were signed off and
/// went bad again.
class InsightsScreen extends StatefulWidget {
  const InsightsScreen({super.key});

  @override
  State<InsightsScreen> createState() => _InsightsScreenState();
}

class _InsightsScreenState extends State<InsightsScreen> {
  late Future<Map<String, dynamic>> _future;
  int _days = 30;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<Map<String, dynamic>> _load() =>
      context.read<ApiClient>().get('/analytics/insights', query: {'days': _days});

  Future<void> _refresh() async {
    setState(() => _future = _load());
    await _future;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Insights')),
      body: FutureBuilder<Map<String, dynamic>>(
        future: _future,
        builder: (context, snapshot) => AsyncBody<Map<String, dynamic>>(
          snapshot: snapshot,
          onRetry: _refresh,
          builder: (data) {
            final hotspots = (data['hotspots'] as List).cast<Map<String, dynamic>>();
            final staffing = data['staffing'] as Map<String, dynamic>;
            final recurrences = (data['recurrences'] as List).cast<Map<String, dynamic>>();
            final hostels = data['hostels'] as Map<String, dynamic>?;
            final unassignedHostels =
                (hostels?['unassignedHostels'] as List? ?? const []).cast<Map<String, dynamic>>();
            final structural = hotspots.where((h) => h['likelyStructural'] == true).toList();
            final busy = hotspots.where((h) => h['likelyStructural'] != true).toList();

            return RefreshIndicator(
              onRefresh: _refresh,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 30),
                children: [
                  Row(
                    children: [
                      const Text(
                        'LAST',
                        style: TextStyle(
                          fontSize: 10.5,
                          letterSpacing: 1.6,
                          fontWeight: FontWeight.w700,
                          color: Palette.inkMuted,
                        ),
                      ),
                      const SizedBox(width: 10),
                      for (final d in [7, 30, 90])
                        Padding(
                          padding: const EdgeInsets.only(right: 7),
                          child: ChoiceChip(
                            selected: _days == d,
                            onSelected: (_) {
                              setState(() => _days = d);
                              _refresh();
                            },
                            label: Text('${d}d', style: const TextStyle(fontSize: 12)),
                            visualDensity: VisualDensity.compact,
                          ),
                        ),
                    ],
                  ),

                  if (structural.isEmpty &&
                      recurrences.isEmpty &&
                      unassignedHostels.isEmpty &&
                      staffing['recommendation'] == null)
                    const Padding(
                      padding: EdgeInsets.only(top: 60),
                      child: EmptyState(
                        icon: Icons.lightbulb_outline,
                        title: 'Nothing to flag yet',
                        subtitle:
                            'Patterns need a few weeks of complaints before they mean '
                            'anything. This fills in as the campus is used.',
                      ),
                    ),

                  // 1 -------------------------------------------------------
                  if (structural.isNotEmpty) ...[
                    const SizedBox(height: 22),
                    const _Heading(
                      'PROBABLY BROKEN, NOT DIRTY',
                      'Places where the same problem keeps coming back',
                    ),
                    for (final h in structural) _StructuralCard(hotspot: h),
                  ],

                  // 2 -------------------------------------------------------
                  if (staffing['recommendation'] != null) ...[
                    const SizedBox(height: 26),
                    const _Heading(
                      'STAFFING',
                      'Where the workload has drifted out of balance',
                    ),
                    _StaffingCard(recommendation: staffing['recommendation'] as Map<String, dynamic>),
                  ],

                  // 3 -------------------------------------------------------
                  if (unassignedHostels.isNotEmpty) ...[
                    const SizedBox(height: 26),
                    _Heading(
                      'HOSTELS WITH NO WARDEN',
                      '${unassignedHostels.length} hostel(s) cannot be allotted a '
                          'worker for a complaint filed inside them until one is assigned',
                    ),
                    for (final h in unassignedHostels) _UnassignedHostelRow(hostel: h),
                  ],

                  // 4 -------------------------------------------------------
                  if (recurrences.isNotEmpty) ...[
                    const SizedBox(height: 26),
                    _Heading(
                      'CLEANED, THEN DIRTY AGAIN',
                      '${recurrences.length} spot(s) came back within days of being signed off',
                    ),
                    for (final r in recurrences) _RecurrenceRow(row: r),
                  ],

                  // Context ------------------------------------------------
                  if (busy.isNotEmpty) ...[
                    const SizedBox(height: 26),
                    const _Heading(
                      'BUSY, BUT FINE',
                      'High volume spread across different problems — traffic, not a fault',
                    ),
                    for (final h in busy) _BusyRow(hotspot: h),
                  ],

                  if (staffing['recommendation'] == null && staffing['note'] != null) ...[
                    const SizedBox(height: 22),
                    InfoBanner(
                      icon: Icons.groups_outlined,
                      color: Palette.neutral,
                      text: staffing['note'] as String,
                    ),
                  ],
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _Heading extends StatelessWidget {
  final String label;
  final String caption;

  const _Heading(this.label, this.caption);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              fontSize: 10.5,
              letterSpacing: 1.8,
              fontWeight: FontWeight.w700,
              color: Palette.inkMuted,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            caption,
            style: const TextStyle(
              fontSize: 13.5,
              height: 1.35,
              color: Palette.inkSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

/// The headline insight: this place is generating the same complaint over and
/// over, which usually means a fault rather than a cleaning failure.
class _StructuralCard extends StatelessWidget {
  final Map<String, dynamic> hotspot;

  const _StructuralCard({required this.hotspot});

  @override
  Widget build(BuildContext context) {
    final zone = hotspot['zone'] as Map<String, dynamic>?;
    final note = hotspot['repeatedNote'] as String?;
    final pct = hotspot['concentrationPct'] as int? ?? 0;

    return Container(
      margin: const EdgeInsets.only(bottom: 11),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Palette.serious.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Palette.serious.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.handyman_outlined, color: Palette.serious, size: 21),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  hotspot['landmark'] as String? ?? 'Unknown place',
                  style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
                ),
              ),
              if (zone != null)
                Text(
                  zone['name'] as String? ?? '',
                  style: const TextStyle(fontSize: 12, color: Palette.inkMuted),
                ),
            ],
          ),

          if (note != null) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                const Icon(Icons.subdirectory_arrow_right, size: 15, color: Palette.serious),
                const SizedBox(width: 5),
                Expanded(
                  child: Text(
                    '"$note" — described ${hotspot['repeatedNoteCount']} times',
                    style: const TextStyle(
                      fontSize: 13,
                      fontStyle: FontStyle.italic,
                      color: Palette.serious,
                    ),
                  ),
                ),
              ],
            ),
          ],

          const SizedBox(height: 12),
          // The concentration is the whole argument, so show it as a bar.
          Row(
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: pct / 100,
                    minHeight: 8,
                    backgroundColor: Palette.grid,
                    valueColor: const AlwaysStoppedAnimation(Palette.serious),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Text(
                '$pct%',
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                  color: Palette.serious,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '${hotspot['topCategoryCount']} of ${hotspot['total']} complaints here are '
            '${(categoryLabels[hotspot['topCategory']] ?? hotspot['topCategory']).toString().toLowerCase()}.',
            style: const TextStyle(fontSize: 13, color: Palette.inkSecondary),
          ),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(11),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(9),
            ),
            child: Text(
              hotspot['verdict'] as String? ?? '',
              style: const TextStyle(
                fontSize: 13,
                height: 1.4,
                fontWeight: FontWeight.w600,
                color: Palette.inkPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A staffing decision, produced by the system rather than requested.
class _StaffingCard extends StatelessWidget {
  final Map<String, dynamic> recommendation;

  const _StaffingCard({required this.recommendation});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.seed.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.seed.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _ZonePill(text: 'Zone ${recommendation['fromZone']}'),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 10),
                child: Icon(Icons.arrow_forward, size: 20, color: AppTheme.seed),
              ),
              _ZonePill(text: 'Zone ${recommendation['toZone']}', filled: true),
              const Spacer(),
              const Icon(Icons.groups_outlined, color: AppTheme.seed, size: 21),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            'Move one worker from ${recommendation['fromName']} to ${recommendation['toName']}',
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          Text(
            recommendation['reason'] as String? ?? '',
            style: const TextStyle(
                fontSize: 13, height: 1.45, color: Palette.inkSecondary),
          ),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(11),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(9),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.trending_down, size: 17, color: Palette.good),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    recommendation['effect'] as String? ?? '',
                    style: const TextStyle(
                      fontSize: 12.5,
                      height: 1.4,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Change a worker’s zone from Workers, or leave it — this is a '
            'suggestion, not an action.',
            style: TextStyle(fontSize: 11.5, height: 1.35, color: Palette.inkMuted),
          ),
        ],
      ),
    );
  }
}

class _ZonePill extends StatelessWidget {
  final String text;
  final bool filled;

  const _ZonePill({required this.text, this.filled = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
      decoration: BoxDecoration(
        color: filled ? AppTheme.seed : Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.seed.withValues(alpha: 0.5)),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w800,
          color: filled ? Colors.white : AppTheme.seed,
        ),
      ),
    );
  }
}

class _RecurrenceRow extends StatelessWidget {
  final Map<String, dynamic> row;

  const _RecurrenceRow({required this.row});

  @override
  Widget build(BuildContext context) {
    final zone = row['zone'] as Map<String, dynamic>?;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: Palette.warning.withValues(alpha: 0.45)),
      ),
      child: Row(
        children: [
          const Icon(Icons.replay, size: 19, color: Palette.warning),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  row['landmarkName'] as String? ?? '',
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 2),
                Text(
                  '${categoryLabels[row['category']] ?? row['category']} · '
                  '${zone?['name'] ?? ''}',
                  style: const TextStyle(fontSize: 12, color: Palette.inkSecondary),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
            decoration: BoxDecoration(
              color: Palette.warning.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(7),
            ),
            child: Text(
              'back in ${row['recurrenceDays']}d',
              style: const TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w800,
                color: Palette.warning,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A hostel with nobody running it - the same shape of gap as a zone with no
/// officer, just surfaced before a complaint ever hits it.
class _UnassignedHostelRow extends StatelessWidget {
  final Map<String, dynamic> hostel;

  const _UnassignedHostelRow({required this.hostel});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: Palette.warning.withValues(alpha: 0.45)),
      ),
      child: Row(
        children: [
          const Icon(Icons.apartment, size: 19, color: Palette.warning),
          const SizedBox(width: 11),
          Expanded(
            child: Text(
              hostel['name'] as String? ?? '',
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
            decoration: BoxDecoration(
              color: Palette.warning.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(7),
            ),
            child: const Text(
              'No warden',
              style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w800, color: Palette.warning),
            ),
          ),
        ],
      ),
    );
  }
}

class _BusyRow extends StatelessWidget {
  final Map<String, dynamic> hotspot;

  const _BusyRow({required this.hotspot});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 9),
      child: Row(
        children: [
          const Icon(Icons.trending_up, size: 16, color: Palette.inkMuted),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              hotspot['landmark'] as String? ?? '',
              style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
            ),
          ),
          Text(
            '${hotspot['total']} complaints · ${hotspot['concentrationPct']}% one type',
            style: const TextStyle(fontSize: 11.5, color: Palette.inkMuted),
          ),
        ],
      ),
    );
  }
}
