import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api_client.dart';
import '../../core/models.dart';
import '../../shared/complaint_card.dart';
import '../../shared/ui.dart';
import '../shared/complaint_detail_screen.dart';

/// Every complaint waiting on Admin or Worker Supervisor right now -
/// verification, zone allotment, hostel allotment and escalations, merged
/// into one list and sorted by urgency (overdue, then soonest-due). Replaces
/// scanning four separate queue counts with one prioritised list; the status
/// chip and SLA countdown on each card already say what it is waiting for,
/// so tapping straight through to the detail screen - where the right
/// action for that state is already wired up - is all this needs to do.
class NeedsAttentionScreen extends StatefulWidget {
  const NeedsAttentionScreen({super.key});

  @override
  State<NeedsAttentionScreen> createState() => _NeedsAttentionScreenState();
}

class _NeedsAttentionScreenState extends State<NeedsAttentionScreen> {
  late Future<List<Complaint>> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<List<Complaint>> _load() async {
    final res = await context.read<ApiClient>().get('/admin/attention');
    return (res['items'] as List)
        .map((i) => Complaint.fromJson(i as Map<String, dynamic>))
        .toList();
  }

  Future<void> _refresh() async {
    setState(() => _future = _load());
    await _future;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Needs your attention')),
      body: FutureBuilder<List<Complaint>>(
        future: _future,
        builder: (context, snapshot) => AsyncBody<List<Complaint>>(
          snapshot: snapshot,
          onRetry: _refresh,
          builder: (items) {
            if (items.isEmpty) {
              return const EmptyState(
                icon: Icons.done_all,
                title: 'Nothing needs you right now',
                subtitle: 'Verification, allotment and escalations all land here, '
                    'most urgent first.',
              );
            }

            return RefreshIndicator(
              onRefresh: _refresh,
              child: ListView.builder(
                padding: const EdgeInsets.symmetric(vertical: 8),
                itemCount: items.length,
                itemBuilder: (_, i) {
                  final c = items[i];
                  return ComplaintCard(
                    complaint: c,
                    showReporterKind: true,
                    onTap: () async {
                      await Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => ComplaintDetailScreen(complaintId: c.id)),
                      );
                      await _refresh();
                    },
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
