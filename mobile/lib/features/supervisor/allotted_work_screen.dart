import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api_client.dart';
import '../../core/models.dart';
import '../../core/palette.dart';
import '../../shared/complaint_card.dart';
import '../../shared/duration_edit_sheet.dart';
import '../../shared/ui.dart';
import '../shared/complaint_detail_screen.dart';
import 'proxy_complete_task_screen.dart';

/// Every task currently out with a worker, campus-wide - the queue a
/// supervisor watches for time constraints, and the one place they act on a
/// phone-less worker's behalf: start it, adjust its deadline, or complete it
/// with a photo taken on the supervisor's own phone. No distinction is made
/// between a worker who has the app and one who doesn't - offering the same
/// actions for both is harmless, since a worker who completes their own task
/// first simply won't be here anymore.
class AllottedWorkScreen extends StatefulWidget {
  const AllottedWorkScreen({super.key});

  @override
  State<AllottedWorkScreen> createState() => _AllottedWorkScreenState();
}

class _AllottedWorkScreenState extends State<AllottedWorkScreen> {
  late Future<List<Complaint>> _future;
  final Set<String> _busyIds = {};

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<List<Complaint>> _load() async {
    final res = await context.read<ApiClient>().get(
      '/admin/complaints',
      query: {'status': 'ALLOTTED_TO_WORKER,IN_PROGRESS'},
    );
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

  Future<void> _adjustTime(Complaint c) async {
    final hours = await DurationEditSheet.show(context);
    if (hours == null || !mounted) return;

    setState(() => _busyIds.add(c.id));
    try {
      final res = await context
          .read<ApiClient>()
          .put('/admin/complaints/${c.id}/duration', {'durationHours': hours});
      if (mounted) {
        showSnack(context, res['message'] as String? ?? 'Deadline updated');
        await _refresh();
      }
    } on ApiException catch (e) {
      if (mounted) showSnack(context, e.message, error: true);
    } finally {
      if (mounted) setState(() => _busyIds.remove(c.id));
    }
  }

  Future<void> _startOnBehalf(Complaint c) async {
    setState(() => _busyIds.add(c.id));
    try {
      final res =
          await context.read<ApiClient>().post('/admin/complaints/${c.id}/start-for-worker');
      if (mounted) {
        showSnack(context, res['message'] as String? ?? 'Task started');
        await _refresh();
      }
    } on ApiException catch (e) {
      if (mounted) showSnack(context, e.message, error: true);
    } finally {
      if (mounted) setState(() => _busyIds.remove(c.id));
    }
  }

  Future<void> _completeOnBehalf(Complaint c) async {
    final done = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => ProxyCompleteTaskScreen(complaint: c)),
    );
    if (done == true) await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Allotted work')),
      body: FutureBuilder<List<Complaint>>(
        future: _future,
        builder: (context, snapshot) => AsyncBody<List<Complaint>>(
          snapshot: snapshot,
          onRetry: _refresh,
          builder: (complaints) {
            if (complaints.isEmpty) {
              return const EmptyState(
                icon: Icons.assignment_turned_in_outlined,
                title: 'Nothing out right now',
                subtitle: 'Every allotted task across every zone will show up here.',
              );
            }

            return RefreshIndicator(
              onRefresh: _refresh,
              child: ListView.builder(
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 20),
                itemCount: complaints.length,
                itemBuilder: (_, i) {
                  final c = complaints[i];
                  final busy = _busyIds.contains(c.id);

                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: ComplaintCard(
                      complaint: c,
                      onTap: () => _open(c),
                      trailing: c.worker != null
                          ? Padding(
                              padding: const EdgeInsets.only(left: 8),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  const Icon(Icons.person_outline, size: 15, color: Palette.inkMuted),
                                  const SizedBox(height: 2),
                                  Text(
                                    c.worker!.name,
                                    style: const TextStyle(fontSize: 11, color: Palette.inkMuted),
                                  ),
                                ],
                              ),
                            )
                          : null,
                      action: busy
                          ? const Padding(
                              padding: EdgeInsets.symmetric(vertical: 6),
                              child: Center(
                                child: SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(strokeWidth: 2.2),
                                ),
                              ),
                            )
                          : Row(
                              children: [
                                Expanded(
                                  child: OutlinedButton.icon(
                                    onPressed: () => _adjustTime(c),
                                    icon: const Icon(Icons.timer_outlined, size: 16),
                                    label: const Text('Adjust time', style: TextStyle(fontSize: 12.5)),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                if (c.status == 'ALLOTTED_TO_WORKER')
                                  Expanded(
                                    child: OutlinedButton.icon(
                                      onPressed: () => _startOnBehalf(c),
                                      icon: const Icon(Icons.play_arrow, size: 16),
                                      label: const Text('Start', style: TextStyle(fontSize: 12.5)),
                                    ),
                                  )
                                else
                                  Expanded(
                                    child: FilledButton.icon(
                                      style: FilledButton.styleFrom(backgroundColor: Palette.good),
                                      onPressed: () => _completeOnBehalf(c),
                                      icon: const Icon(Icons.check, size: 16),
                                      label: const Text('Complete', style: TextStyle(fontSize: 12.5)),
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
