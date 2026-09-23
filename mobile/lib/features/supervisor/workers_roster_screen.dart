import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api_client.dart';
import '../../core/palette.dart';
import '../../shared/ui.dart';
import 'create_worker_screen.dart';

/// Supervisor/Admin: every active worker campus-wide, zone-filterable, with
/// duty control. A worker created directly here (see CreateWorkerScreen) may
/// have no phone at all, so this is also the only place their duty status
/// can ever change - they cannot flip it themselves the way an app-using
/// worker does from their own home screen.
class WorkersRosterScreen extends StatefulWidget {
  const WorkersRosterScreen({super.key});

  @override
  State<WorkersRosterScreen> createState() => _WorkersRosterScreenState();
}

class _WorkersRosterScreenState extends State<WorkersRosterScreen> {
  late Future<List<Map<String, dynamic>>> _future;
  int? _zoneFilter;

  /// Toggled in this session - a duty change is applied optimistically to the
  /// list on success rather than waiting for a full refetch.
  final Set<String> _busyUserIds = {};

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<List<Map<String, dynamic>>> _load() async {
    final res = await context.read<ApiClient>().get('/admin/workers/roster');
    return (res['workers'] as List).cast<Map<String, dynamic>>();
  }

  Future<void> _refresh() async {
    setState(() => _future = _load());
    await _future;
  }

  Future<void> _create() async {
    final created = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const CreateWorkerScreen()),
    );
    if (created == true) await _refresh();
  }

  Future<void> _toggleDuty(Map<String, dynamic> worker) async {
    final userId = worker['userId'] as String;
    final next = worker['dutyStatus'] == 'ON' ? 'OFF' : 'ON';

    setState(() => _busyUserIds.add(userId));
    try {
      final res = await context.read<ApiClient>().put('/admin/workers/$userId/duty', {'dutyStatus': next});
      if (mounted) {
        showSnack(context, res['message'] as String? ?? 'Duty updated');
        await _refresh();
      }
    } on ApiException catch (e) {
      if (mounted) showSnack(context, e.message, error: true);
    } finally {
      if (mounted) setState(() => _busyUserIds.remove(userId));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Workers'),
        actions: [
          IconButton(tooltip: 'New worker', icon: const Icon(Icons.person_add_alt), onPressed: _create),
        ],
      ),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: _future,
        builder: (context, snapshot) => AsyncBody<List<Map<String, dynamic>>>(
          snapshot: snapshot,
          onRetry: _refresh,
          builder: (all) {
            if (all.isEmpty) {
              return const EmptyState(
                icon: Icons.engineering_outlined,
                title: 'No workers yet',
                subtitle: 'Tap + above to create one directly - no approval needed.',
              );
            }

            final zoneCounts = <int, int>{};
            for (final w in all) {
              final code = (w['zone'] as Map<String, dynamic>?)?['code'] as int?;
              if (code != null) zoneCounts[code] = (zoneCounts[code] ?? 0) + 1;
            }
            final zoneCodes = zoneCounts.keys.toList()..sort();

            final workers = _zoneFilter == null
                ? all
                : all.where((w) => (w['zone'] as Map<String, dynamic>?)?['code'] == _zoneFilter).toList();

            return RefreshIndicator(
              onRefresh: _refresh,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 20),
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      ChoiceChip(
                        label: Text('All (${all.length})'),
                        selected: _zoneFilter == null,
                        onSelected: (_) => setState(() => _zoneFilter = null),
                      ),
                      for (final code in zoneCodes)
                        ChoiceChip(
                          label: Text('Zone $code (${zoneCounts[code]})'),
                          selected: _zoneFilter == code,
                          onSelected: (_) => setState(() => _zoneFilter = code),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  for (final w in workers) _WorkerRow(
                    worker: w,
                    busy: _busyUserIds.contains(w['userId']),
                    onToggleDuty: () => _toggleDuty(w),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _WorkerRow extends StatelessWidget {
  final Map<String, dynamic> worker;
  final bool busy;
  final VoidCallback onToggleDuty;

  const _WorkerRow({required this.worker, required this.busy, required this.onToggleDuty});

  @override
  Widget build(BuildContext context) {
    final zone = worker['zone'] as Map<String, dynamic>?;
    final onDuty = worker['dutyStatus'] == 'ON';
    final available = worker['availability'] == 'AVAILABLE';

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: Palette.grid),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(worker['name'] as String, style: const TextStyle(fontWeight: FontWeight.w700)),
                const SizedBox(height: 3),
                Row(
                  children: [
                    if (zone != null)
                      Text('${zone['name']} · ${zone['label']}',
                          style: const TextStyle(fontSize: 11.5, color: Palette.inkSecondary)),
                    const SizedBox(width: 8),
                    if (onDuty)
                      _Pill(
                        text: available ? 'Free' : 'Busy',
                        color: available ? Palette.good : Palette.warning,
                      ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  '${worker['tasksCompletedToday'] ?? 0} done today · ${worker['tasksCompletedTotal'] ?? 0} total',
                  style: const TextStyle(fontSize: 11, color: Palette.inkMuted),
                ),
              ],
            ),
          ),
          Column(
            children: [
              Text(onDuty ? 'On duty' : 'Off duty',
                  style: const TextStyle(fontSize: 10.5, color: Palette.inkMuted)),
              busy
                  ? const SizedBox(
                      width: 40,
                      height: 24,
                      child: Center(
                        child: SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                    )
                  : Switch(value: onDuty, onChanged: (_) => onToggleDuty()),
            ],
          ),
        ],
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  final String text;
  final Color color;

  const _Pill({required this.text, required this.color});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(text, style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, color: color)),
      );
}
