import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api_client.dart';
import '../../core/palette.dart';
import '../../core/theme.dart';
import '../../shared/ui.dart';
import 'reset_credentials_dialog.dart';

/// Who runs what, on one screen: every zone and its officer, every hostel
/// and its warden, and every worker supervisor. The equivalent information
/// is already spread across four different screens (zones, verify-people,
/// hostels, and nowhere at all for supervisors) - this is the single "who is
/// in charge of what" picture that shape of organisation implies.
class RosterScreen extends StatefulWidget {
  const RosterScreen({super.key});

  @override
  State<RosterScreen> createState() => _RosterScreenState();
}

class _RosterScreenState extends State<RosterScreen> {
  late Future<_RosterData> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<_RosterData> _load() async {
    final api = context.read<ApiClient>();
    final results = await Future.wait([
      api.get('/admin/dashboard'),
      api.get('/admin/hostels'),
      api.get('/admin/supervisors'),
    ]);

    return _RosterData(
      zones: (results[0]['zones'] as List).cast<Map<String, dynamic>>(),
      hostels: (results[1]['hostels'] as List).cast<Map<String, dynamic>>(),
      supervisors: (results[2]['supervisors'] as List).cast<Map<String, dynamic>>(),
    );
  }

  Future<void> _refresh() async {
    setState(() => _future = _load());
    await _future;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Roster')),
      body: FutureBuilder<_RosterData>(
        future: _future,
        builder: (context, snapshot) => AsyncBody<_RosterData>(
          snapshot: snapshot,
          onRetry: _refresh,
          builder: (data) {
            return RefreshIndicator(
              onRefresh: _refresh,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 30),
                children: [
                  const _SectionLabel('WORKER SUPERVISORS', 'Campus-wide, over every zone'),
                  if (data.supervisors.isEmpty)
                    const _EmptyRow('None created yet')
                  else
                    for (final s in data.supervisors)
                      _PersonRow(
                        icon: Icons.supervisor_account_outlined,
                        name: s['name'] as String,
                        subtitle: s['email'] as String? ?? '',
                        userId: s['id'] as String,
                        onChanged: _refresh,
                      ),

                  const SizedBox(height: 24),
                  const _SectionLabel('ZONE OFFICERS', 'One per zone, appointed by the admin'),
                  for (final z in data.zones)
                    _RoleSlotRow(
                      dotColor: colorFromHex(z['colorHex'] as String? ?? '#4F86C6'),
                      title: '${z['name']} · ${z['label']}',
                      person: z['officer'] as Map<String, dynamic>?,
                      detail: '${z['workersTotal'] ?? 0} worker(s) · '
                          '${z['openComplaints'] ?? 0} open complaint(s)',
                      onChanged: _refresh,
                    ),

                  const SizedBox(height: 24),
                  const _SectionLabel('HOSTELS & WARDENS', 'One per hostel'),
                  for (final h in data.hostels)
                    _RoleSlotRow(
                      dotColor: const Color(0xFF009E73),
                      title: h['name'] as String,
                      person: h['warden'] as Map<String, dynamic>?,
                      onChanged: _refresh,
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

class _RosterData {
  final List<Map<String, dynamic>> zones;
  final List<Map<String, dynamic>> hostels;
  final List<Map<String, dynamic>> supervisors;

  const _RosterData({required this.zones, required this.hostels, required this.supervisors});
}

class _SectionLabel extends StatelessWidget {
  final String label;
  final String caption;

  const _SectionLabel(this.label, this.caption);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              fontSize: 10.5,
              letterSpacing: 1.8,
              fontWeight: FontWeight.w700,
              color: Palette.inkMuted,
            ),
          ),
          const SizedBox(height: 2),
          Text(caption, style: const TextStyle(fontSize: 12.5, color: Palette.inkSecondary)),
        ],
      ),
    );
  }
}

/// A person filling one campus-wide role, no vacancy state - supervisors
/// exist or they don't.
class _PersonRow extends StatelessWidget {
  final IconData icon;
  final String name;
  final String subtitle;
  final String userId;
  final VoidCallback onChanged;

  const _PersonRow({
    required this.icon,
    required this.name,
    required this.subtitle,
    required this.userId,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: Palette.grid),
      ),
      child: Row(
        children: [
          Icon(icon, size: 19, color: AppTheme.seed),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
                Text(subtitle, style: const TextStyle(fontSize: 12, color: Palette.inkSecondary)),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Reset login',
            icon: const Icon(Icons.key_outlined, size: 19, color: Palette.inkMuted),
            onPressed: () async {
              final changed =
                  await showResetCredentialsDialog(context, userId: userId, name: name);
              if (changed) onChanged();
            },
          ),
        ],
      ),
    );
  }
}

/// One appointment slot - a zone or a hostel - and who (if anyone) fills it.
class _RoleSlotRow extends StatelessWidget {
  final Color dotColor;
  final String title;
  final Map<String, dynamic>? person;
  final String? detail;
  final VoidCallback onChanged;

  const _RoleSlotRow({
    required this.dotColor,
    required this.title,
    required this.person,
    required this.onChanged,
    this.detail,
  });

  @override
  Widget build(BuildContext context) {
    final vacant = person == null;
    final personName = person?['name'] as String?;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: vacant ? Palette.warning.withValues(alpha: 0.4) : Palette.grid),
      ),
      child: Row(
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(color: dotColor, borderRadius: BorderRadius.circular(3)),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700)),
                if (detail != null)
                  Text(detail!, style: const TextStyle(fontSize: 11.5, color: Palette.inkMuted)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(
            personName ?? 'Vacant',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: vacant ? Palette.warning : Palette.inkPrimary,
            ),
          ),
          if (!vacant)
            IconButton(
              tooltip: 'Reset login',
              icon: const Icon(Icons.key_outlined, size: 19, color: Palette.inkMuted),
              onPressed: () async {
                final changed = await showResetCredentialsDialog(
                  context,
                  userId: person!['id'] as String,
                  name: personName!,
                );
                if (changed) onChanged();
              },
            ),
        ],
      ),
    );
  }
}

class _EmptyRow extends StatelessWidget {
  final String text;

  const _EmptyRow(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(text, style: const TextStyle(fontSize: 13, color: Palette.inkMuted)),
    );
  }
}
