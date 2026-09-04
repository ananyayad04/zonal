import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api_client.dart';
import '../../core/models.dart';
import '../../core/palette.dart';
import '../../core/session.dart';
import '../../shared/allotment_details_sheet.dart';
import '../../shared/complaint_card.dart';
import '../../shared/pick_any_worker_sheet.dart';
import '../../shared/ui.dart';
import '../shared/app_drawer.dart';
import '../shared/complaint_detail_screen.dart';
import '../shared/complaint_search_screen.dart';
import 'warden_approval_sheet.dart';

const _needsAllotment = {'ALLOTTED_TO_HOSTEL_STAFF', 'ESCALATED', 'REOPENED'};

/// A Warden's home: the complaint queue for their one hostel. Simpler than
/// the officer's screen - no zone roster, no help-request inbox, since
/// allotment here is always "any free worker on campus", never zone-scoped.
class WardenHome extends StatefulWidget {
  const WardenHome({super.key});

  @override
  State<WardenHome> createState() => _WardenHomeState();
}

class _WardenHomeState extends State<WardenHome> {
  late Future<List<Complaint>> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<List<Complaint>> _load() async {
    final res = await context.read<ApiClient>().get('/hostel/complaints');
    return (res['complaints'] as List)
        .map((c) => Complaint.fromJson(c as Map<String, dynamic>))
        .toList();
  }

  Future<void> _refresh() async {
    setState(() => _future = _load());
    await _future;
    if (mounted) context.read<Session>().refreshUnreadCount();
  }

  Future<void> _allot(Complaint c) async {
    try {
      final res = await context.read<ApiClient>().get('/hostel/free-workers');
      final options = flattenFreeWorkers((res['zones'] as List).cast<Map<String, dynamic>>());

      if (!mounted) return;
      if (options.isEmpty) {
        showSnack(context, 'No worker is free anywhere on campus', error: true);
        return;
      }

      final chosen = await PickAnyWorkerSheet.show(context, options);
      if (chosen == null || !mounted) return;

      final details = await AllotmentDetailsSheet.show(context);
      if (details == null || !mounted) return;

      final result = await context.read<ApiClient>().post(
        '/hostel/complaints/${c.id}/allot',
        {
          'workerUserId': chosen,
          if (details.instructions != null) 'instructions': details.instructions,
          if (details.durationHours != null) 'durationHours': details.durationHours,
        },
      );

      if (mounted) {
        showSnack(context, result['message'] as String? ?? 'Allotted');
        await _refresh();
      }
    } on ApiException catch (e) {
      if (mounted) showSnack(context, e.message, error: true);
    }
  }

  Future<void> _decide(Complaint c, bool satisfied) async {
    final done = await WardenApprovalSheet.show(context, complaint: c, satisfied: satisfied);
    if (done == true) await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final hostelName = context.watch<Session>().user?.hostel?.name;

    return Scaffold(
      appBar: AppBar(
        title: Text(hostelName ?? 'Warden'),
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
      body: FutureBuilder<List<Complaint>>(
        future: _future,
        builder: (context, snapshot) => AsyncBody<List<Complaint>>(
          snapshot: snapshot,
          onRetry: _refresh,
          builder: (complaints) {
            if (complaints.isEmpty) {
              return const EmptyState(
                icon: Icons.apartment_outlined,
                title: 'Nothing yet',
                subtitle: 'Complaints filed from inside this hostel appear here.',
              );
            }

            return RefreshIndicator(
              onRefresh: _refresh,
              child: ListView.builder(
                padding: const EdgeInsets.symmetric(vertical: 8),
                itemCount: complaints.length,
                itemBuilder: (_, i) {
                  final c = complaints[i];
                  return ComplaintCard(
                    complaint: c,
                    showReporterKind: true,
                    onTap: () async {
                      await Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => ComplaintDetailScreen(complaintId: c.id)),
                      );
                      await _refresh();
                    },
                    action: _needsAllotment.contains(c.status)
                        ? FilledButton.icon(
                            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(42)),
                            onPressed: () => _allot(c),
                            icon: const Icon(Icons.person_add_alt, size: 19),
                            label: const Text('Allot to a worker'),
                          )
                        : c.status == 'WORK_DONE'
                            ? Row(
                                children: [
                                  Expanded(
                                    child: FilledButton.icon(
                                      style: FilledButton.styleFrom(
                                        backgroundColor: Palette.good,
                                        minimumSize: const Size.fromHeight(42),
                                      ),
                                      onPressed: () => _decide(c, true),
                                      icon: const Icon(Icons.check, size: 18),
                                      label: const Text('Approve'),
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: OutlinedButton.icon(
                                      style: OutlinedButton.styleFrom(
                                        foregroundColor: Palette.serious,
                                        side: const BorderSide(color: Palette.serious),
                                        minimumSize: const Size.fromHeight(42),
                                      ),
                                      onPressed: () => _decide(c, false),
                                      icon: const Icon(Icons.replay, size: 18),
                                      label: const Text('Send back'),
                                    ),
                                  ),
                                ],
                              )
                            : null,
                  );
                },
              ),
            );
          },
        ),
      ),
    );
  }
}
