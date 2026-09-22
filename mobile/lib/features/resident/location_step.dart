import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../core/location_service.dart';
import '../../core/palette.dart';
import '../../core/theme.dart';

/// A location the resident has captured and confirmed.
///
/// `pin` is where the complaint is. `raw` is what the phone actually reported.
/// They differ only when the resident nudged the pin to correct a poor indoor
/// fix, and both are kept so that correction stays auditable.
class PinnedLocation {
  final LatLng pin;
  final LatLng raw;
  final double accuracyM;
  final DateTime capturedAt;

  const PinnedLocation({
    required this.pin,
    required this.raw,
    required this.accuracyM,
    required this.capturedAt,
  });

  double get adjustedM => const Distance().as(LengthUnit.Meter, raw, pin);
  bool get isAdjusted => adjustedM > 5;
}

/// Step one of filing a complaint: capture exactly where you are, see it on a
/// map, and lock it.
///
/// The GPS fix was always being recorded, but only as a line of coordinates -
/// which tells a resident nothing about whether it is right. Showing the pin
/// on a map lets them check it, and locking it makes the location a deliberate
/// act rather than a silent side effect of opening the screen.
class LocationStep extends StatefulWidget {
  final PinnedLocation? value;
  final ValueChanged<PinnedLocation?> onChanged;

  /// Zone resolved from the pin, shown once locked.
  final Map<String, dynamic>? zone;
  final bool zoneOutsideBoundary;

  /// How far the pin may be moved off the raw fix. Mirrors the server rule.
  final double maxAdjustM;

  const LocationStep({
    super.key,
    required this.value,
    required this.onChanged,
    this.zone,
    this.zoneOutsideBoundary = false,
    this.maxAdjustM = 150,
  });

  @override
  State<LocationStep> createState() => _LocationStepState();
}

class _LocationStepState extends State<LocationStep> {
  final _mapController = MapController();

  GeoFix? _fix;
  LatLng? _pin;
  bool _locating = false;
  bool _adjusting = false;
  String? _error;

  bool get _locked => widget.value != null;

  @override
  void initState() {
    super.initState();
    if (widget.value == null) _acquire();
  }

  @override
  void dispose() {
    _mapController.dispose();
    super.dispose();
  }

  Future<void> _acquire() async {
    setState(() {
      _locating = true;
      _error = null;
    });

    try {
      final fix = await LocationService.current();
      if (!mounted) return;
      setState(() {
        _fix = fix;
        _pin = LatLng(fix.lat, fix.lng);
      });
      _mapController.move(_pin!, 18);
    } on LocationDenied catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Could not get a GPS fix. Move outdoors and try again.');
      }
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  void _movePin(LatLng point) {
    if (!_adjusting || _fix == null) return;

    final raw = LatLng(_fix!.lat, _fix!.lng);
    final metres = const Distance().as(LengthUnit.Meter, raw, point);

    if (metres > widget.maxAdjustM) {
      setState(() => _error =
          'That is ${metres.round()}m from where your phone says you are. '
          'Stay within ${widget.maxAdjustM.round()}m.');
      return;
    }

    setState(() {
      _pin = point;
      _error = null;
    });
  }

  void _lock() {
    if (_fix == null || _pin == null) return;
    widget.onChanged(PinnedLocation(
      pin: _pin!,
      raw: LatLng(_fix!.lat, _fix!.lng),
      accuracyM: _fix!.accuracyM,
      capturedAt: _fix!.at,
    ));
    setState(() => _adjusting = false);
  }

  void _unlock() {
    widget.onChanged(null);
    setState(() => _adjusting = false);
    if (_fix == null) _acquire();
  }

  @override
  Widget build(BuildContext context) {
    if (_locked) {
      return _LockedCard(
        value: widget.value!,
        zone: widget.zone,
        zoneOutsideBoundary: widget.zoneOutsideBoundary,
        onRedo: _unlock,
      );
    }

    if (_error != null && _pin == null) {
      return _Shell(
        color: Palette.critical,
        icon: Icons.location_disabled,
        title: 'Location unavailable',
        body: _error!,
        action: TextButton(onPressed: _acquire, child: const Text('Try again')),
      );
    }

    if (_locating || _pin == null) {
      return const _Shell(
        color: Palette.neutral,
        icon: Icons.my_location,
        title: 'Finding where you are…',
        body: 'A complaint cannot be filed without its exact location.',
        showSpinner: true,
      );
    }

    final poor = (_fix?.accuracyM ?? 0) > 30;

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Palette.warning.withValues(alpha: 0.6), width: 1.4),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          SizedBox(
            height: 200,
            child: Stack(
              children: [
                FlutterMap(
                  mapController: _mapController,
                  options: MapOptions(
                    initialCenter: _pin!,
                    initialZoom: 18,
                    onTap: (_, point) => _movePin(point),
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
                    // How confident the phone is. A big circle means a rough
                    // fix and is the cue to nudge the pin.
                    if (_fix != null)
                      CircleLayer(
                        circles: [
                          CircleMarker(
                            point: LatLng(_fix!.lat, _fix!.lng),
                            radius: _fix!.accuracyM,
                            useRadiusInMeter: true,
                            color: AppTheme.seed.withValues(alpha: 0.12),
                            borderColor: AppTheme.seed.withValues(alpha: 0.4),
                            borderStrokeWidth: 1,
                          ),
                        ],
                      ),
                    MarkerLayer(
                      markers: [
                        Marker(
                          point: _pin!,
                          width: 40,
                          height: 40,
                          child: Icon(
                            Icons.place,
                            size: 38,
                            color: _adjusting ? Palette.warning : AppTheme.seed,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                if (_adjusting)
                  Positioned(
                    top: 8,
                    left: 8,
                    right: 8,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                      decoration: BoxDecoration(
                        color: Palette.warning,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Text(
                        'Tap the map to move the pin to the exact spot',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(13, 11, 13, 13),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      poor ? Icons.gps_not_fixed : Icons.gps_fixed,
                      size: 16,
                      color: poor ? Palette.warning : Palette.good,
                    ),
                    const SizedBox(width: 7),
                    Expanded(
                      child: Text(
                        poor
                            ? 'Rough fix, accurate to about ${_fix!.accuracyM.round()}m'
                            : 'Accurate to about ${_fix!.accuracyM.round()}m',
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          color: poor ? Palette.warning : Palette.good,
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: _acquire,
                      icon: const Icon(Icons.refresh, size: 19),
                      tooltip: 'Refresh location',
                      visualDensity: VisualDensity.compact,
                    ),
                  ],
                ),
                if (poor && !_adjusting) ...[
                  const SizedBox(height: 3),
                  const Text(
                    'If the pin is not on the right spot, move it before locking.',
                    style: TextStyle(fontSize: 11.5, color: Palette.inkSecondary),
                  ),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 7),
                  Text(
                    _error!,
                    style: const TextStyle(fontSize: 12, color: Palette.critical),
                  ),
                ],
                const SizedBox(height: 11),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size.fromHeight(44),
                          foregroundColor: _adjusting ? Palette.warning : null,
                          side: _adjusting
                              ? const BorderSide(color: Palette.warning)
                              : null,
                        ),
                        onPressed: () => setState(() => _adjusting = !_adjusting),
                        icon: Icon(_adjusting ? Icons.check : Icons.edit_location_alt,
                            size: 18),
                        label: Text(_adjusting ? 'Done moving' : 'Move pin',
                            style: const TextStyle(fontSize: 13.5)),
                      ),
                    ),
                    const SizedBox(width: 9),
                    Expanded(
                      flex: 2,
                      child: FilledButton.icon(
                        style: FilledButton.styleFrom(
                          minimumSize: const Size.fromHeight(44),
                        ),
                        onPressed: _lock,
                        icon: const Icon(Icons.lock_outline, size: 18),
                        label: const Text('Use this location'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Once locked, the location is settled and shown read-only.
class _LockedCard extends StatelessWidget {
  final PinnedLocation value;
  final Map<String, dynamic>? zone;
  final bool zoneOutsideBoundary;
  final VoidCallback onRedo;

  const _LockedCard({
    required this.value,
    required this.zone,
    required this.zoneOutsideBoundary,
    required this.onRedo,
  });

  @override
  Widget build(BuildContext context) {
    final zoneName = zone?['name'] as String?;
    final zoneLabel = zone?['label'] as String?;
    final zoneColor = colorFromHex(zone?['colorHex'] as String? ?? '#0072B2');

    // A nearest-edge guess gets the same visual weight as a real lock - a
    // confident green card here is what let a wrong zone slip past
    // unnoticed. The warning banner below the form said as much, but this
    // is the box residents actually look at.
    final color = zoneOutsideBoundary ? Palette.warning : Palette.good;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.5), width: 1.4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                zoneOutsideBoundary ? Icons.error_outline : Icons.check_circle,
                color: color,
                size: 21,
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  zoneOutsideBoundary ? 'Location locked — zone is a guess' : 'Location locked',
                  style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w800),
                ),
              ),
              TextButton(
                onPressed: onRedo,
                style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                child: const Text('Change', style: TextStyle(fontSize: 13)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (zoneName != null)
            Row(
              children: [
                Container(
                  width: 11,
                  height: 11,
                  decoration: BoxDecoration(
                    color: zoneColor,
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    zoneLabel != null ? '$zoneName · $zoneLabel' : zoneName,
                    style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
          if (zoneOutsideBoundary) ...[
            const SizedBox(height: 6),
            const Text(
              'This spot is outside every drawn zone boundary — the nearest one is '
              'shown as a guess. Pick the right zone below if this is wrong.',
              style: TextStyle(fontSize: 12, height: 1.35, color: Palette.inkSecondary),
            ),
          ],
          const SizedBox(height: 6),
          Text(
            '${value.pin.latitude.toStringAsFixed(6)}, '
            '${value.pin.longitude.toStringAsFixed(6)}  ·  '
            '±${value.accuracyM.round()}m',
            style: const TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              color: Palette.inkMuted,
            ),
          ),
          if (value.isAdjusted) ...[
            const SizedBox(height: 5),
            Text(
              'Pin moved ${value.adjustedM.round()}m from the GPS reading',
              style: const TextStyle(fontSize: 11.5, color: Palette.warning),
            ),
          ],
        ],
      ),
    );
  }
}

class _Shell extends StatelessWidget {
  final Color color;
  final IconData icon;
  final String title;
  final String body;
  final Widget? action;
  final bool showSpinner;

  const _Shell({
    required this.color,
    required this.icon,
    required this.title,
    required this.body,
    this.action,
    this.showSpinner = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.09),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 21),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                const SizedBox(height: 3),
                Text(
                  body,
                  style: const TextStyle(
                      fontSize: 12.5, height: 1.35, color: Palette.inkSecondary),
                ),
                if (action != null) action!,
              ],
            ),
          ),
          if (showSpinner)
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2.2),
            ),
        ],
      ),
    );
  }
}
