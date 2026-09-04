import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api_client.dart';
import '../../core/models.dart';
import '../../shared/allotment_details_sheet.dart';
import '../../shared/complaint_card.dart';
import '../../shared/pick_any_worker_sheet.dart';
import '../../shared/ui.dart';
import '../shared/complaint_detail_screen.dart';

const _needsAllotment = {'ALLOTTED_TO_HOSTEL_STAFF', 'ESCALATED', 'REOPENED'};

/// Admin and Worker Supervisor's view across every hostel at once - the
/// campus-wide counterpart to a Warden's own (single-hostel) home screen.
/// Allotment only: approving finished work stays Warden-only, so a WORK_DONE
/// item here carries no action, just the status.
class HostelComplaintsScreen extends StatefulWidget {
  const HostelComplaintsScreen({super.key});

  @override
  State<HostelComplaintsScreen> createState() => _HostelComplaintsScreenState();
}

class _HostelComplaintsScreenState extends State<HostelComplaintsScreen> {
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Hostel complaints')),
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
                subtitle: 'Complaints filed from inside any hostel appear here.',
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
