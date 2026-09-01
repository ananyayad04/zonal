import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api_client.dart';
import '../../core/models.dart';
import '../../shared/allotment_details_sheet.dart';
import '../../shared/complaint_card.dart';
import '../../shared/pick_any_worker_sheet.dart';
import '../../shared/ui.dart';
import '../shared/complaint_detail_screen.dart';

/// Everything approved but not yet in a worker's hands — routed to a zone
/// officer (or waiting on one officer's help request to another) but stuck
/// there. The admin can allot straight to any worker on campus from here,
/// the same override escalations already have, without waiting for the
/// officer to act or for the SLA to escalate it automatically.
class UnallottedComplaintsScreen extends StatefulWidget {
  const UnallottedComplaintsScreen({super.key});

  @override
  State<UnallottedComplaintsScreen> createState() =>
      _UnallottedComplaintsScreenState();
}

class _UnallottedComplaintsScreenState
    extends State<UnallottedComplaintsScreen> {
  late Future<List<Complaint>> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<List<Complaint>> _load() async {
    final res = await context.read<ApiClient>().get(
      '/admin/complaints',
      query: {'status': 'ALLOTTED_TO_OFFICER,HELP_REQUESTED'},
    );
    return (res['complaints'] as List)
        .map((c) => Complaint.fromJson(c as Map<String, dynamic>))
        .toList();
  }

  Future<void> _refresh() async {
    setState(() => _future = _load());
    await _future;
  }

  Future<void> _allot(Complaint c) async {
    try {
      final res = await context.read<ApiClient>().get('/admin/free-workers');
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
        '/admin/complaints/${c.id}/force-allot',
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Unallotted complaints')),
      body: FutureBuilder<List<Complaint>>(
        future: _future,
        builder: (context, snapshot) => AsyncBody<List<Complaint>>(
          snapshot: snapshot,
          onRetry: _refresh,
          builder: (complaints) {
            if (complaints.isEmpty) {
              return const EmptyState(
                icon: Icons.task_alt_outlined,
                title: 'Nothing waiting',
                subtitle: 'Complaints with no worker allotted yet — whether they are '
                    'sitting with a zone officer or a cross-zone help request — '
                    'appear here.',
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
                        MaterialPageRoute(
                          builder: (_) => ComplaintDetailScreen(complaintId: c.id),
                        ),
                      );
                      await _refresh();
                    },
                    action: FilledButton.icon(
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(42),
                      ),
                      onPressed: () => _allot(c),
                      icon: const Icon(Icons.person_add_alt, size: 19),
                      label: const Text('Allot to a worker'),
                    ),
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
