import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../../core/api_client.dart';
import '../../core/location_service.dart';
import '../../core/palette.dart';
import '../../core/theme.dart';
import '../../shared/ui.dart';

/// Set up the campus by marking one point inside each zone.
///
/// Boundaries are computed from those points: every location belongs to
/// whichever mark is nearest. That gives a partition with no gaps and no
/// overlaps, which is the thing free-hand drawing on a phone cannot promise -
/// and it takes eight taps instead of forty.
///
/// The admin can also stand in a zone and use their own GPS, which is the
/// fastest way to map a campus you are actually walking around.
class ZoneSetupScreen extends StatefulWidget {
  const ZoneSetupScreen({super.key});

  @override
  State<ZoneSetupScreen> createState() => _ZoneSetupScreenState();
}

class _ZoneSetupScreenState extends State<ZoneSetupScreen> {
  final _mapController = MapController();

  List<Map<String, dynamic>> _zones = const [];
  final Map<int, LatLng> _anchors = {};

  /// How far each zone reaches from its centre. Set by dropping a second pin
  /// on the zone's edge; the radius is the distance between the two.
  ///
  /// This is a claim on territory, not a literal circle. A zone with a bigger
  /// radius pushes its border further out against its neighbours â€” which is
  /// how a large academic block and a small hostel end up correctly sized
  /// without reintroducing gaps between them.
  final Map<int, double> _radii = {};

  final Set<int> _moved = {};

  /// When true, the next map tap sets the selected zone's edge instead of its
  /// centre.
  bool _settingEdge = false;

  int _selected = 1;
  bool _loading = true;
  bool _busy = false;
  String? _error;
  int? _coveragePct;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _mapController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final res = await context.read<ApiClient>().get('/admin/zones');
      final zones = (res['zones'] as List).cast<Map<String, dynamic>>();

      if (!mounted) return;
      setState(() {
        _zones = zones;
        _anchors.clear();
        _radii.clear();
        for (final z in zones) {
          final code = z['code'] as int;
          // Prefer the admin's own mark; fall back to the computed centroid so
          // a campus that has never been set up still shows something.
          final anchor = z['anchor'] as Map<String, dynamic>?;
          final centroid = z['centroid'] as Map<String, dynamic>?;
          final source = anchor ?? centroid;

          if (source?['lat'] != null) {
            _anchors[code] =
                LatLng((source!['lat'] as num).toDouble(), (source['lng'] as num).toDouble());
          }
          if (anchor?['radiusM'] != null) {
            _radii[code] = (anchor!['radiusM'] as num).toDouble();
          }
        }
        _error = null;
      });
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _placeAt(LatLng point) {
    // Second tap sets how far the zone reaches, measured from its centre.
    if (_settingEdge) {
      final centre = _anchors[_selected];
      if (centre == null) {
        showSnack(context, 'Mark the centre of Zone $_selected first', error: true);
        return;
      }
      final metres = const Distance().as(LengthUnit.Meter, centre, point);
      if (metres < 10) {
        showSnack(context, 'That is too close to the centre â€” tap further out', error: true);
        return;
      }
      setState(() {
        _radii[_selected] = metres;
        _moved.add(_selected);
        _settingEdge = false;
      });
      showSnack(context, 'Zone $_selected reaches about ${metres.round()} m');
      return;
    }

    setState(() {
      _anchors[_selected] = point;
      _moved.add(_selected);
      // Step to the next zone so marking all eight is one continuous pass.
      final codes = _zones.map((z) => z['code'] as int).toList()..sort();
      final i = codes.indexOf(_selected);
      if (i >= 0 && i < codes.length - 1) _selected = codes[i + 1];
    });
  }

  Future<void> _useMyLocation() async {
    setState(() => _busy = true);
    try {
      final fix = await LocationService.current();
      if (!mounted) return;
      final point = LatLng(fix.lat, fix.lng);
      _placeAt(point);
      _mapController.move(point, 17);
      showSnack(context, 'Zone $_selected marked at your location');
    } on LocationDenied catch (e) {
      if (mounted) showSnack(context, e.message, error: true);
    } catch (_) {
      if (mounted) {
        showSnack(context, 'Could not get a GPS fix. Move outdoors and retry.', error: true);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _apply() async {
    if (_anchors.length < 2) {
      showSnack(context, 'Mark at least two zones first', error: true);
      return;
    }

    setState(() => _busy = true);
    try {
      final res = await context.read<ApiClient>().post('/admin/zones/anchors', {
        'anchors': _anchors.entries
            .map((e) => {
                  'code': e.key,
                  'lat': e.value.latitude,
                  'lng': e.value.longitude,
                  if (_radii[e.key] != null) 'radiusM': _radii[e.key],
                })
            .toList(),
        'marginM': 400,
      });

      if (!mounted) return;
      setState(() {
        _coveragePct = res['coveragePct'] as int?;
        _moved.clear();
      });
      await _load();
      if (mounted) showSnack(context, res['message'] as String? ?? 'Boundaries computed');
    } on ApiException catch (e) {
      if (mounted) showSnack(context, e.message, error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  LatLng get _centre {
    if (_anchors.isEmpty) return const LatLng(26.7314, 83.4324); // MMMUT Gorakhpur
    final lat = _anchors.values.map((p) => p.latitude).reduce((a, b) => a + b) / _anchors.length;
    final lng = _anchors.values.map((p) => p.longitude).reduce((a, b) => a + b) / _anchors.length;
    return LatLng(lat, lng);
  }

  Color _colorOf(int code) {
    final z = _zones.firstWhere(
      (z) => z['code'] == code,
      orElse: () => const <String, dynamic>{},
    );
    return colorFromHex(z['colorHex'] as String? ?? '#0072B2');
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: const Text('Set up zones')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    if (_error != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Set up zones')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.cloud_off, size: 44, color: Palette.critical),
                const SizedBox(height: 14),
                Text(_error!, textAlign: TextAlign.center),
                const SizedBox(height: 18),
                OutlinedButton(onPressed: _load, child: const Text('Try again')),
              ],
            ),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Set up zones'),
        actions: [
          TextButton(
            onPressed: _busy ? null : _apply,
            child: Text(
              _busy ? 'Workingâ€¦' : 'Apply',
              style: const TextStyle(
                  color: Colors.white, fontWeight: FontWeight.w700, fontSize: 15),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                FlutterMap(
                  mapController: _mapController,
                  options: MapOptions(
                    initialCenter: _centre,
                    initialZoom: 15.5,
                    onTap: (_, point) => _placeAt(point),
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

                    // The boundaries currently in force.
                    PolygonLayer(
                      polygons: [
                        for (final z in _zones)
                          if ((z['polygon'] as List?) != null &&
                              (z['polygon'] as List).length >= 3)
                            Polygon(
                              points: (z['polygon'] as List)
                                  .map<LatLng>((p) => LatLng(
                                        (p[0] as num).toDouble(),
                                        (p[1] as num).toDouble(),
                                      ))
                                  .toList(),
                              color: colorFromHex(z['colorHex'] as String? ?? '#0072B2')
                                  .withValues(alpha: 0.18),
                              borderColor:
                                  colorFromHex(z['colorHex'] as String? ?? '#0072B2')
                                      .withValues(alpha: 0.8),
                              borderStrokeWidth: 2,
                            ),
                      ],
                    ),

                    // How far each zone claims to reach. Deliberately drawn
                    // as a dashed-looking outline, not a filled disc: it is a
                    // claim on territory, not the zone's actual edge. The
                    // solid polygons above are the real boundaries.
                    CircleLayer(
                      circles: [
                        for (final entry in _radii.entries)
                          if (_anchors[entry.key] != null)
                            CircleMarker(
                              point: _anchors[entry.key]!,
                              radius: entry.value,
                              useRadiusInMeter: true,
                              color: Colors.transparent,
                              borderColor: _colorOf(entry.key).withValues(alpha: 0.85),
                              borderStrokeWidth: entry.key == _selected ? 3 : 1.5,
                            ),
                      ],
                    ),

                    MarkerLayer(
                      markers: [
                        for (final entry in _anchors.entries)
                          Marker(
                            point: entry.value,
                            width: 46,
                            height: 46,
                            child: _AnchorPin(
                              code: entry.key,
                              color: _colorOf(entry.key),
                              selected: entry.key == _selected,
                              moved: _moved.contains(entry.key),
                              onTap: () => setState(() => _selected = entry.key),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),

                Positioned(
                  top: 12,
                  left: 12,
                  right: 12,
                  child: _Instruction(
                    selected: _selected,
                    color: _colorOf(_selected),
                    placed: _anchors.length,
                    total: _zones.length,
                    pendingChanges: _moved.length,
                    coveragePct: _coveragePct,
                    settingEdge: _settingEdge,
                    radiusM: _radii[_selected],
                  ),
                ),
              ],
            ),
          ),
          _ZonePicker(
            zones: _zones,
            anchors: _anchors,
            moved: _moved,
            selected: _selected,
            busy: _busy,
            onSelect: (code) {
              setState(() => _selected = code);
              final p = _anchors[code];
              if (p != null) _mapController.move(p, _mapController.camera.zoom);
            },
            onUseLocation: _busy ? null : _useMyLocation,
            onApply: _busy ? null : _apply,
            settingEdge: _settingEdge,
            hasRadius: _radii[_selected] != null,
            onSetEdge: _anchors[_selected] == null
                ? null
                : () => setState(() => _settingEdge = !_settingEdge),
            onClearRadius: _radii[_selected] == null
                ? null
                : () => setState(() {
                      _radii.remove(_selected);
                      _moved.add(_selected);
                      _settingEdge = false;
                    }),
          ),
        ],
      ),
    );
  }
}

class _AnchorPin extends StatelessWidget {
  final int code;
  final Color color;
  final bool selected;
  final bool moved;
  final VoidCallback onTap;

  const _AnchorPin({
    required this.code,
    required this.color,
    required this.selected,
    required this.moved,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Center(
        child: Container(
          width: selected ? 42 : 32,
          height: selected ? 42 : 32,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(
              color: selected ? Palette.inkPrimary : Colors.white,
              width: selected ? 3.5 : 2.5,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.3),
                blurRadius: 4,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Center(
            child: Text(
              '$code',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w800,
                fontSize: selected ? 17 : 14,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Instruction extends StatelessWidget {
  final int selected;
  final Color color;
  final int placed;
  final int total;
  final int pendingChanges;
  final int? coveragePct;
  final bool settingEdge;
  final double? radiusM;

  const _Instruction({
    required this.selected,
    required this.color,
    required this.placed,
    required this.total,
    required this.pendingChanges,
    this.coveragePct,
    this.settingEdge = false,
    this.radiusM,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      elevation: 3,
      borderRadius: BorderRadius.circular(12),
      color: Colors.white,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        child: Column(
          children: [
            Row(
              children: [
                Container(
                  width: 26,
                  height: 26,
                  decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                  child: Center(
                    child: Text(
                      '$selected',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    settingEdge
                        ? 'Tap how far this zone reaches'
                        : 'Tap the map where this zone is',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: settingEdge ? Palette.warning : Palette.inkPrimary,
                    ),
                  ),
                ),
                Text(
                  radiusM != null ? '${radiusM!.round()} m' : '$placed/$total',
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w700, color: Palette.inkMuted),
                ),
              ],
            ),
            if (pendingChanges > 0) ...[
              const SizedBox(height: 6),
              Row(
                children: [
                  const Icon(Icons.edit_location_alt, size: 14, color: Palette.warning),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '$pendingChanges mark(s) moved â€” tap Apply to redraw the boundaries',
                      style: const TextStyle(fontSize: 11.5, color: Palette.warning),
                    ),
                  ),
                ],
              ),
            ] else if (coveragePct != null) ...[
              const SizedBox(height: 6),
              Row(
                children: [
                  const Icon(Icons.verified, size: 14, color: Palette.good),
                  const SizedBox(width: 6),
                  Text(
                    '$coveragePct% of campus covered â€” no gaps, no overlaps',
                    style: const TextStyle(fontSize: 11.5, color: Palette.good),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ZonePicker extends StatelessWidget {
  final List<Map<String, dynamic>> zones;
  final Map<int, LatLng> anchors;
  final Set<int> moved;
  final int selected;
  final bool busy;
  final void Function(int code) onSelect;
  final VoidCallback? onUseLocation;
  final VoidCallback? onApply;
  final bool settingEdge;
  final bool hasRadius;
  final VoidCallback? onSetEdge;
  final VoidCallback? onClearRadius;

  const _ZonePicker({
    required this.zones,
    required this.anchors,
    required this.moved,
    required this.selected,
    required this.busy,
    required this.onSelect,
    this.onUseLocation,
    this.onApply,
    this.settingEdge = false,
    this.hasRadius = false,
    this.onSetEdge,
    this.onClearRadius,
  });

  @override
  Widget build(BuildContext context) {
    final sorted = [...zones]
      ..sort((a, b) => (a['code'] as int).compareTo(b['code'] as int));

    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: Palette.grid)),
      ),
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 62,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: sorted.length,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (_, i) {
                final z = sorted[i];
                final code = z['code'] as int;
                final color = colorFromHex(z['colorHex'] as String? ?? '#0072B2');
                final isSelected = code == selected;
                final hasAnchor = anchors.containsKey(code);

                return GestureDetector(
                  onTap: () => onSelect(code),
                  child: Container(
                    width: 96,
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
                    decoration: BoxDecoration(
                      color: isSelected ? color.withValues(alpha: 0.16) : Colors.white,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: isSelected ? color : Palette.grid,
                        width: isSelected ? 2.5 : 1,
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Container(
                              width: 10,
                              height: 10,
                              decoration: BoxDecoration(
                                  color: color, borderRadius: BorderRadius.circular(3)),
                            ),
                            const SizedBox(width: 5),
                            Text(
                              'Zone $code',
                              style: const TextStyle(
                                  fontSize: 12.5, fontWeight: FontWeight.w800),
                            ),
                          ],
                        ),
                        const SizedBox(height: 3),
                        Row(
                          children: [
                            Icon(
                              moved.contains(code)
                                  ? Icons.edit_location_alt
                                  : hasAnchor
                                      ? Icons.check_circle
                                      : Icons.radio_button_unchecked,
                              size: 12,
                              color: moved.contains(code)
                                  ? Palette.warning
                                  : hasAnchor
                                      ? Palette.good
                                      : Palette.inkMuted,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              moved.contains(code)
                                  ? 'moved'
                                  : hasAnchor
                                      ? 'marked'
                                      : 'not set',
                              style: const TextStyle(
                                  fontSize: 10.5, color: Palette.inkMuted),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(42),
                    foregroundColor: settingEdge ? Palette.warning : null,
                    side: settingEdge ? const BorderSide(color: Palette.warning) : null,
                  ),
                  onPressed: onSetEdge,
                  icon: Icon(settingEdge ? Icons.close : Icons.adjust, size: 18),
                  label: Text(
                    settingEdge
                        ? 'Cancel'
                        : hasRadius
                            ? 'Change size'
                            : 'Set how far it reaches',
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
              ),
              if (hasRadius) ...[
                const SizedBox(width: 8),
                IconButton.filledTonal(
                  onPressed: onClearRadius,
                  icon: const Icon(Icons.restart_alt, size: 18),
                  tooltip: 'Use default size',
                ),
              ],
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(46)),
                  onPressed: onUseLocation,
                  icon: const Icon(Icons.my_location, size: 19),
                  label: Text('I am in Zone $selected'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(46),
                    backgroundColor: moved.isEmpty ? null : Palette.good,
                  ),
                  onPressed: onApply,
                  icon: busy
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white),
                        )
                      : const Icon(Icons.auto_awesome_motion, size: 19),
                  label: const Text('Apply'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

