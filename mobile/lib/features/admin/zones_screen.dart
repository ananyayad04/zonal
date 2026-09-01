import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api_client.dart';
import '../../core/palette.dart';
import '../../core/theme.dart';
import '../../shared/ui.dart';
import 'zone_editor_screen.dart';
import 'zone_setup_screen.dart';

/// The admin's zone list. Every zone's boundary, officer and roster in one
/// place.
class ZonesScreen extends StatefulWidget {
  const ZonesScreen({super.key});

  @override
  State<ZonesScreen> createState() => _ZonesScreenState();
}

class _ZonesScreenState extends State<ZonesScreen> {
  late Future<_ZonesData> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<_ZonesData> _load() async {
    final api = context.read<ApiClient>();
    final res = await api.get('/admin/zones');
    return _ZonesData(zones: (res['zones'] as List).cast<Map<String, dynamic>>());
  }

  Future<void> _refresh() async {
    setState(() => _future = _load());
    await _future;
  }

  Future<void> _edit(Map<String, dynamic> zone) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => ZoneEditorScreen(zone: zone)),
    );
    if (changed == true) await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Zones')),
      body: FutureBuilder<_ZonesData>(
        future: _future,
        builder: (context, snapshot) => AsyncBody<_ZonesData>(
          snapshot: snapshot,
          onRetry: _refresh,
          builder: (data) => RefreshIndicator(
            onRefresh: _refresh,
            child: ListView(
              padding: const EdgeInsets.only(bottom: 28),
              children: [
                // The recommended path. Marking one point per zone gives a
                // partition with no gaps and no overlaps, in eight taps.
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(13),
                      onTap: () async {
                        await Navigator.of(context).push(
                          MaterialPageRoute(builder: (_) => const ZoneSetupScreen()),
                        );
                        await _refresh();
                      },
                      child: Container(
                        padding: const EdgeInsets.all(15),
                        decoration: BoxDecoration(
                          color: AppTheme.seed.withValues(alpha: 0.07),
                          borderRadius: BorderRadius.circular(13),
                          border: Border.all(color: AppTheme.seed.withValues(alpha: 0.35)),
                        ),
                        child: const Row(
                          children: [
                            Icon(Icons.pin_drop_outlined,
                                color: AppTheme.seed, size: 24),
                            SizedBox(width: 13),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Mark where each zone is',
                                    style: TextStyle(
                                        fontSize: 15.5, fontWeight: FontWeight.w800),
                                  ),
                                  SizedBox(height: 3),
                                  Text(
                                    'Drop one pin per zone — or stand in it and use your '
                                    'GPS. Boundaries are worked out for you, with no gaps '
                                    'and no overlaps.',
                                    style: TextStyle(
                                        fontSize: 12.5,
                                        height: 1.35,
                                        color: Palette.inkSecondary),
                                  ),
                                ],
                              ),
                            ),
                            Icon(Icons.chevron_right, color: AppTheme.seed),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),

                const Padding(
                  padding: EdgeInsets.fromLTRB(18, 20, 18, 0),
                  child: Text(
                    'THE EIGHT ZONES',
                    style: TextStyle(
                      fontSize: 10.5,
                      letterSpacing: 1.8,
                      fontWeight: FontWeight.w700,
                      color: Palette.inkMuted,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                for (final z in data.zones) _ZoneRow(zone: z, onTap: () => _edit(z)),
                const Padding(
                  padding: EdgeInsets.fromLTRB(18, 16, 18, 0),
                  child: Text(
                    'Re-drawing a boundary never moves complaints that were already '
                    'filed — they keep the zone they were reported in, so past '
                    'reports and analytics stay put.',
                    style: TextStyle(
                        fontSize: 12, height: 1.4, color: Palette.inkMuted),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ZonesData {
  final List<Map<String, dynamic>> zones;

  const _ZonesData({required this.zones});
}

class _ZoneRow extends StatelessWidget {
  final Map<String, dynamic> zone;
  final VoidCallback onTap;

  const _ZoneRow({required this.zone, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final color = colorFromHex(zone['colorHex'] as String? ?? '#0072B2');
    final officer = zone['officer'] as Map<String, dynamic>?;
    final hasBoundary = zone['hasBoundary'] == true;
    final areaM2 = zone['areaM2'] as int? ?? 0;
    final extent = hasBoundary ? _extentOf(zone['polygon'] as List?) : null;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(width: 6, color: color),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 13, 12, 13),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            zone['name'] as String,
                            style: const TextStyle(
                                fontSize: 16, fontWeight: FontWeight.w800),
                          ),
                          const SizedBox(width: 8),
                          if (!hasBoundary)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 7, vertical: 2),
                              decoration: BoxDecoration(
                                color: Palette.serious.withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(5),
                              ),
                              child: const Text(
                                'NO BOUNDARY',
                                style: TextStyle(
                                  fontSize: 9,
                                  letterSpacing: 0.8,
                                  fontWeight: FontWeight.w800,
                                  color: Palette.serious,
                                ),
                              ),
                            ),
                          const Spacer(),
                          const Icon(Icons.chevron_right, color: Palette.inkMuted),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 14,
                        runSpacing: 5,
                        children: [
                          _Fact(
                            icon: Icons.badge_outlined,
                            text: officer?['name'] as String? ?? 'No officer',
                            warn: officer == null,
                          ),
                          _Fact(
                            icon: Icons.cleaning_services_outlined,
                            text: '${zone['workerCount'] ?? 0} workers',
                          ),
                          _Fact(
                            icon: Icons.description_outlined,
                            text: '${zone['complaintCount'] ?? 0} complaints',
                          ),
                          if (hasBoundary)
                            _Fact(
                              icon: Icons.crop_square,
                              text: areaM2 > 10000
                                  ? '${(areaM2 / 10000).toStringAsFixed(1)} ha'
                                  : '$areaM2 m²',
                            ),
                          if (extent != null)
                            _Fact(
                              icon: Icons.explore_outlined,
                              text: extent,
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The lat/lng bounding box a drawn boundary actually covers, so the admin
/// can see where a zone sits on the map without opening the editor - useful
/// since zones are drawn freehand rather than assigned from a fixed list.
String? _extentOf(List? polygon) {
  if (polygon == null || polygon.length < 3) return null;
  var minLat = double.infinity, maxLat = -double.infinity;
  var minLng = double.infinity, maxLng = -double.infinity;
  for (final p in polygon) {
    final lat = (p[0] as num).toDouble();
    final lng = (p[1] as num).toDouble();
    if (lat < minLat) minLat = lat;
    if (lat > maxLat) maxLat = lat;
    if (lng < minLng) minLng = lng;
    if (lng > maxLng) maxLng = lng;
  }
  return '${minLat.toStringAsFixed(4)}–${maxLat.toStringAsFixed(4)}°N, '
      '${minLng.toStringAsFixed(4)}–${maxLng.toStringAsFixed(4)}°E';
}

class _Fact extends StatelessWidget {
  final IconData icon;
  final String text;
  final bool warn;

  const _Fact({required this.icon, required this.text, this.warn = false});

  @override
  Widget build(BuildContext context) {
    final color = warn ? Palette.serious : Palette.inkMuted;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 4),
        Text(
          text,
          style: TextStyle(
            fontSize: 12,
            color: color,
            fontWeight: warn ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
      ],
    );
  }
}
