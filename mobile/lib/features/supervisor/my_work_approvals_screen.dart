import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api_client.dart';
import '../../core/models.dart';
import '../../core/palette.dart';
import '../../shared/complaint_card.dart';
import '../../shared/ui.dart';
import '../resident/satisfaction_sheet.dart';
import '../shared/complaint_detail_screen.dart';

/// Every non-hostel complaint sitting at WORK_DONE, campus-wide - a
/// Supervisor may approve or send back any of them, not just the work
/// orders they created themselves, since a citizen reporter can be slow to
/// respond and the Supervisor is watching allotted work generally. Hostel
/// complaints are excluded - those go through HostelComplaintsScreen
/// instead, since a hostel complaint's approval flow is different (Warden
/// or Supervisor, no citizen confirm/reopen step). Reuses
/// POST /complaints/:id/satisfaction as-is - it now allows a Supervisor
/// regardless of who filed the complaint, not just their own reports.
class MyWorkApprovalsScreen extends StatefulWidget {
  const MyWorkApprovalsScreen({super.key});

  @override
  State<MyWorkApprovalsScreen> createState() => _MyWorkApprovalsScreenState();
}

class _MyWorkApprovalsScreenState extends State<MyWorkApprovalsScreen> {
  late Future<List<Complaint>> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<List<Complaint>> _load() async {
    final res = await context
        .read<ApiClient>()
        .get('/admin/complaints', query: {'status': 'WORK_DONE'});
    return (res['complaints'] as List)
        .map((c) => Complaint.fromJson(c as Map<String, dynamic>))
        .where((c) => !c.isHostelComplaint)
        .toList();
  }

  Future<void> _refresh() async {
    setState(() => _future = _load());
    await _future;
  }

  Future<void> _open(Complaint c) async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => ComplaintDetailScreen(complaintId: c.id)),
    );
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Awaiting approval')),
      body: FutureBuilder<List<Complaint>>(
        future: _future,
        builder: (context, snapshot) => AsyncBody<List<Complaint>>(
          snapshot: snapshot,
          onRetry: _refresh,
          builder: (complaints) {
            if (complaints.isEmpty) {
              return const EmptyState(
                icon: Icons.fact_check_outlined,
                title: 'Nothing waiting on you',
                subtitle: 'Any complaint or work order finished by a worker appears '
                    'here for you to approve or send back, not just the ones you '
                    'created yourself.',
              );
            }

            return RefreshIndicator(
              onRefresh: _refresh,
              child: ListView.builder(
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 20),
                itemCount: complaints.length,
                itemBuilder: (_, i) {
                  final c = complaints[i];
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: ComplaintCard(
                      complaint: c,
                      onTap: () => _open(c),
                      action: Row(
                        children: [
                          Expanded(
                            child: FilledButton.icon(
                              style: FilledButton.styleFrom(
                                backgroundColor: Palette.good,
                                minimumSize: const Size.fromHeight(40),
                                textStyle:
                                    const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
                              ),
                              onPressed: () async {
                                final ok =
                                    await SatisfactionSheet.show(context, complaint: c, satisfied: true);
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
                                textStyle:
                                    const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
                              ),
                              onPressed: () async {
                                final ok = await SatisfactionSheet.show(context,
                                    complaint: c, satisfied: false);
                                if (ok == true) await _refresh();
                              },
                              icon: const Icon(Icons.replay, size: 17),
                              label: const Text('Send back'),
                            ),
                          ),
                        ],
                      ),
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
