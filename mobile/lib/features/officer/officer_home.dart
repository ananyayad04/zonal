import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api_client.dart';
import '../../core/models.dart';
import '../../core/palette.dart';
import '../../core/session.dart';
import '../../core/theme.dart';
import '../../shared/complaint_card.dart';
import '../../shared/ui.dart';
import '../shared/app_drawer.dart';
import '../shared/complaint_detail_screen.dart';
import 'allot_sheet.dart';
import 'help_inbox_screen.dart';

class OfficerHome extends StatefulWidget {
  const OfficerHome({super.key});

  @override
  State<OfficerHome> createState() => _OfficerHomeState();
}

class _OfficerHomeState extends State<OfficerHome> {
  late Future<Map<String, dynamic>> _future;

  /// Complaints this officer verified or rejected in this session. Used only
  /// to confirm the action on screen - a verified complaint stays in the queue
  /// (it still needs a worker), so without a marker it looks untouched.
  final Set<String> _justVerified = {};
  final Set<String> _justRejected = {};

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<Map<String, dynamic>> _load() =>
      context.read<ApiClient>().get('/officer/dashboard');

  Future<void> _refresh() async {
    setState(() => _future = _load());
    await _future;
    if (mounted) context.read<Session>().refreshUnreadCount();
  }

  Future<void> _allot(Complaint c) async {
    final done = await AllotSheet.show(context, complaint: c);
    if (done == true) await _refresh();
  }

  /// The officer can verify a complaint in their own zone without waiting for
  /// an admin — they see it the moment it is filed.
  Future<void> _review(Complaint c, bool approve) async {
    String? reason;
    if (!approve) {
      final controller = TextEditingController();
      reason = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Reject this complaint'),
          content: TextField(
            controller: controller,
            autofocus: true,
            maxLines: 2,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(hintText: 'Why is it being rejected?'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Palette.critical),
              onPressed: () => Navigator.of(ctx).pop(
                controller.text.trim().isEmpty ? 'Not a cleanliness issue' : controller.text.trim(),
              ),
              child: const Text('Reject'),
            ),
          ],
        ),
      );
      if (reason == null) return;
    }

    if (!mounted) return;

    try {
      final res = await context.read<ApiClient>().post(
        '/officer/complaints/${c.id}/review',
        {'approve': approve, if (reason != null) 'reason': reason},
      );
      if (mounted) {
        // Mark it so the card visibly changes the moment the server confirms.
        setState(() {
          if (approve) {
            _justVerified.add(c.id);
          } else {
            _justRejected.add(c.id);
          }
        });
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
    final zone = context.watch<Session>().user?.zone;

    return Scaffold(
      appBar: AppBar(
        title: Text(zone == null ? 'My zone' : zone.name),
        actions: const [NotificationBell()],
      ),
      drawer: const AppDrawer(),
      body: FutureBuilder<Map<String, dynamic>>(
        future: _future,
        builder: (context, snapshot) => AsyncBody<Map<String, dynamic>>(
          snapshot: snapshot,
          onRetry: _refresh,
          builder: (data) {
            final zoneData = data['zone'] as Map<String, dynamic>;
            final totals = data['totals'] as Map<String, dynamic>;
            final roster = (data['roster'] as List).cast<Map<String, dynamic>>();
            final queue = (data['actionQueue'] as List)
                .map((c) => Complaint.fromJson(c as Map<String, dynamic>))
                .toList();

            final incomingHelp = totals['incomingHelpRequests'] as int? ?? 0;

            return RefreshIndicator(
              onRefresh: _refresh,
              child: ListView(
                padding: const EdgeInsets.only(bottom: 30),
                children: [
                  _ZoneHeader(zone: zoneData, totals: totals),

                  if (incomingHelp > 0)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          borderRadius: BorderRadius.circular(12),
                          onTap: () async {
                            await Navigator.of(context).push(
                              MaterialPageRoute(builder: (_) => const HelpInboxScreen()),
                            );
                            await _refresh();
                          },
                          child: Container(
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              color: const Color(0xFF7A52CC).withValues(alpha: 0.10),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                  color: const Color(0xFF7A52CC).withValues(alpha: 0.4)),
                            ),
                            child: Row(
                              children: [
                                const Icon(Icons.handshake,
                                    color: Color(0xFF7A52CC), size: 21),
                                const SizedBox(width: 11),
                                Expanded(
                                  child: Text(
                                    '$incomingHelp zone${incomingHelp == 1 ? '' : 's'} '
                                    'asking you for a worker',
                                    style: const TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w700,
                                      color: Color(0xFF7A52CC),
                                    ),
                                  ),
                                ),
                                const Icon(Icons.chevron_right,
                                    color: Color(0xFF7A52CC)),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),

                  if (queue.isEmpty)
                    const Padding(
                      padding: EdgeInsets.only(top: 30),
                      child: EmptyState(
                        icon: Icons.inbox_outlined,
                        title: 'Nothing waiting on you',
                        subtitle: 'Verified complaints for your zone appear here for '
                            'you to allot.',
                      ),
                    )
                  else ...[
                    const Padding(
                      padding: EdgeInsets.fromLTRB(18, 20, 18, 0),
                      child: Text(
                        'WAITING ON YOU',
                        style: TextStyle(
                          fontSize: 10.5,
                          letterSpacing: 1.8,
                          fontWeight: FontWeight.w700,
                          color: Palette.warning,
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    for (final c in queue)
                      ComplaintCard(
                        complaint: c,
                        showReporterKind: true,
                        onTap: () => _open(c),
                        action: c.status == 'UNDER_REVIEW'
                            ? Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Container(
                                    width: double.infinity,
                                    padding: const EdgeInsets.all(10),
                                    decoration: BoxDecoration(
                                      color: Palette.warning.withValues(alpha: 0.10),
                                      borderRadius: BorderRadius.circular(9),
                                    ),
                                    child: const Row(
                                      children: [
                                        Icon(Icons.gavel, size: 16, color: Palette.warning),
                                        SizedBox(width: 8),
                                        Expanded(
                                          child: Text(
                                            'Not verified yet — you or the admin can verify it',
                                            style: TextStyle(
                                                fontSize: 12.5, color: Palette.warning),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(height: 9),
                                  Row(
                                    children: [
                                      Expanded(
                                        child: FilledButton.icon(
                                          style: FilledButton.styleFrom(
                                            backgroundColor: Palette.good,
                                            minimumSize: const Size.fromHeight(42),
                                          ),
                                          onPressed: () => _review(c, true),
                                          icon: const Icon(Icons.check, size: 18),
                                          label: const Text('Verify'),
                                        ),
                                      ),
                                      const SizedBox(width: 9),
                                      Expanded(
                                        child: OutlinedButton.icon(
                                          style: OutlinedButton.styleFrom(
                                            foregroundColor: Palette.critical,
                                            side: const BorderSide(color: Palette.critical),
                                            minimumSize: const Size.fromHeight(42),
                                          ),
                                          onPressed: () => _review(c, false),
                                          icon: const Icon(Icons.close, size: 18),
                                          label: const Text('Reject'),
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              )
                            : c.status == 'HELP_REQUESTED'
                            ? Container(
                                padding: const EdgeInsets.all(11),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF7A52CC).withValues(alpha: 0.09),
                                  borderRadius: BorderRadius.circular(9),
                                ),
                                child: const Row(
                                  children: [
                                    Icon(Icons.hourglass_top,
                                        size: 17, color: Color(0xFF7A52CC)),
                                    SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        'Waiting for a nearby zone to lend a worker',
                                        style: TextStyle(
                                            fontSize: 12.5, color: Color(0xFF7A52CC)),
                                      ),
                                    ),
                                  ],
                                ),
                              )
                            : Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  if (_justVerified.contains(c.id)) ...[
                                    Container(
                                      width: double.infinity,
                                      padding: const EdgeInsets.all(10),
                                      decoration: BoxDecoration(
                                        color: Palette.good.withValues(alpha: 0.12),
                                        borderRadius: BorderRadius.circular(9),
                                      ),
                                      child: const Row(
                                        children: [
                                          Icon(Icons.verified,
                                              size: 17, color: Palette.good),
                                          SizedBox(width: 8),
                                          Expanded(
                                            child: Text(
                                              'You verified this — now send someone',
                                              style: TextStyle(
                                                fontSize: 12.5,
                                                fontWeight: FontWeight.w600,
                                                color: Palette.good,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    const SizedBox(height: 9),
                                  ],
                                  FilledButton.icon(
                                    style: FilledButton.styleFrom(
                                        minimumSize: const Size.fromHeight(42)),
                                    onPressed: () => _allot(c),
                                    icon: const Icon(Icons.person_add_alt, size: 19),
                                    label: const Text('Allot a worker'),
                                  ),
                                ],
                              ),
                      ),
                  ],

                  _RosterSection(roster: roster),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Future<void> _open(Complaint c) async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => ComplaintDetailScreen(complaintId: c.id)),
    );
    await _refresh();
  }
}

class _ZoneHeader extends StatelessWidget {
  final Map<String, dynamic> zone;
  final Map<String, dynamic> totals;

  const _ZoneHeader({required this.zone, required this.totals});

  @override
  Widget build(BuildContext context) {
    final color = colorFromHex(zone['colorHex'] as String? ?? '#0072B2');

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 18),
      color: Colors.white,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 13,
                height: 13,
                decoration:
                    BoxDecoration(color: color, borderRadius: BorderRadius.circular(3.5)),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  zone['label'] as String? ?? '',
                  style: const TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    color: Palette.inkSecondary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              _Tile(
                value: '${totals['needsMyAction'] ?? 0}',
                label: 'To allot',
                color: (totals['needsMyAction'] ?? 0) > 0 ? Palette.warning : null,
              ),
              _Tile(
                value: '${totals['workersFree'] ?? 0}',
                label: 'Free workers',
                color: (totals['workersFree'] ?? 0) > 0 ? Palette.good : Palette.critical,
              ),
              _Tile(
                value: '${totals['workersBusy'] ?? 0}',
                label: 'Busy',
              ),
              _Tile(
                value: '${totals['workersTotal'] ?? 0}',
                label: 'Roster',
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  final String value;
  final String label;
  final Color? color;

  const _Tile({required this.value, required this.label, this.color});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            value,
            style: TextStyle(
              fontSize: 26,
              height: 1,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.8,
              color: color ?? Palette.inkPrimary,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            label.toUpperCase(),
            style: const TextStyle(
              fontSize: 9,
              letterSpacing: 0.9,
              fontWeight: FontWeight.w700,
              color: Palette.inkMuted,
            ),
          ),
        ],
      ),
    );
  }
}

class _RosterSection extends StatelessWidget {
  final List<Map<String, dynamic>> roster;

  const _RosterSection({required this.roster});

  @override
  Widget build(BuildContext context) {
    if (roster.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 26, 18, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'YOUR WORKERS',
            style: TextStyle(
              fontSize: 10.5,
              letterSpacing: 1.8,
              fontWeight: FontWeight.w700,
              color: Palette.inkMuted,
            ),
          ),
          const SizedBox(height: 12),
          for (final w in roster)
            Padding(
              padding: const EdgeInsets.only(bottom: 11),
              child: Row(
                children: [
                  Container(
                    width: 9,
                    height: 9,
                    decoration: BoxDecoration(
                      color: w['dutyStatus'] == 'OFF'
                          ? Palette.inkMuted
                          : w['availability'] == 'AVAILABLE'
                              ? Palette.good
                              : Palette.warning,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 11),
                  Expanded(
                    child: Text(
                      w['name'] as String? ?? '',
                      style: const TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w600),
                    ),
                  ),
                  Text(
                    w['dutyStatus'] == 'OFF'
                        ? 'Off duty'
                        : w['availability'] == 'AVAILABLE'
                            ? 'Free'
                            : 'On a task',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: w['dutyStatus'] == 'OFF'
                          ? Palette.inkMuted
                          : w['availability'] == 'AVAILABLE'
                              ? Palette.good
                              : Palette.warning,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    '${w['tasksCompletedToday'] ?? 0} today',
                    style: const TextStyle(fontSize: 11.5, color: Palette.inkMuted),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
