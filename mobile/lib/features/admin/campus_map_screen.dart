import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../../core/api_client.dart';
import '../../core/models.dart';
import '../../core/palette.dart';
import '../../core/theme.dart';
import '../../shared/ui.dart';

/// The campus, on a real map.
///
/// OpenStreetMap rather than Google Maps: no API key, no billing card, and the
/// zone boundaries are our own data anyway.
///
/// Zone fills are the one place the categorical zone hues are used. Three of
/// them fall below 3:1 contrast on a pale basemap, so every zone is also
/// labelled - the fill never identifies a zone on its own.
class CampusMapScreen extends StatefulWidget {
  const CampusMapScreen({super.key});

  @override
  State<CampusMapScreen> createState() => _CampusMapScreenState();
}

class _CampusMapScreenState extends State<CampusMapScreen> {
  late Future<_MapData> _future;
  bool _showComplaints = true;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<_MapData> _load() async {
    final api = context.read<ApiClient>();
    final results = await Future.wait([
      api.get('/zones'),
      api.get('/analytics/heatmap', query: {'days': 90}),
    ]);

    return _MapData(
      zones: (results[0]['zones'] as List)
          .map((z) => Zone.fromJson(z as Map<String, dynamic>))
          .toList(),
      points: (results[1]['points'] as List).cast<Map<String, dynamic>>(),
    );
  }

  Future<void> _refresh() async {
    setState(() => _future = _load());
    await _future;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Campus map'),
        actions: [
          IconButton(
            tooltip: _showComplaints ? 'Hide complaints' : 'Show complaints',
            icon: Icon(_showComplaints ? Icons.location_on : Icons.location_off),
            onPressed: () => setState(() => _showComplaints = !_showComplaints),
          ),
        ],
      ),
      body: FutureBuilder<_MapData>(
        future: _future,
        builder: (context, snapshot) => AsyncBody<_MapData>(
          snapshot: snapshot,
          onRetry: _refresh,
          builder: (data) {
            if (data.zones.isEmpty) {
              return const EmptyState(
                icon: Icons.map_outlined,
                title: 'No zones configured',
                subtitle: 'Run the database seed to create the eight campus zones.',
              );
            }

            final centre = _centreOf(data.zones);

            return Column(
              children: [
                Expanded(
                  child: FlutterMap(
                    options: MapOptions(
                      initialCenter: centre,
                      initialZoom: 15.5,
                      interactionOptions: const InteractionOptions(
                        flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
                      ),
                    ),
                    children: [
                      TileLayer(
                        urlTemplate:
                            'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}',
                        userAgentPackageName: 'edu.campus.zonal',
                        maxZoom: 19,
                      ),

                      PolygonLayer(
                        polygons: [
                          for (final z in data.zones)
                            if (z.polygon.isNotEmpty)
                              Polygon(
                                points: z.polygon
                                    .map((p) => LatLng(p[0], p[1]))
                                    .toList(),
                                color: colorFromHex(z.colorHex)
                                    .withValues(alpha: 0.22),
                                borderColor: colorFromHex(z.colorHex),
                                borderStrokeWidth: 2,
                              ),
                        ],
                      ),

                      // Zone names. Required, not decorative - see the note at
                      // the top of this file.
                      MarkerLayer(
                        markers: [
                          for (final z in data.zones)
                            if (z.centroidLat != null && z.centroidLng != null)
                              Marker(
                                point: LatLng(z.centroidLat!, z.centroidLng!),
                                width: 108,
                                height: 34,
                                child: _ZoneLabel(zone: z),
                              ),
                        ],
                      ),

                      if (_showComplaints)
                        MarkerLayer(
                          markers: [
                            for (final p in data.points)
                              Marker(
                                point: LatLng(
                                  (p['lat'] as num).toDouble(),
                                  (p['lng'] as num).toDouble(),
                                ),
                                width: 14,
                                height: 14,
                                child: Container(
                                  decoration: BoxDecoration(
                                    color: Palette.forComplaintStatus(
                                      p['status'] as String? ?? '',
                                    ),
                                    shape: BoxShape.circle,
                                    // 2px surface ring so overlapping points
                                    // stay countable.
                                    border: Border.all(color: Colors.white, width: 2),
                                  ),
                                ),
                              ),
                          ],
                        ),
                    ],
                  ),
                ),
                _Legend(zones: data.zones, complaintCount: data.points.length),
              ],
            );
          },
        ),
      ),
    );
  }

  static LatLng _centreOf(List<Zone> zones) {
    final withCentroid =
        zones.where((z) => z.centroidLat != null && z.centroidLng != null).toList();
    if (withCentroid.isEmpty) return const LatLng(26.7314, 83.4324); // MMMUT Gorakhpur

    final lat = withCentroid.map((z) => z.centroidLat!).reduce((a, b) => a + b) /
        withCentroid.length;
    final lng = withCentroid.map((z) => z.centroidLng!).reduce((a, b) => a + b) /
        withCentroid.length;
    return LatLng(lat, lng);
  }
}

class _MapData {
  final List<Zone> zones;
  final List<Map<String, dynamic>> points;

  const _MapData({required this.zones, required this.points});
}

class _ZoneLabel extends StatelessWidget {
  final Zone zone;

  const _ZoneLabel({required this.zone});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.9),
          borderRadius: BorderRadius.circular(5),
          border: Border.all(color: colorFromHex(zone.colorHex), width: 1.5),
        ),
        child: Text(
          zone.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontSize: 10.5,
            fontWeight: FontWeight.w800,
            color: Palette.inkPrimary,
          ),
        ),
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  final List<Zone> zones;
  final int complaintCount;

  const _Legend({required this.zones, required this.complaintCount});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: Palette.grid)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$complaintCount complaints in the last 90 days',
            style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 9),
          Wrap(
            spacing: 12,
            runSpacing: 6,
            children: [
              for (final (status, label) in const [
                ('CLOSED', 'Closed'),
                ('IN_PROGRESS', 'In progress'),
                ('WORK_DONE', 'Awaiting confirmation'),
                ('ESCALATED', 'Escalated'),
              ])
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: Palette.forComplaintStatus(status),
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 1.5),
                      ),
                    ),
                    const SizedBox(width: 5),
                    Text(
                      label,
                      style: const TextStyle(fontSize: 11, color: Palette.inkSecondary),
                    ),
                  ],
                ),
            ],
          ),
        ],
      ),
    );
  }
}

