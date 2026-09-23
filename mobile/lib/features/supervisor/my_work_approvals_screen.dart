import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api_client.dart';
import '../../core/models.dart';
import '../../core/palette.dart';
import '../../shared/complaint_card.dart';
import '../../shared/ui.dart';
import '../resident/satisfaction_sheet.dart';
import '../shared/complaint_detail_screen.dart';

/// Work orders the supervisor created themselves, finished by a worker and
/// sitting at WORK_DONE - the same "please confirm" queue a citizen sees for
/// their own complaints, since the supervisor IS the reporter on a work
/// order. Reuses GET /complaints/awaiting-confirmation and
/// POST /:id/satisfaction as-is - both key on reporterId, not role, so
/// nothing on the backend needed to change for this to work.
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
    final res = await context.read<ApiClient>().get('/complaints/awaiting-confirmation');
    return (res['complaints'] as List).map((c) => Complaint.fromJson(c as Map<String, dynamic>)).toList();
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
      appBar: AppBar(title: const Text('My work orders')),
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
                subtitle: 'Work orders you created appear here once a worker '
                    'finishes them, for you to approve or send back.',
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
