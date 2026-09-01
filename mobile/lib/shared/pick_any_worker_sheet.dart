import 'package:flutter/material.dart';

import '../core/palette.dart';

/// One flattened `{userId, name, zoneName, tasksCompletedToday, zoneOpenComplaints?}`
/// entry per free worker, built by flattening the zone-grouped response of
/// `GET /admin/free-workers`.
typedef WorkerOption = Map<String, dynamic>;

List<WorkerOption> flattenFreeWorkers(List<Map<String, dynamic>> zones) {
  final options = <WorkerOption>[];
  for (final z in zones) {
    final zone = z['zone'] as Map<String, dynamic>;
    for (final w in (z['workers'] as List).cast<Map<String, dynamic>>()) {
      options.add({
        ...w,
        'zoneName': zone['name'],
        'zoneOpenComplaints': z['openComplaintCount'],
      });
    }
  }
  return options;
}

/// A bottom sheet listing every free worker on campus, with no zone
/// restriction - used wherever the admin bypasses the officer entirely
/// (escalations, and complaints nobody has allotted yet).
class PickAnyWorkerSheet extends StatelessWidget {
  final List<WorkerOption> options;

  const PickAnyWorkerSheet({super.key, required this.options});

  static Future<String?> show(BuildContext context, List<WorkerOption> options) {
    return showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => PickAnyWorkerSheet(options: options),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Palette.grid,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 20),
            const Text(
              'Free workers, campus-wide',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 4),
            const Text(
              'Zone rules do not apply here — you can send anyone.',
              style: TextStyle(fontSize: 13, color: Palette.inkSecondary),
            ),
            const SizedBox(height: 14),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: options.length,
                itemBuilder: (_, i) {
                  final w = options[i];
                  final openInZone = w['zoneOpenComplaints'] as int?;
                  return ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: CircleAvatar(
                      backgroundColor: Palette.grid,
                      child: Text(
                        (w['name'] as String).isEmpty
                            ? '?'
                            : (w['name'] as String)[0].toUpperCase(),
                        style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          color: Palette.inkSecondary,
                        ),
                      ),
                    ),
                    title: Text(
                      w['name'] as String,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    subtitle: Text(
                      '${w['zoneName']} · ${w['tasksCompletedToday'] ?? 0} done today'
                      '${openInZone != null ? ' · $openInZone open there' : ''}',
                    ),
                    trailing: const Icon(Icons.arrow_forward_ios, size: 15),
                    onTap: () => Navigator.of(context).pop(w['userId'] as String),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
