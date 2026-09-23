import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api_client.dart';
import '../../core/palette.dart';
import '../../core/session.dart';
import '../../shared/ui.dart';
import '../../shared/zone_grid.dart';
import '../admin/analytics_screen.dart';
import '../admin/escalations_screen.dart';
import '../admin/hostel_complaints_screen.dart';
import '../admin/insights_screen.dart';
import '../admin/needs_attention_screen.dart';
import '../admin/unallotted_complaints_screen.dart';
import '../admin/verify_complaints_screen.dart';
import '../shared/app_drawer.dart';
import '../shared/complaint_search_screen.dart';
import 'allotted_work_screen.dart';
import 'create_work_order_screen.dart';
import 'my_work_approvals_screen.dart';
import 'workers_roster_screen.dart';

/// Worker Supervisor: the same campus-wide reach over complaints and
/// allotment that Admin has (verify, monitor, force-allot, free workers) -
/// reuses Admin's own screens directly, since the backend already grants
/// this role the same access to those endpoints. What it does NOT get is
/// personnel verification, zone drawing, or hostel/warden management -
/// those stay on the Admin's own home screen.
class SupervisorHome extends StatefulWidget {
  const SupervisorHome({super.key});

  @override
  State<SupervisorHome> createState() => _SupervisorHomeState();
}

class _SupervisorHomeState extends State<SupervisorHome> {
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
        title: const Text('Worker supervisor'),
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
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _go(const CreateWorkOrderScreen()),
        icon: const Icon(Icons.add),
        label: const Text('Create work'),
      ),
      body: FutureBuilder<Map<String, dynamic>>(
        future: _future,
        builder: (context, snapshot) => AsyncBody<Map<String, dynamic>>(
          snapshot: snapshot,
          onRetry: _refresh,
          builder: (data) {
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

            final attentionCount = data['attentionCount'] as int? ?? 0;

            return RefreshIndicator(
              onRefresh: _refresh,
              child: ListView(
                padding: const EdgeInsets.only(bottom: 30),
                children: [
                  // Verification, allotment (zone or hostel) and escalations
                  // merged into one urgency-sorted queue - see
                  // NeedsAttentionScreen.
                  if (attentionCount > 0)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 14, 12, 0),
                      child: Column(
                        children: [
                          _QueueTile(
                            icon: Icons.priority_high,
                            color: Palette.warning,
                            count: attentionCount,
                            title: 'item${attentionCount == 1 ? '' : 's'} need your attention',
                            subtitle: 'Verification, allotment and escalations - most urgent first',
                            onTap: () => _go(const NeedsAttentionScreen()),
                          ),
                        ],
                      ),
                    ),

                  // Live state across every zone - who is free, and where the
                  // open work sits right now.
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

                  const SizedBox(height: 22),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: _NavTile(
                      icon: Icons.add_task,
                      title: 'Create work',
                      subtitle: 'Zone, type of work, describe it, then allot a worker',
                      onTap: () => _go(const CreateWorkOrderScreen()),
                    ),
                  ),

                  _NavSection(
                    label: 'QUEUES',
                    tiles: [
                      _NavTile(
                        icon: Icons.gavel_outlined,
                        title: 'Verify complaints',
                        subtitle: 'The first-step gate, same as the admin',
                        onTap: () => _go(const VerifyComplaintsScreen()),
                      ),
                      _NavTile(
                        icon: Icons.assignment_late_outlined,
                        title: 'Unallotted complaints',
                        subtitle: 'Allot straight to any free worker on campus',
                        onTap: () => _go(const UnallottedComplaintsScreen()),
                      ),
                      _NavTile(
                        icon: Icons.assignment_turned_in_outlined,
                        title: 'Allotted work',
                        subtitle: 'Every task out with a worker - adjust deadlines, '
                            'start or finish one on their behalf',
                        onTap: () => _go(const AllottedWorkScreen()),
                      ),
                      _NavTile(
                        icon: Icons.apartment_outlined,
                        title: 'Hostel complaints',
                        subtitle: 'Every hostel at once - allot a free worker to any of them',
                        onTap: () => _go(const HostelComplaintsScreen()),
                      ),
                      _NavTile(
                        icon: Icons.warning_amber_outlined,
                        title: 'Escalations',
                        subtitle: 'Missed deadlines and unanswered requests',
                        onTap: () => _go(const EscalationsScreen()),
                      ),
                      _NavTile(
                        icon: Icons.fact_check_outlined,
                        title: 'My work orders',
                        subtitle: 'Extra work you created - approve it once a worker finishes',
                        onTap: () => _go(const MyWorkApprovalsScreen()),
                      ),
                    ],
                  ),

                  _NavSection(
                    label: 'MY WORKERS',
                    tiles: [
                      _NavTile(
                        icon: Icons.engineering_outlined,
                        title: 'Workers roster',
                        subtitle: 'Create a worker directly, zone-wise, and set duty status',
                        onTap: () => _go(const WorkersRosterScreen()),
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
                        subtitle: 'Resolution times, hostels, escalation reasons',
                        onTap: () => _go(const AnalyticsScreen()),
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
                            style: TextStyle(fontSize: 21, fontWeight: FontWeight.w800, color: color),
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(subtitle, style: const TextStyle(fontSize: 12.5, color: Palette.inkSecondary)),
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

/// A labelled group of nav tiles, so the growing list of screens reads as a
/// few short sections rather than one long scan.
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

  const _NavTile({required this.icon, required this.title, required this.subtitle, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 15, vertical: 5),
        leading: Icon(icon, color: Palette.inkSecondary),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
        subtitle: Text(subtitle, style: const TextStyle(fontSize: 12.5, color: Palette.inkSecondary)),
        trailing: const Icon(Icons.chevron_right, color: Palette.inkMuted),
        onTap: onTap,
      ),
    );
  }
}
