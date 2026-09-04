import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api_client.dart';
import '../../core/palette.dart';
import '../../shared/ui.dart';
import 'create_warden_screen.dart';

class _Hostel {
  final String id;
  final String name;
  final String category;
  final Map<String, dynamic>? warden;

  const _Hostel({required this.id, required this.name, required this.category, this.warden});

  factory _Hostel.fromJson(Map<String, dynamic> j) => _Hostel(
        id: j['id'] as String,
        name: j['name'] as String,
        category: j['category'] as String,
        warden: j['warden'] as Map<String, dynamic>?,
      );
}

/// Admin-only: every hostel-category landmark and who runs it. Mirrors
/// ZonesScreen's list, minus the polygon editor - a hostel needs no boundary,
/// only a warden.
class HostelsScreen extends StatefulWidget {
  const HostelsScreen({super.key});

  @override
  State<HostelsScreen> createState() => _HostelsScreenState();
}

class _HostelsScreenState extends State<HostelsScreen> {
  late Future<List<_Hostel>> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<List<_Hostel>> _load() async {
    final res = await context.read<ApiClient>().get('/admin/hostels');
    return (res['hostels'] as List).map((h) => _Hostel.fromJson(h as Map<String, dynamic>)).toList();
  }

  Future<void> _refresh() async {
    setState(() => _future = _load());
    await _future;
  }

  Future<void> _clearWarden(_Hostel h) async {
    try {
      final res = await context.read<ApiClient>().put('/admin/hostels/${h.id}', {'wardenId': null});
      if (mounted) {
        showSnack(context, res['message'] as String? ?? 'Cleared');
        await _refresh();
      }
    } on ApiException catch (e) {
      if (mounted) showSnack(context, e.message, error: true);
    }
  }

  Future<void> _addWarden() async {
    final created = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const CreateWardenScreen()),
    );
    if (created == true) await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Hostels & wardens'),
        actions: [
          IconButton(icon: const Icon(Icons.person_add_alt), onPressed: _addWarden),
        ],
      ),
      body: FutureBuilder<List<_Hostel>>(
        future: _future,
        builder: (context, snapshot) => AsyncBody<List<_Hostel>>(
          snapshot: snapshot,
          onRetry: _refresh,
          builder: (hostels) {
            return RefreshIndicator(
              onRefresh: _refresh,
              child: ListView.builder(
                padding: const EdgeInsets.symmetric(vertical: 8),
                itemCount: hostels.length,
                itemBuilder: (_, i) {
                  final h = hostels[i];
                  final warden = h.warden;
                  return Card(
                    margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                    child: ListTile(
                      leading: Icon(
                        Icons.apartment,
                        color: warden != null ? Palette.good : Palette.warning,
                      ),
                      title: Text(h.name, style: const TextStyle(fontWeight: FontWeight.w700)),
                      subtitle: Text(
                        warden != null
                            ? 'Run by ${warden['name']}'
                            : 'No warden assigned',
                        style: TextStyle(
                          fontSize: 12.5,
                          color: warden != null ? Palette.inkSecondary : Palette.warning,
                        ),
                      ),
                      trailing: warden != null
                          ? TextButton(
                              onPressed: () => _clearWarden(h),
                              child: const Text('Clear'),
                            )
                          : TextButton(
                              onPressed: _addWarden,
                              child: const Text('Assign'),
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
