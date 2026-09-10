import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api_client.dart';
import '../../core/palette.dart';
import '../../shared/ui.dart';
import 'add_landmark_screen.dart';

const _categoryLabels = <String, String>{
  'DEPARTMENT': 'Departments & academic',
  'BOYS_HOSTEL': 'Boys hostels',
  'GIRLS_HOSTEL': 'Girls hostels',
  'FACILITY': 'Facilities',
  'RESIDENCE': 'Residences',
};

/// Admin-only: every named place the complaint form pickers offer, grouped
/// by category. A fresh production install starts with none of these - this
/// is where they get added.
class LandmarksScreen extends StatefulWidget {
  const LandmarksScreen({super.key});

  @override
  State<LandmarksScreen> createState() => _LandmarksScreenState();
}

class _LandmarksScreenState extends State<LandmarksScreen> {
  late Future<List<Map<String, dynamic>>> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<List<Map<String, dynamic>>> _load() async {
    final res = await context.read<ApiClient>().get('/landmarks');
    return (res['landmarks'] as List).cast<Map<String, dynamic>>();
  }

  Future<void> _refresh() async {
    setState(() => _future = _load());
    await _future;
  }

  Future<void> _add() async {
    final created = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const AddLandmarkScreen()),
    );
    if (created == true) await _refresh();
  }

  Future<void> _remove(Map<String, dynamic> landmark) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Remove ${landmark['name']}?'),
        content: const Text(
          'It disappears from every complaint form picker. Complaints '
          'already filed against it keep their record either way.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Palette.critical),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    try {
      final res = await context
          .read<ApiClient>()
          .put('/landmarks/${landmark['id']}', {'isActive': false});
      if (mounted) {
        showSnack(context, res['message'] as String? ?? 'Removed');
        await _refresh();
      }
    } on ApiException catch (e) {
      if (mounted) showSnack(context, e.message, error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Landmarks'),
        actions: [
          IconButton(tooltip: 'New landmark', icon: const Icon(Icons.add_location_alt_outlined), onPressed: _add),
        ],
      ),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: _future,
        builder: (context, snapshot) => AsyncBody<List<Map<String, dynamic>>>(
          snapshot: snapshot,
          onRetry: _refresh,
          builder: (landmarks) {
            if (landmarks.isEmpty) {
              return const EmptyState(
                icon: Icons.add_location_alt_outlined,
                title: 'No landmarks yet',
                subtitle: 'Nobody can file a complaint until at least one exists - '
                    'tap the icon above to add the first one.',
              );
            }

            final byCategory = <String, List<Map<String, dynamic>>>{};
            for (final l in landmarks) {
              (byCategory[l['category'] as String] ??= []).add(l);
            }

            return RefreshIndicator(
              onRefresh: _refresh,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 30),
                children: [
                  for (final category in _categoryLabels.keys)
                    if (byCategory[category] != null) ...[
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8, top: 8),
                        child: Text(
                          _categoryLabels[category]!.toUpperCase(),
                          style: const TextStyle(
                            fontSize: 10.5,
                            letterSpacing: 1.8,
                            fontWeight: FontWeight.w700,
                            color: Palette.inkMuted,
                          ),
                        ),
                      ),
                      for (final l in byCategory[category]!)
                        Container(
                          margin: const EdgeInsets.only(bottom: 8),
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(11),
                            border: Border.all(color: Palette.grid),
                          ),
                          child: ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text(l['name'] as String, style: const TextStyle(fontWeight: FontWeight.w700)),
                            subtitle: l['zoneCode'] != null
                                ? Text('Zone ${l['zoneCode']}', style: const TextStyle(fontSize: 12))
                                : null,
                            trailing: IconButton(
                              tooltip: 'Remove',
                              icon: const Icon(Icons.close, size: 19, color: Palette.inkMuted),
                              onPressed: () => _remove(l),
                            ),
                          ),
                        ),
                    ],
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}
