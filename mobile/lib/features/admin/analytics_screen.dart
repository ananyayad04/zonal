import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api_client.dart';
import '../../core/palette.dart';
import '../../core/theme.dart';
import '../../shared/ui.dart';

const _sourceLabels = <String, String>{
  'RESIDENT': 'Residents',
  'STUDENT': 'Students',
  'WORKER_SUPERVISOR': 'Created by supervisors',
};

const _escalationReasonLabels = <String, String>{
  'NO_ZONE_OFFICER': 'Zone has no officer',
  'OFFICER_SLA_BREACH': 'Officer missed allotment deadline',
  'WORKER_SLA_BREACH': 'Worker missed completion deadline',
  'HELP_REQUEST_EXPIRED': 'No zone answered a help request',
  'NO_FREE_WORKER_CAMPUS_WIDE': 'No worker free anywhere',
  'REJECTED_TWICE': 'Resident rejected the work twice',
  'NO_WARDEN_ASSIGNED': 'Hostel has no warden',
  'HOSTEL_STAFF_SLA_BREACH': 'Hostel complaint missed allotment deadline',
  'HOSTEL_REJECTED_TWICE': 'Warden rejected the work twice',
};

/// Analytics.
///
/// Colour is assigned by the job it does, which is why there are no eight-hue
/// charts here. "Complaints per zone" is a magnitude question - the bar length
/// carries the value and the zone name on the axis carries the identity, so
/// painting each bar a different colour would encode nothing. Those bars get
/// one blue ramp. Only state uses the reserved status colours, and each of
/// those ships with an icon and a label rather than colour alone.
class AnalyticsScreen extends StatefulWidget {
  const AnalyticsScreen({super.key});

  @override
  State<AnalyticsScreen> createState() => _AnalyticsScreenState();
}

class _AnalyticsScreenState extends State<AnalyticsScreen> {
  late Future<Map<String, dynamic>> _future;
  int _days = 30;
  bool _showTable = false;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<Map<String, dynamic>> _load() =>
      context.read<ApiClient>().get('/analytics/overview', query: {'days': _days});

  Future<void> _refresh() async {
    setState(() => _future = _load());
    await _future;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Analytics'),
        actions: [
          IconButton(
            tooltip: _showTable ? 'Show charts' : 'Show as table',
            icon: Icon(_showTable ? Icons.bar_chart : Icons.table_rows_outlined),
            onPressed: () => setState(() => _showTable = !_showTable),
          ),
        ],
      ),
      body: FutureBuilder<Map<String, dynamic>>(
        future: _future,
        builder: (context, snapshot) => AsyncBody<Map<String, dynamic>>(
          snapshot: snapshot,
          onRetry: _refresh,
          builder: (data) {
            final totals = data['totals'] as Map<String, dynamic>;
            final rates = data['rates'] as Map<String, dynamic>;
            final avgs = data['averageMinutes'] as Map<String, dynamic>;
            final byZone = (data['byZone'] as List).cast<Map<String, dynamic>>();
            final byHostel = (data['byHostel'] as List? ?? const [])
                .cast<Map<String, dynamic>>();
            final bySource = (data['bySource'] as List? ?? const [])
                .cast<Map<String, dynamic>>();
            final escalationReasons =
                (data['escalationReasons'] as List? ?? const []).cast<Map<String, dynamic>>();
            final byCategory = (data['byCategory'] as List).cast<Map<String, dynamic>>();
            final byStatus = data['byStatus'] as Map<String, dynamic>;

            return RefreshIndicator(
              onRefresh: _refresh,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 30),
                children: [
                  // Filters as a single pill-shaped segmented row, so the
                  // page opens with one clear control rather than loose text
                  // and chips side by side.
                  Container(
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Palette.grid),
                    ),
                    child: Row(
                      children: [
                        for (final d in [7, 30, 90])
                          Expanded(
                            child: _RangeSegment(
                              label: '${d}d',
                              selected: _days == d,
                              onTap: () {
                                setState(() => _days = d);
                                _refresh();
                              },
                            ),
                          ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 18),

                  // The headline number gets to be a number, not a chart.
                  _HeroStat(
                    value: '${totals['total'] ?? 0}',
                    label: 'complaints filed',
                    detail: '${totals['closed'] ?? 0} closed · ${totals['open'] ?? 0} still open'
                        '${(totals['hostelComplaints'] as int? ?? 0) > 0 ? ' · ${totals['hostelComplaints']} from hostels' : ''}',
                  ),

                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: _StatTile(
                          icon: Icons.check_circle_outline,
                          value: rates['resolutionRatePct'] == null
                              ? '—'
                              : '${rates['resolutionRatePct']}%',
                          label: 'Resolution rate',
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _StatTile(
                          icon: Icons.schedule,
                          value: formatDuration(avgs['endToEndResolution'] as int?),
                          label: 'Avg resolution',
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _StatTile(
                          icon: Icons.handshake_outlined,
                          value: rates['crossZonePct'] == null
                              ? '—'
                              : '${rates['crossZonePct']}%',
                          label: 'Cross-zone',
                        ),
                      ),
                    ],
                  ),

                  if (byZone.any((z) => (z['total'] as int? ?? 0) > 0)) ...[
                    const SizedBox(height: 12),
                    Builder(builder: (context) {
                      final busiest = byZone.reduce((a, b) =>
                          (a['total'] as int? ?? 0) >= (b['total'] as int? ?? 0) ? a : b);
                      return InfoBanner(
                        icon: Icons.priority_high,
                        color: Palette.warning,
                        text: '${busiest['name']} is the most complaint-prone zone: '
                            '${busiest['total']} complaint(s) in the last $_days days.',
                      );
                    }),
                  ],

                  // Auto-closed is reported separately from resident-approved,
                  // so a timeout can never be passed off as approval.
                  if ((rates['autoClosedPct'] as int? ?? 0) > 0) ...[
                    const SizedBox(height: 12),
                    InfoBanner(
                      icon: Icons.timer_off_outlined,
                      color: Palette.neutral,
                      text: '${rates['autoClosedPct']}% of closed complaints were closed '
                          'automatically because the resident never replied. Only '
                          '${rates['residentApprovedPct'] ?? 0}% were actually approved by them.',
                    ),
                  ],

                  const SizedBox(height: 22),
                  _ChartSection(
                    title: 'WHERE THE PROBLEMS ARE',
                    caption: 'Complaints per zone',
                    child: _showTable
                        ? _ZoneTable(rows: byZone)
                        : _BarChart(
                            bars: byZone
                                .map((z) => _Bar(
                                      label: '${z['name']}',
                                      sublabel: z['label'] as String?,
                                      value: (z['total'] as int?) ?? 0,
                                    ))
                                .toList(),
                          ),
                  ),

                  const SizedBox(height: 14),
                  _ChartSection(
                    title: 'STAFFING',
                    caption: 'Active workers per zone',
                    child: _BarChart(
                      bars: byZone
                          .map((z) => _Bar(
                                label: '${z['name']}',
                                sublabel: '${z['freeWorkerCount'] ?? 0} free',
                                value: (z['workerCount'] as int?) ?? 0,
                              ))
                          .toList(),
                    ),
                  ),

                  const SizedBox(height: 14),
                  _ChartSection(
                    title: 'WHAT KIND OF PROBLEM',
                    caption: 'Complaints per category',
                    child: _BarChart(
                      bars: byCategory
                          .map((c) => _Bar(
                                label: categoryLabels[c['category']] ??
                                    c['category'] as String,
                                value: (c['count'] as int?) ?? 0,
                              ))
                          .toList(),
                    ),
                  ),

                  const SizedBox(height: 14),
                  _ChartSection(
                    title: 'HOW LONG EACH STAGE TAKES',
                    caption: 'Average, from one handover to the next',
                    child: _StageBars(avgs: avgs),
                  ),

                  const SizedBox(height: 14),
                  _ChartSection(
                    title: 'WHERE THINGS STAND',
                    caption: 'Current status of every complaint',
                    child: _StatusList(byStatus: byStatus),
                  ),

                  // The exact-numbers table only when it isn't already on
                  // screen from the toggle above - otherwise the same table
                  // showed twice.
                  if (!_showTable) ...[
                    const SizedBox(height: 14),
                    _ChartSection(
                      title: 'ZONE BY ZONE',
                      caption: 'Every number, exactly',
                      footer: 'Borrowed = complaints in this zone that needed a '
                          'worker from somewhere else. A high number means the '
                          'zone is understaffed.',
                      child: _ZoneTable(rows: byZone),
                    ),
                  ],

                  // Citizen-reported vs staff-initiated - only worth a section
                  // once there is more than one source to compare.
                  if (bySource.length > 1) ...[
                    const SizedBox(height: 14),
                    _ChartSection(
                      title: 'WHO FILED IT',
                      caption: 'Citizen complaints vs. work supervisors created directly',
                      child: _BarChart(
                        bars: bySource
                            .map((s) => _Bar(
                                  label: _sourceLabels[s['reporterRole']] ??
                                      s['reporterRole'] as String,
                                  value: (s['count'] as int?) ?? 0,
                                ))
                            .toList(),
                      ),
                    ),
                  ],

                  // Hostels only ever generate hostel complaints, so an empty
                  // campus with none filed yet would just be a table of zeros.
                  if (byHostel.any((h) => (h['total'] as int? ?? 0) > 0)) ...[
                    const SizedBox(height: 14),
                    _ChartSection(
                      title: 'HOSTELS',
                      caption: 'Complaints filed from inside each hostel',
                      footer: 'A hostel with no warden shown cannot be allotted a '
                          'worker until the admin assigns one.',
                      child: _HostelTable(rows: byHostel),
                    ),
                  ],

                  if (escalationReasons.isNotEmpty) ...[
                    const SizedBox(height: 14),
                    _ChartSection(
                      title: 'WHY THINGS ESCALATED',
                      caption: 'Every reason a complaint reached the admin',
                      child: _BarChart(
                        bars: escalationReasons
                            .map((e) => _Bar(
                                  label: _escalationReasonLabels[e['reason']] ??
                                      e['reason'] as String,
                                  value: (e['count'] as int?) ?? 0,
                                ))
                            .toList(),
                      ),
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

class _HeroStat extends StatelessWidget {
  final String value;
  final String label;
  final String detail;

  const _HeroStat({required this.value, required this.label, required this.detail});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Palette.grid),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                value,
                style: const TextStyle(
                  fontSize: 46,
                  height: 1,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -2,
                  color: AppTheme.seed,
                ),
              ),
              const SizedBox(width: 10),
              Text(
                label,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: Palette.inkSecondary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            detail,
            style: const TextStyle(fontSize: 13, color: Palette.inkMuted),
          ),
        ],
      ),
    );
  }
}

class _StatTile extends StatelessWidget {
  final IconData icon;
  final String value;
  final String label;

  const _StatTile({required this.icon, required this.value, required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Palette.grid),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: AppTheme.seed),
          const SizedBox(height: 8),
          Text(
            value,
            style: const TextStyle(
              fontSize: 21,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.5,
              color: Palette.inkPrimary,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: const TextStyle(fontSize: 11, color: Palette.inkMuted),
          ),
        ],
      ),
    );
  }
}

/// One segment of the day-range control - a pill that fills solid when
/// selected, so the whole row reads as one control rather than loose chips.
class _RangeSegment extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _RangeSegment({required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(9),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(vertical: 9),
          decoration: BoxDecoration(
            color: selected ? AppTheme.seed : Colors.transparent,
            borderRadius: BorderRadius.circular(9),
          ),
          alignment: Alignment.center,
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: selected ? Colors.white : Palette.inkSecondary,
            ),
          ),
        ),
      ),
    );
  }
}

/// Every chart lives in the same boxed card the hero stat and stat tiles use,
/// so the page reads as one consistent stack rather than half boxed content
/// and half bare list items.
class _ChartSection extends StatelessWidget {
  final String title;
  final String caption;
  final Widget child;
  final String? footer;

  const _ChartSection({
    required this.title,
    required this.caption,
    required this.child,
    this.footer,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Palette.grid),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
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
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: Palette.inkPrimary,
            ),
          ),
          const SizedBox(height: 16),
          child,
          if (footer != null) ...[
            const SizedBox(height: 10),
            Text(
              footer!,
              style: const TextStyle(fontSize: 11.5, height: 1.35, color: Palette.inkMuted),
            ),
          ],
        ],
      ),
    );
  }
}

class _Bar {
  final String label;
  final String? sublabel;
  final int value;

  const _Bar({required this.label, this.sublabel, required this.value});
}

/// Horizontal bars, one hue. Length is the encoding; the label on the left is
/// the identity. Values are printed at the end of each bar because there are
/// few enough bars for that to stay readable.
class _BarChart extends StatelessWidget {
  final List<_Bar> bars;

  const _BarChart({required this.bars});

  @override
  Widget build(BuildContext context) {
    if (bars.isEmpty) {
      return const Text(
        'No data in this period.',
        style: TextStyle(color: Palette.inkMuted),
      );
    }

    final max = bars.map((b) => b.value).reduce((a, b) => a > b ? a : b);
    final safeMax = max == 0 ? 1 : max;

    return Column(
      children: [
        for (final bar in bars)
          Padding(
            padding: const EdgeInsets.only(bottom: 11),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                SizedBox(
                  width: 96,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        bar.label,
                        style: const TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          color: Palette.inkPrimary,
                        ),
                      ),
                      if (bar.sublabel != null)
                        Text(
                          bar.sublabel!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 10, color: Palette.inkMuted),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final fraction = bar.value / safeMax;
                      return Stack(
                        children: [
                          // Recessive track.
                          Container(
                            height: 14,
                            decoration: BoxDecoration(
                              color: Palette.grid.withValues(alpha: 0.55),
                              borderRadius: BorderRadius.circular(4),
                            ),
                          ),
                          Container(
                            height: 14,
                            width: (constraints.maxWidth * fraction)
                                .clamp(bar.value > 0 ? 4.0 : 0.0, constraints.maxWidth),
                            decoration: BoxDecoration(
                              color: Palette.sequentialStep(fraction),
                              borderRadius: BorderRadius.circular(4),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
                const SizedBox(width: 10),
                SizedBox(
                  width: 30,
                  child: Text(
                    '${bar.value}',
                    textAlign: TextAlign.right,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: Palette.inkPrimary,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// The four handovers, as durations. Kept on one scale - never two axes.
class _StageBars extends StatelessWidget {
  final Map<String, dynamic> avgs;

  const _StageBars({required this.avgs});

  @override
  Widget build(BuildContext context) {
    final stages = <(String, int?)>[
      ('Filed → verified by admin', avgs['submitToVerify'] as int?),
      ('Verified → worker allotted', avgs['verifyToAllot'] as int?),
      ('Allotted → work done', avgs['allotToDone'] as int?),
      ('Filed → closed', avgs['endToEndResolution'] as int?),
    ];

    final values = stages.map((s) => s.$2 ?? 0).toList();
    final max = values.isEmpty ? 1 : values.reduce((a, b) => a > b ? a : b);
    final safeMax = max == 0 ? 1 : max;

    return Column(
      children: [
        for (final (label, minutes) in stages)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        label,
                        style: const TextStyle(
                            fontSize: 12.5, color: Palette.inkSecondary),
                      ),
                    ),
                    Text(
                      formatDuration(minutes),
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: Palette.inkPrimary,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 5),
                LayoutBuilder(
                  builder: (context, constraints) {
                    final fraction = (minutes ?? 0) / safeMax;
                    return Stack(
                      children: [
                        Container(
                          height: 10,
                          decoration: BoxDecoration(
                            color: Palette.grid.withValues(alpha: 0.55),
                            borderRadius: BorderRadius.circular(3),
                          ),
                        ),
                        Container(
                          height: 10,
                          width: (constraints.maxWidth * fraction)
                              .clamp(0.0, constraints.maxWidth),
                          decoration: BoxDecoration(
                            color: Palette.sequentialStep(fraction),
                            borderRadius: BorderRadius.circular(3),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Status uses the reserved status palette, and every row carries an icon and
/// a written label - never colour on its own.
class _StatusList extends StatelessWidget {
  final Map<String, dynamic> byStatus;

  const _StatusList({required this.byStatus});

  @override
  Widget build(BuildContext context) {
    final entries = byStatus.entries.toList()
      ..sort((a, b) => (b.value as int).compareTo(a.value as int));

    if (entries.isEmpty) {
      return const Text(
        'No data in this period.',
        style: TextStyle(color: Palette.inkMuted),
      );
    }

    final total = entries.fold<int>(0, (sum, e) => sum + (e.value as int));

    return Column(
      children: [
        for (final e in entries)
          Padding(
            padding: const EdgeInsets.only(bottom: 9),
            child: Row(
              children: [
                Icon(
                  StatusStyle.of(e.key).icon,
                  size: 17,
                  color: Palette.forComplaintStatus(e.key),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    StatusStyle.of(e.key).label,
                    style: const TextStyle(fontSize: 13.5),
                  ),
                ),
                Text(
                  '${e.value}',
                  style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 40,
                  child: Text(
                    total == 0
                        ? ''
                        : '${(((e.value as int) / total) * 100).round()}%',
                    textAlign: TextAlign.right,
                    style: const TextStyle(fontSize: 12, color: Palette.inkMuted),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// The table view. Always available, and the only place the per-zone numbers
/// can be read exactly.
class _ZoneTable extends StatelessWidget {
  final List<Map<String, dynamic>> rows;

  const _ZoneTable({required this.rows});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(
            headingRowHeight: 38,
            dataRowMinHeight: 38,
            dataRowMaxHeight: 46,
            columnSpacing: 20,
            headingTextStyle: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: Palette.inkMuted,
            ),
            dataTextStyle: const TextStyle(fontSize: 12.5, color: Palette.inkPrimary),
            columns: const [
              DataColumn(label: Text('ZONE')),
              DataColumn(label: Text('TOTAL'), numeric: true),
              DataColumn(label: Text('OPEN'), numeric: true),
              DataColumn(label: Text('CLOSED'), numeric: true),
              DataColumn(label: Text('BORROWED'), numeric: true),
              DataColumn(label: Text('WORKERS'), numeric: true),
              DataColumn(label: Text('AVG TIME')),
            ],
            rows: [
              for (final z in rows)
                DataRow(cells: [
                  DataCell(Row(
                    children: [
                      Container(
                        width: 9,
                        height: 9,
                        decoration: BoxDecoration(
                          color: colorFromHex(z['colorHex'] as String? ?? '#0072B2'),
                          borderRadius: BorderRadius.circular(2.5),
                        ),
                      ),
                      const SizedBox(width: 7),
                      Text(z['name'] as String),
                    ],
                  )),
                  DataCell(Text('${z['total'] ?? 0}')),
                  DataCell(Text('${z['open'] ?? 0}')),
                  DataCell(Text('${z['closed'] ?? 0}')),
                  DataCell(Text('${z['crossZoneBorrowed'] ?? 0}')),
                  DataCell(Text('${z['workerCount'] ?? 0}')),
                  DataCell(Text(formatDuration(z['avgResolutionMinutes'] as int?))),
                ]),
            ],
          ),
        ),
      ],
    );
  }
}

/// The per-hostel table - mirrors _ZoneTable's shape, but a hostel has a
/// warden instead of an officer/worker roster, and no cross-zone borrowing.
class _HostelTable extends StatelessWidget {
  final List<Map<String, dynamic>> rows;

  const _HostelTable({required this.rows});

  @override
  Widget build(BuildContext context) {
    // A campus can have a couple of dozen hostels - only show the ones that
    // have actually had a complaint, so the table isn't mostly zero rows.
    final active = rows.where((h) => (h['total'] as int? ?? 0) > 0).toList();

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        headingRowHeight: 38,
        dataRowMinHeight: 38,
        dataRowMaxHeight: 46,
        columnSpacing: 20,
        headingTextStyle: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: Palette.inkMuted,
        ),
        dataTextStyle: const TextStyle(fontSize: 12.5, color: Palette.inkPrimary),
        columns: const [
          DataColumn(label: Text('HOSTEL')),
          DataColumn(label: Text('WARDEN')),
          DataColumn(label: Text('TOTAL'), numeric: true),
          DataColumn(label: Text('OPEN'), numeric: true),
          DataColumn(label: Text('CLOSED'), numeric: true),
          DataColumn(label: Text('AVG TIME')),
        ],
        rows: [
          for (final h in active)
            DataRow(cells: [
              DataCell(Text(h['name'] as String? ?? '')),
              DataCell(
                (h['warden'] as Map<String, dynamic>?) != null
                    ? Text((h['warden'] as Map<String, dynamic>)['name'] as String)
                    : const Text('None', style: TextStyle(color: Palette.warning)),
              ),
              DataCell(Text('${h['total'] ?? 0}')),
              DataCell(Text('${h['open'] ?? 0}')),
              DataCell(Text('${h['closed'] ?? 0}')),
              DataCell(Text(formatDuration(h['avgResolutionMinutes'] as int?))),
            ]),
        ],
      ),
    );
  }
}
