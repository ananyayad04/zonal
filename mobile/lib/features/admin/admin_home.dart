import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api_client.dart';
import '../../core/palette.dart';
import '../../core/session.dart';
import '../../shared/ui.dart';
import '../../shared/zone_grid.dart';
import '../shared/app_drawer.dart';
import '../shared/complaint_search_screen.dart';
import 'analytics_screen.dart';
import 'audit_log_screen.dart';
import 'campus_map_screen.dart';
import 'create_supervisor_screen.dart';
import 'hostel_complaints_screen.dart';
import 'hostels_screen.dart';
import 'insights_screen.dart';
import 'landmarks_screen.dart';
import 'multi_zone_workers_screen.dart';
import 'needs_attention_screen.dart';
import 'roster_screen.dart';
import 'unallotted_complaints_screen.dart';
import 'verify_people_screen.dart';
import 'zones_screen.dart';

class AdminHome extends StatefulWidget {
  const AdminHome({super.key});

  @override
  State<AdminHome> createState() => _AdminHomeState();
}

class _AdminHomeState extends State<AdminHome> {
  late Future<Map<String, dynamic>> _future;
  ZoneGridMetric _metric = ZoneGridMetric.openComplaints;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<Map<String, dynamic>> _load() async {
    final api = context.read<ApiClient>();
    final results = await Future.wait([api.get('/admin/dashboard'), api.get('/admin/attention')]);
    return {
      ...results[0],
      'attentionCount': (results[1]['items'] as List).length,
    };
  }

  Future<void> _refresh() async {
    setState(() => _future = _load());
    await _future;
    if (mounted) context.read<Session>().refreshUnreadCount();
  }

  Future<void> _go(Widget screen) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Campus admin'),
        actions: [
          IconButton(
            tooltip: 'Find a complaint',
            icon: const Icon(Icons.search),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const ComplaintSearchScreen()),
            ),
          ),
          const NotificationBell(),
        ],
      ),
      drawer: const AppDrawer(),
      body: FutureBuilder<Map<String, dynamic>>(
        future: _future,
        builder: (context, snapshot) => AsyncBody<Map<String, dynamic>>(
          snapshot: snapshot,
          onRetry: _refresh,
          builder: (data) {
            final queues = data['queues'] as Map<String, dynamic>;
            final zones = (data['zones'] as List).cast<Map<String, dynamic>>();

            final cells = zones
                .map((z) => ZoneCellData(
                      code: z['code'] as int,
                      name: z['name'] as String,
                      label: z['label'] as String,
                      colorHex: z['colorHex'] as String,
                      openCount: z['openComplaints'] as int? ?? 0,
                      workersFree: z['workersFree'] as int? ?? 0,
                      workersTotal: z['workersTotal'] as int? ?? 0,
                    ))
                .toList();

            final pendingWorkers = queues['pendingWorkers'] as int? ?? 0;
            final pendingOfficers = queues['pendingOfficers'] as int? ?? 0;
            final attentionCount = data['attentionCount'] as int? ?? 0;

            return RefreshIndicator(
              onRefresh: _refresh,
              child: ListView(
                padding: const EdgeInsets.only(bottom: 30),
                children: [
                  // Verification, allotment (zone or hostel) and escalations
                  // are one merged, urgency-sorted queue - see
                  // NeedsAttentionScreen. Personnel (workers/officers waiting
                  // to be verified) stays separate: it is a different kind of
                  // wait, with no complaint or deadline to sort by.
                  if (attentionCount > 0 || pendingWorkers > 0 || pendingOfficers > 0)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 14, 12, 0),
                      child: Column(
                        children: [
                          if (attentionCount > 0)
                            _QueueTile(
                              icon: Icons.priority_high,
                              color: Palette.warning,
                              count: attentionCount,
                              title: 'item${attentionCount == 1 ? '' : 's'} need your attention',
                              subtitle: 'Verification, allotment and escalations - most urgent first',
                              onTap: () => _go(const NeedsAttentionScreen()),
                            ),
                          if (pendingWorkers > 0)
                            _QueueTile(
                              icon: Icons.how_to_reg,
                              color: const Color(0xFF0072B2),
                              count: pendingWorkers,
                              title: 'worker${pendingWorkers == 1 ? '' : 's'} to verify',
                              subtitle: 'They cannot be given work until verified',
                              onTap: () => _go(const VerifyPeopleScreen()),
                            ),
                          if (pendingOfficers > 0)
                            _QueueTile(
                              icon: Icons.shield_outlined,
                              color: const Color(0xFF7A52CC),
                              count: pendingOfficers,
                              title: 'officer${pendingOfficers == 1 ? '' : 's'} to approve',
                              subtitle: 'A zone has no one routing its complaints '
                                  'until you appoint someone',
                              onTap: () => _go(const VerifyPeopleScreen(officers: true)),
                            ),
                        ],
                      ),
                    ),

                  // The campus itself. Position is the information here.
                  Padding(
                    padding: const EdgeInsets.fromLTRB(18, 24, 18, 0),
                    child: Row(
                      children: [
                        const Expanded(
                          child: Text(
                            'THE CAMPUS',
                            style: TextStyle(
                              fontSize: 10.5,
                              letterSpacing: 1.8,
                              fontWeight: FontWeight.w700,
                              color: Palette.inkMuted,
                            ),
                          ),
                        ),
                        SegmentedButton<ZoneGridMetric>(
                          style: const ButtonStyle(
                            visualDensity: VisualDensity.compact,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          segments: const [
                            ButtonSegment(
                              value: ZoneGridMetric.openComplaints,
                              label: Text('Open', style: TextStyle(fontSize: 12)),
                            ),
                            ButtonSegment(
                              value: ZoneGridMetric.freeWorkers,
                              label: Text('Free', style: TextStyle(fontSize: 12)),
                            ),
                          ],
                          selected: {_metric},
                          onSelectionChanged: (s) => setState(() => _metric = s.first),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 18),
                    child: ZoneGrid(
                      zones: cells,
                      metric: _metric,
                      onTap: (z) => showSnack(
                        context,
                        '${z.name} · ${z.label} — ${z.openCount} open, '
                        '${z.workersFree}/${z.workersTotal} workers free',
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 18),
                    child: ZoneGridLegend(zones: cells),
                  ),

                  _NavSection(
                    label: 'QUEUES',
                    tiles: [
                      _NavTile(
                        icon: Icons.assignment_late_outlined,
                        title: 'Unallotted complaints',
                        subtitle: 'Allot straight to a worker, without the officer',
                        onTap: () => _go(const UnallottedComplaintsScreen()),
                      ),
                      _NavTile(
                        icon: Icons.home_repair_service_outlined,
                        title: 'Hostel complaints',
                        subtitle: 'Every hostel at once - allot a free worker to any of them',
                        onTap: () => _go(const HostelComplaintsScreen()),
                      ),
                      _NavTile(
                        icon: Icons.swap_horiz,
                        title: 'Multi-zone workers',
                        subtitle: 'Who is currently lent to another zone',
                        onTap: () => _go(const MultiZoneWorkersScreen()),
                      ),
                    ],
                  ),

                  _NavSection(
                    label: 'PEOPLE',
                    tiles: [
                      _NavTile(
                        icon: Icons.groups_outlined,
                        title: 'Roster',
                        subtitle: 'Who runs every zone, hostel and supervises campus-wide',
                        onTap: () => _go(const RosterScreen()),
                      ),
                      _NavTile(
                        icon: Icons.badge_outlined,
                        title: 'All workers',
                        subtitle: 'Verified, pending and rejected',
                        onTap: () => _go(const VerifyPeopleScreen()),
                      ),
                      _NavTile(
                        icon: Icons.shield_outlined,
                        title: 'Zone officers',
                        subtitle: 'Who runs which zone - create or reassign',
                        onTap: () => _go(const VerifyPeopleScreen(officers: true)),
                      ),
                      _NavTile(
                        icon: Icons.supervisor_account_outlined,
                        title: 'Worker supervisors',
                        subtitle: 'Campus-wide reach over complaints and allotment',
                        onTap: () => _go(const CreateSupervisorScreen()),
                      ),
                      _NavTile(
                        icon: Icons.apartment_outlined,
                        title: 'Hostels & wardens',
                        subtitle: 'Who owns each hostel\'s complaints',
                        onTap: () => _go(const HostelsScreen()),
                      ),
                    ],
                  ),

                  _NavSection(
                    label: 'CAMPUS SETUP',
                    tiles: [
                      _NavTile(
                        icon: Icons.edit_location_alt_outlined,
                        title: 'Set up zones',
                        subtitle: 'Draw boundaries, assign officers, check coverage',
                        onTap: () => _go(const ZonesScreen()),
                      ),
                      _NavTile(
                        icon: Icons.add_location_alt_outlined,
                        title: 'Landmarks',
                        subtitle: 'Departments, hostels, facilities - required on every complaint',
                        onTap: () => _go(const LandmarksScreen()),
                      ),
                      _NavTile(
                        icon: Icons.map_outlined,
                        title: 'Campus map',
                        subtitle: 'Zone boundaries and where complaints come from',
                        onTap: () => _go(const CampusMapScreen()),
                      ),
                    ],
                  ),

                  _NavSection(
                    label: 'REPORTS',
                    tiles: [
                      _NavTile(
                        icon: Icons.lightbulb_outline,
                        title: 'Insights',
                        subtitle: 'What the system noticed without being asked',
                        onTap: () => _go(const InsightsScreen()),
                      ),
                      _NavTile(
                        icon: Icons.insights_outlined,
                        title: 'Analytics',
                        subtitle: 'Resolution times, hotspots, cross-zone borrowing',
                        onTap: () => _go(const AnalyticsScreen()),
                      ),
                      _NavTile(
                        icon: Icons.history,
                        title: 'Activity log',
                        subtitle: 'Who you verified, created or appointed, and when',
                        onTap: () => _go(const AuditLogScreen()),
                      ),
                    ],
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _QueueTile extends StatelessWidget {
  final IconData icon;
  final Color color;
  final int count;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _QueueTile({
    required this.icon,
    required this.color,
    required this.count,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 9),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(13),
          child: Container(
            padding: const EdgeInsets.all(15),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.09),
              borderRadius: BorderRadius.circular(13),
              border: Border.all(color: color.withValues(alpha: 0.4)),
            ),
            child: Row(
              children: [
                Icon(icon, color: color, size: 23),
                const SizedBox(width: 13),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.baseline,
                        textBaseline: TextBaseline.alphabetic,
                        children: [
                          Text(
                            '$count',
                            style: TextStyle(
                              fontSize: 21,
                              fontWeight: FontWeight.w800,
                              color: color,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              title,
                              style: const TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: const TextStyle(
                            fontSize: 12.5, color: Palette.inkSecondary),
                      ),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right, color: color),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A labelled group of nav tiles. Eleven flat tiles in one list meant scanning
/// past everything to find one thing - four short sections, each answering a
/// different question ("what needs a worker", "who runs what", "how is the
/// campus laid out", "how is it doing"), read faster than one long list.
class _NavSection extends StatelessWidget {
  final String label;
  final List<Widget> tiles;

  const _NavSection({required this.label, required this.tiles});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 22, 12, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 6, bottom: 8),
            child: Text(
              label,
              style: const TextStyle(
                fontSize: 10.5,
                letterSpacing: 1.8,
                fontWeight: FontWeight.w700,
                color: Palette.inkMuted,
              ),
            ),
          ),
          ...tiles,
        ],
      ),
    );
  }
}

class _NavTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _NavTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 15, vertical: 5),
        leading: Icon(icon, color: Palette.inkSecondary),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
        subtitle: Text(
          subtitle,
          style: const TextStyle(fontSize: 12.5, color: Palette.inkSecondary),
        ),
        trailing: const Icon(Icons.chevron_right, color: Palette.inkMuted),
        onTap: onTap,
      ),
    );
  }
}
