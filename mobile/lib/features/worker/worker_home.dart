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
import 'complete_task_screen.dart';

class WorkerHome extends StatefulWidget {
  const WorkerHome({super.key});

  @override
  State<WorkerHome> createState() => _WorkerHomeState();
}

class _WorkerHomeState extends State<WorkerHome> {
  late Future<_WorkerData> _future;
  bool _togglingDuty = false;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<_WorkerData> _load() async {
    final api = context.read<ApiClient>();
    final status = await api.get('/worker/status');

    // An unverified worker has no access to the task endpoints, so do not
    // even ask - their screen is the waiting-for-approval one.
    if (status['approvalStatus'] != 'ACTIVE') {
      return _WorkerData(status: status, active: const [], history: const []);
    }

    final tasks = await api.get('/worker/tasks');
    List<Complaint> parse(String key) => (tasks[key] as List)
        .map((c) => Complaint.fromJson(c as Map<String, dynamic>))
        .toList();

    return _WorkerData(
      status: status,
      active: parse('active'),
      history: parse('history'),
    );
  }

  Future<void> _refresh() async {
    setState(() => _future = _load());
    await _future;
    if (mounted) await context.read<Session>().refreshUser();
  }

  Future<void> _toggleDuty(bool on) async {
    setState(() => _togglingDuty = true);
    try {
      final res = await context
          .read<ApiClient>()
          .post('/worker/duty', {'dutyStatus': on ? 'ON' : 'OFF'});
      if (mounted) {
        showSnack(context, res['message'] as String? ?? 'Updated');
        await _refresh();
      }
    } on ApiException catch (e) {
      if (mounted) showSnack(context, e.message, error: true);
    } finally {
      if (mounted) setState(() => _togglingDuty = false);
    }
  }

  Future<void> _start(Complaint c) async {
    try {
      await context.read<ApiClient>().post('/worker/tasks/${c.id}/start');
      if (mounted) {
        showSnack(context, 'Task started');
        await _refresh();
      }
    } on ApiException catch (e) {
      if (mounted) showSnack(context, e.message, error: true);
    }
  }

  Future<void> _complete(Complaint c) async {
    final done = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => CompleteTaskScreen(complaint: c)),
    );
    if (done == true) await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('My work'),
        actions: const [NotificationBell()],
      ),
      drawer: const AppDrawer(),
      body: FutureBuilder<_WorkerData>(
        future: _future,
        builder: (context, snapshot) => AsyncBody<_WorkerData>(
          snapshot: snapshot,
          onRetry: _refresh,
          builder: (data) {
            final approval = data.status['approvalStatus'] as String;

            if (approval == 'PENDING') {
              return _PendingApproval(status: data.status, onRefresh: _refresh);
            }
            if (approval == 'REJECTED') {
              return _Rejected(note: data.status['rejectionNote'] as String?);
            }

            return RefreshIndicator(
              onRefresh: _refresh,
              child: ListView(
                padding: const EdgeInsets.only(bottom: 30),
                children: [
                  _DutyCard(
                    status: data.status,
                    busy: _togglingDuty,
                    onToggle: _toggleDuty,
                  ),

                  if (data.active.isEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 30),
                      child: EmptyState(
                        icon: (data.status['dutyStatus'] == 'ON')
                            ? Icons.hourglass_empty
                            : Icons.bedtime_outlined,
                        title: (data.status['dutyStatus'] == 'ON')
                            ? 'No task right now'
                            : 'You are off duty',
                        subtitle: (data.status['dutyStatus'] == 'ON')
                            ? 'Your zone officer will send you the next job.'
                            : 'Go on duty to start receiving work.',
                      ),
                    )
                  else ...[
                    const Padding(
                      padding: EdgeInsets.fromLTRB(18, 18, 18, 0),
                      child: Text(
                        'YOUR TASK',
                        style: TextStyle(
                          fontSize: 10.5,
                          letterSpacing: 1.8,
                          fontWeight: FontWeight.w700,
                          color: Palette.inkMuted,
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    for (final c in data.active)
                      ComplaintCard(
                        complaint: c,
                        onTap: () => _open(c),
                        action: _taskAction(c),
                      ),
                  ],

                  if (data.history.isNotEmpty) ...[
                    const Padding(
                      padding: EdgeInsets.fromLTRB(18, 22, 18, 0),
                      child: Text(
                        'FINISHED',
                        style: TextStyle(
                          fontSize: 10.5,
                          letterSpacing: 1.8,
                          fontWeight: FontWeight.w700,
                          color: Palette.inkMuted,
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    for (final c in data.history)
                      ComplaintCard(complaint: c, onTap: () => _open(c)),
                  ],
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget? _taskAction(Complaint c) => switch (c.status) {
        'ALLOTTED_TO_WORKER' || 'REOPENED' => FilledButton.icon(
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(42)),
            onPressed: () => _start(c),
            icon: const Icon(Icons.play_arrow, size: 19),
            label: Text(c.status == 'REOPENED' ? 'Start rework' : 'Start work'),
          ),
        'IN_PROGRESS' => FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: Palette.good,
              minimumSize: const Size.fromHeight(42),
            ),
            onPressed: () => _complete(c),
            icon: const Icon(Icons.camera_alt_outlined, size: 19),
            label: const Text('Mark done + photo'),
          ),
        'WORK_DONE' => Container(
            padding: const EdgeInsets.all(11),
            decoration: BoxDecoration(
              color: Palette.warning.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(9),
            ),
            child: const Row(
              children: [
                Icon(Icons.hourglass_top, size: 17, color: Palette.warning),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Waiting for the resident to confirm',
                    style: TextStyle(fontSize: 12.5, color: Palette.warning),
                  ),
                ),
              ],
            ),
          ),
        _ => null,
      };

  Future<void> _open(Complaint c) async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => ComplaintDetailScreen(complaintId: c.id)),
    );
    await _refresh();
  }
}

class _WorkerData {
  final Map<String, dynamic> status;
  final List<Complaint> active;
  final List<Complaint> history;

  const _WorkerData({
    required this.status,
    required this.active,
    required this.history,
  });
}

/// Duty toggle + the day's numbers. "Free" in the allocation engine means
/// exactly what this card shows: on duty and holding no live task.
class _DutyCard extends StatelessWidget {
  final Map<String, dynamic> status;
  final bool busy;
  final void Function(bool on) onToggle;

  const _DutyCard({required this.status, required this.busy, required this.onToggle});

  @override
  Widget build(BuildContext context) {
    final onDuty = status['dutyStatus'] == 'ON';
    final hasActiveTask = (status['activeTaskCount'] as int? ?? 0) > 0;
    final zone = status['zone'] as Map<String, dynamic>?;
    final zoneColor = colorFromHex(zone?['colorHex'] as String? ?? '#0072B2');

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 14, 12, 4),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: onDuty ? Palette.good.withValues(alpha: 0.5) : Palette.grid,
          width: onDuty ? 1.6 : 1,
        ),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Container(
                width: 11,
                height: 11,
                decoration: BoxDecoration(
                  color: onDuty ? Palette.good : Palette.inkMuted,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      onDuty ? 'On duty' : 'Off duty',
                      style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
                    ),
                    if (zone != null)
                      Text(
                        '${zone['name']} · ${zone['label']}',
                        style: const TextStyle(
                            fontSize: 12.5, color: Palette.inkSecondary),
                      ),
                  ],
                ),
              ),
              if (busy)
                const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2.2),
                )
              else
                // Free is the only state the toggle can change - a worker
                // holding a task cannot go off duty and abandon it, so the
                // switch is locked rather than letting them tap it and hit
                // an error.
                Switch(value: onDuty, onChanged: hasActiveTask ? null : onToggle),
            ],
          ),
          if (hasActiveTask) ...[
            const SizedBox(height: 10),
            const Text(
              'You have a task allotted, so you cannot go off duty right now. '
              'Finish it first.',
              style: TextStyle(fontSize: 12, color: Palette.inkMuted),
            ),
          ],
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.symmetric(vertical: 12),
            decoration: BoxDecoration(
              color: zoneColor.withValues(alpha: 0.07),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                _Metric(
                  value: '${status['tasksCompletedToday'] ?? 0}',
                  label: 'Done today',
                ),
                _Divider(),
                _Metric(
                  value: '${status['tasksCompletedTotal'] ?? 0}',
                  label: 'All time',
                ),
                _Divider(),
                _Metric(
                  value: status['availability'] == 'AVAILABLE' ? 'Free' : 'Busy',
                  label: 'Right now',
                  color: status['availability'] == 'AVAILABLE'
                      ? Palette.good
                      : Palette.warning,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  final String value;
  final String label;
  final Color? color;

  const _Metric({required this.value, required this.label, this.color});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        children: [
          Text(
            value,
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w800,
              color: color ?? Palette.inkPrimary,
            ),
          ),
          const SizedBox(height: 2),
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

class _Divider extends StatelessWidget {
  @override
  Widget build(BuildContext context) =>
      Container(width: 1, height: 28, color: Palette.grid);
}

/// The gate. A worker who has registered but not been verified lands here and
/// can go no further - the server refuses every task endpoint for them too.
class _PendingApproval extends StatelessWidget {
  final Map<String, dynamic> status;
  final Future<void> Function() onRefresh;

  const _PendingApproval({required this.status, required this.onRefresh});

  @override
  Widget build(BuildContext context) {
    final zone = status['zone'] as Map<String, dynamic>?;

    return RefreshIndicator(
      onRefresh: onRefresh,
      child: ListView(
        children: [
          const SizedBox(height: 60),
          const Icon(Icons.hourglass_top, size: 60, color: Palette.warning),
          const SizedBox(height: 22),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 32),
            child: Text(
              'Waiting for verification',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 21, fontWeight: FontWeight.w800),
            ),
          ),
          const SizedBox(height: 10),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 36),
            child: Text(
              'The campus admin is checking your registration'
              '${zone != null ? ' for ${zone['name']}' : ''}. '
              'You can be given work once that is done.',
              textAlign: TextAlign.center,
              style: const TextStyle(
                  fontSize: 14, height: 1.5, color: Palette.inkSecondary),
            ),
          ),
          const SizedBox(height: 28),
          Center(
            child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(190, 46),
              ),
              onPressed: onRefresh,
              icon: const Icon(Icons.refresh),
              label: const Text('Check again'),
            ),
          ),
        ],
      ),
    );
  }
}

class _Rejected extends StatelessWidget {
  final String? note;

  const _Rejected({this.note});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.person_off_outlined, size: 56, color: Palette.critical),
            const SizedBox(height: 20),
            const Text(
              'Registration not approved',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 10),
            Text(
              note ?? 'Contact the campus admin for details.',
              textAlign: TextAlign.center,
              style: const TextStyle(
                  fontSize: 14, height: 1.5, color: Palette.inkSecondary),
            ),
            const SizedBox(height: 26),
            OutlinedButton(
              onPressed: () => context.read<Session>().logout(),
              child: const Text('Sign out'),
            ),
          ],
        ),
      ),
    );
  }
}
