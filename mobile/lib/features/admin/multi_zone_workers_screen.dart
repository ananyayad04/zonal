import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api_client.dart';
import '../../core/palette.dart';
import '../../core/theme.dart';
import '../../shared/ui.dart';

/// Every worker currently on loan to a zone that is not their own — whether
/// lent through an officer's help request or sent there directly by the
/// admin. One place to see the campus's cross-zone borrowing at a glance.
class MultiZoneWorkersScreen extends StatefulWidget {
  const MultiZoneWorkersScreen({super.key});

  @override
  State<MultiZoneWorkersScreen> createState() => _MultiZoneWorkersScreenState();
}

class _MultiZoneWorkersScreenState extends State<MultiZoneWorkersScreen> {
  late Future<List<Map<String, dynamic>>> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<List<Map<String, dynamic>>> _load() async {
    final res = await context.read<ApiClient>().get('/admin/multi-zone-workers');
    return (res['workers'] as List).cast<Map<String, dynamic>>();
  }

  Future<void> _refresh() async {
    setState(() => _future = _load());
    await _future;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Multi-zone workers')),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: _future,
        builder: (context, snapshot) => AsyncBody<List<Map<String, dynamic>>>(
          snapshot: snapshot,
          onRetry: _refresh,
          builder: (workers) {
            if (workers.isEmpty) {
              return const EmptyState(
                icon: Icons.swap_horiz,
                title: 'No one is on loan right now',
                subtitle: 'Workers currently helping out a zone other than their '
                    'own — lent by an officer or sent directly by you — show up '
                    'here.',
              );
            }

            return RefreshIndicator(
              onRefresh: _refresh,
              child: ListView.builder(
                padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
                itemCount: workers.length,
                itemBuilder: (_, i) {
                  final w = workers[i];
                  final home = w['homeZone'] as Map<String, dynamic>?;
                  final working = w['workingZone'] as Map<String, dynamic>;
                  final workerInfo = w['worker'] as Map<String, dynamic>?;

                  return Card(
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            workerInfo?['name'] as String? ?? 'Unknown worker',
                            style: const TextStyle(
                                fontSize: 15.5, fontWeight: FontWeight.w800),
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              _ZonePill(
                                label: home?['name'] as String? ?? 'Unknown',
                                caption: 'home zone',
                              ),
                              const Padding(
                                padding: EdgeInsets.symmetric(horizontal: 8),
                                child: Icon(Icons.arrow_forward,
                                    size: 16, color: Palette.inkMuted),
                              ),
                              _ZonePill(
                                label: working['name'] as String,
                                caption: 'working in',
                                emphasis: true,
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          Text(
                            '${w['category']} · ${w['complaintRef']}',
                            style: const TextStyle(
                                fontSize: 12.5, color: Palette.inkSecondary),
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

class _ZonePill extends StatelessWidget {
  final String label;
  final String caption;
  final bool emphasis;

  const _ZonePill({required this.label, required this.caption, this.emphasis = false});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
          decoration: BoxDecoration(
            color: (emphasis ? AppTheme.seed : Palette.inkPrimary).withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
              color: emphasis ? AppTheme.seed : Palette.inkPrimary,
            ),
          ),
        ),
        const SizedBox(height: 2),
        Text(
          caption,
          style: const TextStyle(fontSize: 10, color: Palette.inkMuted),
        ),
      ],
    );
  }
}
