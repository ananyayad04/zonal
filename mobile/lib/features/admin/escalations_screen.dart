import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api_client.dart';
import '../../core/models.dart';
import '../../core/palette.dart';
import '../../shared/allotment_details_sheet.dart';
import '../../shared/complaint_card.dart';
import '../../shared/pick_any_worker_sheet.dart';
import '../../shared/ui.dart';
import '../shared/complaint_detail_screen.dart';

/// Everything that fell through a crack. Each entry says which rule fired, so
/// the admin knows whether the problem is a person or the staffing.
class EscalationsScreen extends StatefulWidget {
  const EscalationsScreen({super.key});

  @override
  State<EscalationsScreen> createState() => _EscalationsScreenState();
}

class _EscalationsScreenState extends State<EscalationsScreen> {
  late Future<List<Complaint>> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<List<Complaint>> _load() async {
    final res = await context.read<ApiClient>().get('/admin/escalations');
    return (res['complaints'] as List)
        .map((c) => Complaint.fromJson(c as Map<String, dynamic>))
        .toList();
  }

  Future<void> _refresh() async {
    setState(() => _future = _load());
    await _future;
  }

  Future<void> _allotAnyone(Complaint c) async {
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
      appBar: AppBar(title: const Text('Escalations')),
      body: FutureBuilder<List<Complaint>>(
        future: _future,
        builder: (context, snapshot) => AsyncBody<List<Complaint>>(
          snapshot: snapshot,
          onRetry: _refresh,
          builder: (complaints) {
            if (complaints.isEmpty) {
              return const EmptyState(
                icon: Icons.verified_outlined,
                title: 'Nothing escalated',
                subtitle: 'Missed deadlines and unanswered help requests appear here.',
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
                    action: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: Palette.critical.withValues(alpha: 0.08),
                            borderRadius: BorderRadius.circular(9),
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Icon(Icons.warning_amber,
                                  size: 16, color: Palette.critical),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  _reasonText(c.escalationReason),
                                  style: const TextStyle(
                                    fontSize: 12.5,
                                    height: 1.3,
                                    color: Palette.critical,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 9),
                        FilledButton.icon(
                          style: FilledButton.styleFrom(
                            minimumSize: const Size.fromHeight(42),
                          ),
                          onPressed: () => _allotAnyone(c),
                          icon: const Icon(Icons.person_add_alt, size: 19),
                          label: const Text('Allot anyone on campus'),
                        ),
                      ],
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

  static String _reasonText(String? reason) => switch (reason) {
        'OFFICER_SLA_BREACH' => 'The zone officer did not allot a worker in time.',
        'WORKER_SLA_BREACH' => 'The worker missed the completion deadline.',
        'HELP_REQUEST_EXPIRED' => 'No other zone officer answered the request for help.',
        'NO_FREE_WORKER_CAMPUS_WIDE' =>
          'Every worker on campus was busy or off duty when this came in.',
        'NO_ZONE_OFFICER' => 'That zone has no officer assigned to it.',
        'REJECTED_TWICE' => 'The resident sent the work back more than once.',
        'NO_WARDEN_ASSIGNED' => 'That hostel has no warden assigned to it.',
        'HOSTEL_STAFF_SLA_BREACH' => 'No one allotted a worker to this hostel complaint in time.',
        'HOSTEL_REJECTED_TWICE' => 'The warden sent the work back more than once.',
        _ => 'Escalated to the admin.',
      };
}
