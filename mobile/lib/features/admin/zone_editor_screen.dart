import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../../core/api_client.dart';
import '../../core/palette.dart';
import '../../core/theme.dart';
import '../../shared/ui.dart';

/// Draw a zone's boundary on the map.
///
/// Tap the map to drop a corner, tap a corner to remove it. The shape is
/// validated against the server as you go, so the admin sees a self-crossing
/// boundary or an overlap with a neighbour before saving rather than after a
/// complaint lands in the wrong place.
class ZoneEditorScreen extends StatefulWidget {
  final Map<String, dynamic> zone;

  const ZoneEditorScreen({super.key, required this.zone});

  @override
  State<ZoneEditorScreen> createState() => _ZoneEditorScreenState();
}

class _ZoneEditorScreenState extends State<ZoneEditorScreen> {
  final _mapController = MapController();

  late List<LatLng> _points;
  late TextEditingController _name;
  late TextEditingController _label;
  late String _colorHex;
  String? _officerId;

  List<Map<String, dynamic>> _otherZones = const [];
  List<Map<String, dynamic>> _officers = const [];

  bool _drawing = false;
  bool _busy = false;
  bool _dirty = false;

  /// The shape as it was before this drawing session, kept on screen as a
  /// faint outline. Entering draw mode starts a NEW shape rather than
  /// appending to the old one - tapping the map used to tack corners onto the
  /// existing square and drag it into a mess.
  List<LatLng> _ghost = const [];

  void _toggleDrawing() {
    setState(() {
      if (!_drawing) {
        _drawing = true;
        if (_points.isNotEmpty) {
          _ghost = List.of(_points);
          _points = [];
          _errors = const [];
          _warnings = const [];
          _areaM2 = 0;
          _dirty = true;
        }
      } else {
        _drawing = false;
        // Nothing was drawn - put the old shape back rather than losing it.
        if (_points.isEmpty && _ghost.isNotEmpty) {
          _points = List.of(_ghost);
          _ghost = const [];
          _dirty = false;
          _validate();
        }
      }
    });
  }

  // Live validation from the server.
  List<String> _errors = const [];
  List<String> _warnings = const [];
  int _areaM2 = 0;

  @override
  void initState() {
    super.initState();
    final polygon = (widget.zone['polygon'] as List?) ?? const [];
    _points = polygon
        .map<LatLng>((p) => LatLng((p[0] as num).toDouble(), (p[1] as num).toDouble()))
        .toList();

    _name = TextEditingController(text: widget.zone['name'] as String? ?? '');
    _label = TextEditingController(text: widget.zone['label'] as String? ?? '');
    _colorHex = widget.zone['colorHex'] as String? ?? '#0072B2';
    _officerId = (widget.zone['officer'] as Map<String, dynamic>?)?['id'] as String?;
    _areaM2 = widget.zone['areaM2'] as int? ?? 0;

    // A zone with no boundary has exactly one thing to do, so start in draw
    // mode rather than making the admin hunt for the button first.
    _drawing = _points.isEmpty;

    _loadContext();
  }

  @override
  void dispose() {
    _name.dispose();
    _label.dispose();
    _mapController.dispose();
    super.dispose();
  }

  Future<void> _loadContext() async {
    try {
      final api = context.read<ApiClient>();
      final results = await Future.wait([
        api.get('/admin/zones'),
        api.get('/admin/zones/officers'),
      ]);
      if (!mounted) return;
      setState(() {
        _otherZones = (results[0]['zones'] as List)
            .cast<Map<String, dynamic>>()
            .where((z) => z['code'] != widget.zone['code'])
            .toList();
        _officers = (results[1]['officers'] as List).cast<Map<String, dynamic>>();
      });
    } on ApiException {
      // Context is a convenience; the editor still works without it.
    }
  }

  /// Ask the server whether the current shape is legal.
  Future<void> _validate() async {
    if (_points.length < 3) {
      setState(() {
        _errors = const [];
        _warnings = const [];
        _areaM2 = 0;
      });
      return;
    }

    try {
      final res = await context.read<ApiClient>().post('/admin/zones/validate', {
        'code': widget.zone['code'],
        'polygon': _points.map((p) => [p.latitude, p.longitude]).toList(),
      });
      if (!mounted) return;
      setState(() {
        _errors = (res['errors'] as List?)?.cast<String>() ?? const [];
        _warnings = (res['warnings'] as List?)?.cast<String>() ?? const [];
        _areaM2 = res['areaM2'] as int? ?? 0;
      });
    } on ApiException catch (e) {
      if (mounted) setState(() => _errors = [e.message]);
    }
  }

  void _addPoint(LatLng p) {
    // Tapping the map while not in draw mode used to do nothing at all, which
    // reads as "the map is broken". Say what to do instead.
    if (!_drawing) {
      showSnack(context, 'Tap "Draw boundary" first, then tap the map to add corners');
      return;
    }
    setState(() {
      _points.add(p);
      _dirty = true;
    });
    _validate();
  }

  void _removePoint(int index) {
    setState(() {
      _points.removeAt(index);
      _dirty = true;
    });
    _validate();
  }

  void _undo() {
    if (_points.isEmpty) return;
    setState(() {
      _points.removeLast();
      _dirty = true;
    });
    _validate();
  }

  Future<void> _clear() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Clear the boundary?'),
        content: const Text(
          'This removes every corner. The saved boundary stays until you save '
          'the empty one.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Palette.critical),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      setState(() {
        _points = [];
        _dirty = true;
        _errors = const [];
        _warnings = const [];
        _areaM2 = 0;
      });
    }
  }

  Future<void> _save() async {
    if (_points.isNotEmpty && _points.length < 3) {
      showSnack(context, 'A boundary needs at least 3 corners', error: true);
      return;
    }
    if (_errors.isNotEmpty) {
      showSnack(context, _errors.first, error: true);
      return;
    }

    setState(() => _busy = true);

    try {
      final body = <String, dynamic>{
        'name': _name.text.trim(),
        'label': _label.text.trim(),
        'colorHex': _colorHex,
        if (_officerId != null) 'officerId': _officerId,
        if (_points.length >= 3)
          'polygon': _points.map((p) => [p.latitude, p.longitude]).toList(),
      };

      final res = await context.read<ApiClient>().put('/admin/zones/${widget.zone['code']}', body);

      if (!mounted) return;
      final warnings = (res['warnings'] as List?)?.cast<String>() ?? const [];
      Navigator.of(context).pop(true);
      showSnack(
        context,
        warnings.isEmpty
            ? res['message'] as String? ?? 'Zone saved'
            : warnings.first,
      );
    } on ApiException catch (e) {
      if (mounted) showSnack(context, e.message, error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  LatLng get _initialCentre {
    if (_points.isNotEmpty) {
      final lat = _points.map((p) => p.latitude).reduce((a, b) => a + b) / _points.length;
      final lng = _points.map((p) => p.longitude).reduce((a, b) => a + b) / _points.length;
      return LatLng(lat, lng);
    }

    final c = widget.zone['centroid'] as Map<String, dynamic>?;
    if (c != null && c['lat'] != null) {
      return LatLng((c['lat'] as num).toDouble(), (c['lng'] as num).toDouble());
    }

    // Nothing drawn yet - open on whichever zone HAS been drawn, so each new
    // zone starts next to its neighbours rather than back at the default.
    for (final z in _otherZones) {
      final oc = z['centroid'] as Map<String, dynamic>?;
      if (oc != null && oc['lat'] != null) {
        return LatLng((oc['lat'] as num).toDouble(), (oc['lng'] as num).toDouble());
      }
    }

    return const LatLng(26.7314, 83.4324); // MMMUT Gorakhpur
  }

  @override
  Widget build(BuildContext context) {
    final color = colorFromHex(_colorHex);

    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop || !mounted) return;
        // Capture the navigator before awaiting, so the dialog result is not
        // used against a context that may have gone away.
        final navigator = Navigator.of(context);
        final leave = await showDialog<bool>(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text('Discard changes?'),
            content: const Text('The boundary you drew has not been saved.'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Keep editing'),
              ),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: Palette.critical),
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Discard'),
              ),
            ],
          ),
        );
        if (leave == true) navigator.pop(false);
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.zone['name'] as String? ?? 'Zone'),
          actions: [
            TextButton(
              onPressed: _busy ? null : _save,
              child: Text(
                _busy ? 'Savingâ€¦' : 'Save',
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
                      initialCenter: _initialCentre,
                      initialZoom: 16,
                      onTap: (_, point) => _addPoint(point),
                      interactionOptions: const InteractionOptions(
                        flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
                      ),
                    ),
                    children: [
                      TileLayer(
                        // Satellite, not OSM's cartographic tiles - MMMUT's
                        // campus is thin on OSM detail, but the actual
                        // ground (buildings, paths, boundaries) shows up
                        // clearly in imagery either way.
                        urlTemplate:
                            'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}',
                        userAgentPackageName: 'edu.campus.zonal',
                        maxZoom: 19,
                      ),

                      // Neighbouring zones, dimmed - context for where this
                      // boundary should stop.
                      PolygonLayer(
                        polygons: [
                          for (final z in _otherZones)
                            if ((z['polygon'] as List?)?.length != null &&
                                (z['polygon'] as List).length >= 3)
                              Polygon(
                                points: (z['polygon'] as List)
                                    .map<LatLng>((p) => LatLng(
                                          (p[0] as num).toDouble(),
                                          (p[1] as num).toDouble(),
                                        ))
                                    .toList(),
                                color: colorFromHex(z['colorHex'] as String? ?? '#999999')
                                    .withValues(alpha: 0.10),
                                borderColor: colorFromHex(z['colorHex'] as String? ?? '#999999')
                                    .withValues(alpha: 0.5),
                                borderStrokeWidth: 1,
                              ),
                        ],
                      ),

                      // The previous shape, while a new one is being drawn.
                      if (_ghost.length >= 3)
                        PolygonLayer(
                          polygons: [
                            Polygon(
                              points: _ghost,
                              color: Colors.transparent,
                              borderColor: Palette.inkMuted.withValues(alpha: 0.55),
                              borderStrokeWidth: 1.5,
                            ),
                          ],
                        ),

                      // The zone being edited.
                      if (_points.length >= 3)
                        PolygonLayer(
                          polygons: [
                            Polygon(
                              points: _points,
                              color: color.withValues(alpha: 0.28),
                              borderColor: _errors.isEmpty ? color : Palette.critical,
                              borderStrokeWidth: 3,
                            ),
                          ],
                        ),

                      // While there are too few points to close a shape, show
                      // the open path so the admin can see what they have.
                      if (_points.length == 2)
                        PolylineLayer(
                          polylines: [
                            Polyline(points: _points, color: color, strokeWidth: 3),
                          ],
                        ),

                      // Corner handles. Tap one to delete it.
                      MarkerLayer(
                        markers: [
                          for (var i = 0; i < _points.length; i++)
                            Marker(
                              point: _points[i],
                              width: 30,
                              height: 30,
                              child: GestureDetector(
                                onTap: () => _removePoint(i),
                                child: Container(
                                  decoration: BoxDecoration(
                                    color: Colors.white,
                                    shape: BoxShape.circle,
                                    border: Border.all(color: color, width: 3),
                                  ),
                                  child: Center(
                                    child: Text(
                                      '${i + 1}',
                                      style: TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w800,
                                        color: color,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),

                  // Drawing controls
                  Positioned(
                    top: 12,
                    left: 12,
                    right: 12,
                    child: _DrawBar(
                      drawing: _drawing,
                      pointCount: _points.length,
                      areaM2: _areaM2,
                      onToggle: _toggleDrawing,
                      onUndo: _points.isEmpty ? null : _undo,
                      onClear: _points.isEmpty ? null : _clear,
                    ),
                  ),

                  if (_errors.isNotEmpty || _warnings.isNotEmpty)
                    Positioned(
                      bottom: 12,
                      left: 12,
                      right: 12,
                      child: _ValidationBanner(errors: _errors, warnings: _warnings),
                    ),
                ],
              ),
            ),
            _DetailsPanel(
              name: _name,
              label: _label,
              colorHex: _colorHex,
              onColor: (hex) => setState(() {
                _colorHex = hex;
                _dirty = true;
              }),
              officers: _officers,
              officerId: _officerId,
              zoneCode: widget.zone['code'] as int,
              onOfficer: (id) => setState(() {
                _officerId = id;
                _dirty = true;
              }),
              onEdited: () => _dirty = true,
            ),
          ],
        ),
      ),
    );
  }
}

class _DrawBar extends StatelessWidget {
  final bool drawing;
  final int pointCount;
  final int areaM2;
  final VoidCallback onToggle;
  final VoidCallback? onUndo;
  final VoidCallback? onClear;

  const _DrawBar({
    required this.drawing,
    required this.pointCount,
    required this.areaM2,
    required this.onToggle,
    this.onUndo,
    this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      elevation: 3,
      borderRadius: BorderRadius.circular(12),
      color: Colors.white,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(40),
                      backgroundColor: drawing ? Palette.good : AppTheme.seed,
                    ),
                    onPressed: onToggle,
                    icon: Icon(drawing ? Icons.check : Icons.edit_location_alt, size: 18),
                    label: Text(drawing ? 'Done drawing' : 'Draw boundary'),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filledTonal(
                  onPressed: onUndo,
                  icon: const Icon(Icons.undo, size: 19),
                  tooltip: 'Undo last corner',
                ),
                IconButton.filledTonal(
                  onPressed: onClear,
                  icon: const Icon(Icons.delete_outline, size: 19),
                  tooltip: 'Clear all corners',
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              drawing
                  ? 'Tap the map to drop a corner Â· tap a corner to remove it'
                  : pointCount == 0
                      ? 'No boundary yet â€” tap "Draw boundary" to start'
                      // Always say how to edit, even when a boundary exists.
                      : 'Tap "Draw boundary" to edit Â· $pointCount corners'
                          '${areaM2 > 0 ? ' Â· ${areaM2 > 10000 ? '${(areaM2 / 10000).toStringAsFixed(2)} ha' : '$areaM2 mÂ²'}' : ''}',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 11.5,
                color: drawing ? Palette.good : Palette.inkSecondary,
                fontWeight: drawing ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ValidationBanner extends StatelessWidget {
  final List<String> errors;
  final List<String> warnings;

  const _ValidationBanner({required this.errors, required this.warnings});

  @override
  Widget build(BuildContext context) {
    final isError = errors.isNotEmpty;
    final color = isError ? Palette.critical : Palette.warning;
    final messages = isError ? errors : warnings;

    return Material(
      elevation: 3,
      borderRadius: BorderRadius.circular(12),
      color: Colors.white,
      child: Container(
        padding: const EdgeInsets.all(13),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withValues(alpha: 0.45)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(isError ? Icons.error_outline : Icons.warning_amber, color: color, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final m in messages)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 2),
                      child: Text(
                        m,
                        style: TextStyle(fontSize: 12.5, height: 1.35, color: color),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DetailsPanel extends StatelessWidget {
  final TextEditingController name;
  final TextEditingController label;
  final String colorHex;
  final void Function(String hex) onColor;
  final List<Map<String, dynamic>> officers;
  final String? officerId;
  final int zoneCode;
  final void Function(String? id) onOfficer;
  final VoidCallback onEdited;

  const _DetailsPanel({
    required this.name,
    required this.label,
    required this.colorHex,
    required this.onColor,
    required this.officers,
    required this.officerId,
    required this.zoneCode,
    required this.onOfficer,
    required this.onEdited,
  });

  /// The validated, colourblind-safe ring palette. Not a free colour picker:
  /// arbitrary colours would break the guarantee that adjacent zones stay
  /// distinguishable.
  static const _palette = <int, String>{
    1: '#0072B2',
    8: '#E69F00',
    7: '#009E73',
    6: '#7A52CC',
    5: '#56B4E9',
    4: '#D55E00',
    3: '#CC79A7',
    2: '#6E8B00',
  };

  @override
  Widget build(BuildContext context) {
    final available = officers
        .where((o) => o['available'] == true || (o['currentZone']?['code']) == zoneCode)
        .toList();

    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: Palette.grid)),
      ),
      constraints: const BoxConstraints(maxHeight: 250),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: name,
                    onChanged: (_) => onEdited(),
                    decoration: const InputDecoration(
                      labelText: 'Zone name',
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  flex: 2,
                  child: TextField(
                    controller: label,
                    onChanged: (_) => onEdited(),
                    decoration: const InputDecoration(
                      labelText: 'What is here',
                      isDense: true,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            const Text(
              'COLOUR',
              style: TextStyle(
                fontSize: 9.5,
                letterSpacing: 1.3,
                fontWeight: FontWeight.w700,
                color: Palette.inkMuted,
              ),
            ),
            const SizedBox(height: 7),
            Wrap(
              spacing: 8,
              children: [
                for (final hex in _palette.values)
                  GestureDetector(
                    onTap: () => onColor(hex),
                    child: Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        color: colorFromHex(hex),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: hex == colorHex ? Palette.inkPrimary : Colors.transparent,
                          width: 3,
                        ),
                      ),
                      child: hex == colorHex
                          ? const Icon(Icons.check, size: 16, color: Colors.white)
                          : null,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 14),
            const Text(
              'ZONE OFFICER',
              style: TextStyle(
                fontSize: 9.5,
                letterSpacing: 1.3,
                fontWeight: FontWeight.w700,
                color: Palette.inkMuted,
              ),
            ),
            const SizedBox(height: 7),
            DropdownButtonFormField<String>(
              initialValue: officerId,
              isExpanded: true,
              decoration: const InputDecoration(isDense: true),
              items: [
                for (final o in available)
                  DropdownMenuItem(
                    value: o['id'] as String,
                    child: Text(
                      o['name'] as String,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: onOfficer,
            ),
            const SizedBox(height: 6),
            const Text(
              'Only officers who are free, or already run this zone, are listed. '
              'An officer runs one zone at a time.',
              style: TextStyle(fontSize: 11.5, height: 1.35, color: Palette.inkMuted),
            ),
          ],
        ),
      ),
    );
  }
}

