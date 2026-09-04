import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api_client.dart';
import '../../core/palette.dart';
import '../../shared/ui.dart';

const _actionLabels = <String, (String, IconData)>{
  'WORKER_VERIFIED': ('verified', Icons.how_to_reg),
  'WORKER_REJECTED': ('rejected', Icons.person_off_outlined),
  'OFFICER_CREATED': ('created', Icons.shield_outlined),
  'OFFICER_VERIFIED': ('verified', Icons.how_to_reg),
  'OFFICER_REJECTED': ('rejected', Icons.person_off_outlined),
  'OFFICER_REASSIGNED': ('zone reassigned', Icons.swap_horiz),
  'SUPERVISOR_CREATED': ('created', Icons.supervisor_account_outlined),
  'WARDEN_CREATED': ('created', Icons.apartment_outlined),
  'WARDEN_REASSIGNED': ('hostel reassigned', Icons.swap_horiz),
};

/// Who Admin verified, created, or appointed to run a zone or hostel, and
/// when - the accountability trail a formal admin role implies. Deliberately
/// narrow: complaint activity has its own timeline on each complaint already,
/// this is personnel decisions only.
class AuditLogScreen extends StatefulWidget {
  const AuditLogScreen({super.key});

  @override
  State<AuditLogScreen> createState() => _AuditLogScreenState();
}

class _AuditLogScreenState extends State<AuditLogScreen> {
  late Future<List<Map<String, dynamic>>> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<List<Map<String, dynamic>>> _load() async {
    final res = await context.read<ApiClient>().get('/admin/audit-log');
    return (res['entries'] as List).cast<Map<String, dynamic>>();
  }

  Future<void> _refresh() async {
    setState(() => _future = _load());
    await _future;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Activity log')),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: _future,
        builder: (context, snapshot) => AsyncBody<List<Map<String, dynamic>>>(
          snapshot: snapshot,
          onRetry: _refresh,
          builder: (entries) {
            if (entries.isEmpty) {
              return const EmptyState(
                icon: Icons.history,
                title: 'Nothing yet',
                subtitle: 'Every account you create or verify, and every zone or '
                    'hostel you appoint someone to, is recorded here.',
              );
            }

            return RefreshIndicator(
              onRefresh: _refresh,
              child: ListView.separated(
                itemCount: entries.length,
                separatorBuilder: (_, __) => const Divider(height: 1, indent: 60),
                itemBuilder: (_, i) => _EntryRow(entry: entries[i]),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _EntryRow extends StatelessWidget {
  final Map<String, dynamic> entry;

  const _EntryRow({required this.entry});

  @override
  Widget build(BuildContext context) {
    final action = entry['action'] as String? ?? '';
    final (verb, icon) = _actionLabels[action] ?? (action.toLowerCase(), Icons.circle_outlined);
    final actorName = entry['actorName'] as String? ?? 'Someone';
    final targetLabel = entry['targetLabel'] as String? ?? '';
    final note = entry['note'] as String?;
    final at = DateTime.tryParse(entry['createdAt'] as String? ?? '')?.toLocal();

    return ListTile(
      leading: Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          color: Palette.inkPrimary.withValues(alpha: 0.06),
          shape: BoxShape.circle,
        ),
        child: Icon(icon, size: 18, color: Palette.inkSecondary),
      ),
      title: Text(
        '$actorName $verb $targetLabel',
        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
      ),
      subtitle: note != null
          ? Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(note, style: const TextStyle(fontSize: 12.5, color: Palette.inkSecondary)),
            )
          : null,
      trailing: Text(
        at != null ? timeAgo(at) : '',
        style: const TextStyle(fontSize: 11, color: Palette.inkMuted),
      ),
      isThreeLine: note != null,
    );
  }
}
