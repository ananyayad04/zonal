import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api_client.dart';
import '../../core/models.dart';
import '../../core/palette.dart';
import '../../core/session.dart';
import '../../shared/complaint_card.dart';
import '../../shared/ui.dart';
import '../shared/app_drawer.dart';
import '../shared/complaint_detail_screen.dart';
import 'new_complaint_screen.dart';
import 'community_screen.dart';
import 'satisfaction_sheet.dart';

class ResidentHome extends StatefulWidget {
  const ResidentHome({super.key});

  @override
  State<ResidentHome> createState() => _ResidentHomeState();
}

class _ResidentHomeState extends State<ResidentHome> {
  late Future<_ResidentData> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<_ResidentData> _load() async {
    final api = context.read<ApiClient>();
    final results = await Future.wait([
      api.get('/complaints/mine'),
      api.get('/complaints/awaiting-confirmation'),
    ]);

    List<Complaint> parse(Map<String, dynamic> res) => (res['complaints'] as List)
        .map((c) => Complaint.fromJson(c as Map<String, dynamic>))
        .toList();

    return _ResidentData(
      all: parse(results[0]),
      awaiting: parse(results[1]),
    );
  }

  Future<void> _refresh() async {
    setState(() => _future = _load());
    await _future;
    if (mounted) context.read<Session>().refreshUnreadCount();
  }

  Future<void> _report() async {
    final created = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const NewComplaintScreen()),
    );
    if (created == true) await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<Session>();
    final name = session.user?.name.split(' ').first ?? 'there';
    final isStudent = session.role == Role.student;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Smart Clean Campus'),
        actions: [
          IconButton(
            tooltip: isStudent ? 'Student reports' : 'Resident reports',
            icon: const Icon(Icons.groups_outlined),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const CommunityScreen()),
            ),
          ),
          const NotificationBell(),
        ],
      ),
      drawer: const AppDrawer(),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _report,
        icon: const Icon(Icons.add_a_photo_outlined),
        label: const Text('Report'),
      ),
      body: FutureBuilder<_ResidentData>(
        future: _future,
        builder: (context, snapshot) => AsyncBody<_ResidentData>(
          snapshot: snapshot,
          onRetry: _refresh,
          builder: (data) => RefreshIndicator(
            onRefresh: _refresh,
            child: ListView(
              padding: const EdgeInsets.only(bottom: 96),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 18, 18, 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Hello, $name',
                        style: const TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.5,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        data.all.isEmpty
                            ? 'Spotted something unclean? Report it.'
                            : '${data.all.length} complaint${data.all.length == 1 ? '' : 's'} filed',
                        style: const TextStyle(fontSize: 13.5, color: Palette.inkSecondary),
                      ),
                    ],
                  ),
                ),

                // Anything finished and waiting on this person comes first -
                // it is the only thing on this screen that is blocked on them.
                if (data.awaiting.isNotEmpty) ...[
                  const Padding(
                    padding: EdgeInsets.fromLTRB(18, 18, 18, 0),
                    child: Text(
                      'WAITING FOR YOU',
                      style: TextStyle(
                        fontSize: 10.5,
                        letterSpacing: 1.8,
                        fontWeight: FontWeight.w700,
                        color: Palette.warning,
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  for (final c in data.awaiting)
                    ComplaintCard(
                      complaint: c,
                      onTap: () => _open(c),
                      action: Row(
                        children: [
                          Expanded(
                            child: FilledButton.icon(
                              style: FilledButton.styleFrom(
                                backgroundColor: Palette.good,
                                minimumSize: const Size.fromHeight(40),
                                textStyle: const TextStyle(
                                    fontSize: 13.5, fontWeight: FontWeight.w600),
                              ),
                              onPressed: () async {
                                final ok = await SatisfactionSheet.show(
                                  context,
                                  complaint: c,
                                  satisfied: true,
                                );
                                if (ok == true) await _refresh();
                              },
                              icon: const Icon(Icons.check, size: 17),
                              label: const Text('Looks good'),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: OutlinedButton.icon(
                              style: OutlinedButton.styleFrom(
                                foregroundColor: Palette.serious,
                                side: const BorderSide(color: Palette.serious),
                                minimumSize: const Size.fromHeight(40),
                                textStyle: const TextStyle(
                                    fontSize: 13.5, fontWeight: FontWeight.w600),
                              ),
                              onPressed: () async {
                                final ok = await SatisfactionSheet.show(
                                  context,
                                  complaint: c,
                                  satisfied: false,
                                );
                                if (ok == true) await _refresh();
                              },
                              icon: const Icon(Icons.replay, size: 17),
                              label: const Text('Send back'),
                            ),
                          ),
                        ],
                      ),
                    ),
                  const SizedBox(height: 10),
                ],

                if (data.all.isEmpty)
                  const Padding(
                    padding: EdgeInsets.only(top: 40),
                    child: EmptyState(
                      icon: Icons.cleaning_services_outlined,
                      title: 'No complaints yet',
                      subtitle:
                          'Tap Report, photograph what needs cleaning, and it goes '
                          'straight to the officer for that zone.',
                    ),
                  )
                else ...[
                  const Padding(
                    padding: EdgeInsets.fromLTRB(18, 12, 18, 0),
                    child: Text(
                      'YOUR COMPLAINTS',
                      style: TextStyle(
                        fontSize: 10.5,
                        letterSpacing: 1.8,
                        fontWeight: FontWeight.w700,
                        color: Palette.inkMuted,
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  for (final c in data.all)
                    ComplaintCard(complaint: c, onTap: () => _open(c)),
                ],
              ],
            ),
          ),
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

class _ResidentData {
  final List<Complaint> all;
  final List<Complaint> awaiting;

  const _ResidentData({required this.all, required this.awaiting});
}
