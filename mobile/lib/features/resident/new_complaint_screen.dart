import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:record/record.dart';

import '../../core/api_client.dart';
import '../../core/config.dart';
import 'location_step.dart';
import '../../core/models.dart';
import '../../core/palette.dart';
import '../../core/session.dart';
import '../../core/theme.dart';
import '../../shared/ui.dart';

/// One captured attachment, stamped with the locked location it belongs to.
class _Attachment {
  final File file;
  final String type; // PHOTO | VIDEO | AUDIO
  final int? durationSec;
  final PinnedLocation? at;

  const _Attachment({
    required this.file,
    required this.type,
    this.durationSec,
    this.at,
  });
}

class NewComplaintScreen extends StatefulWidget {
  const NewComplaintScreen({super.key});

  @override
  State<NewComplaintScreen> createState() => _NewComplaintScreenState();
}

const _hostelCategories = {'BOYS_HOSTEL', 'GIRLS_HOSTEL'};

class _NewComplaintScreenState extends State<NewComplaintScreen> {
  final _description = TextEditingController();
  final _recorder = AudioRecorder();

  String _category = 'GARBAGE';
  bool _isEmergency = false;
  /// From inside a hostel - skips the officer queue, forwarded straight to
  /// the hostel's warden. Only offered to students; residents don't live in
  /// hostels.
  bool _isHostelComplaint = false;
  final List<_Attachment> _attachments = [];

  // Where exactly. Compulsory: GPS gives the zone, this gives the building.
  final _landmarkNote = TextEditingController();
  List<LandmarkGroup> _landmarkGroups = const [];
  Landmark? _landmark;
  bool _loadingLandmarks = true;

  /// Step one: the confirmed, locked location. Nothing else can be filled in
  /// until this exists.
  PinnedLocation? _location;

  // Zone resolved from the locked pin by the server.
  Map<String, dynamic>? _detectedZone;
  bool _zoneOutsideBoundary = false;
  int? _zoneOverrideCode;

  bool _recording = false;
  DateTime? _recordStartedAt;

  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadLandmarks();
  }

  /// Called when the resident locks (or clears) their location.
  Future<void> _onLocationChanged(PinnedLocation? value) async {
    setState(() {
      _location = value;
      _detectedZone = null;
      _zoneOutsideBoundary = false;
      _zoneOverrideCode = null;
      _error = null;
    });
    if (value != null) await _detectZone(value);
  }

  Future<void> _detectZone(PinnedLocation loc) async {
    try {
      final res = await context.read<ApiClient>().get(
        '/zones/detect',
        query: {'lat': loc.pin.latitude, 'lng': loc.pin.longitude},
      );
      if (!mounted) return;
      setState(() {
        _detectedZone = res['zone'] as Map<String, dynamic>;
        _zoneOutsideBoundary = res['matchedPolygon'] == false;
      });
    } on ApiException {
      // Not fatal - the server resolves the zone again on submit.
    }
  }

  @override
  void dispose() {
    _description.dispose();
    _landmarkNote.dispose();
    _recorder.dispose();
    super.dispose();
  }

  Future<void> _loadLandmarks() async {
    try {
      final res = await context.read<ApiClient>().get('/landmarks');
      if (!mounted) return;
      setState(() {
        _landmarkGroups = (res['groups'] as List)
            .map((g) => LandmarkGroup.fromJson(g as Map<String, dynamic>))
            .toList();
      });
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loadingLandmarks = false);
    }
  }

  Future<void> _capturePhoto() async {
    if (!_canAddMore) return;
    final picked = await ImagePicker().pickImage(
      source: ImageSource.camera,
      imageQuality: 75,
      maxWidth: 1920,
    );
    if (picked == null || !mounted) return;
    setState(() => _attachments.add(
          _Attachment(file: File(picked.path), type: 'PHOTO', at: _location),
        ));
  }

  Future<void> _captureVideo() async {
    if (!_canAddMore) return;
    final picked = await ImagePicker().pickVideo(
      source: ImageSource.camera,
      maxDuration: const Duration(seconds: AppConfig.maxVideoSeconds),
    );
    if (picked == null || !mounted) return;
    setState(() => _attachments.add(
          _Attachment(file: File(picked.path), type: 'VIDEO', at: _location),
        ));
  }

  Future<void> _toggleRecording() async {
    if (_recording) {
      final path = await _recorder.stop();
      final seconds = _recordStartedAt == null
          ? null
          : DateTime.now().difference(_recordStartedAt!).inSeconds;

      if (!mounted) return;
      setState(() {
        _recording = false;
        _recordStartedAt = null;
        if (path != null) {
          _attachments.add(_Attachment(
            file: File(path),
            type: 'AUDIO',
            durationSec: seconds,
            at: _location,
          ));
        }
      });
      return;
    }

    if (!_canAddMore) return;

    if (!await _recorder.hasPermission()) {
      if (mounted) showSnack(context, 'Microphone permission is needed', error: true);
      return;
    }

    final dir = Directory.systemTemp.createTempSync('zonal_audio');
    final path = '${dir.path}/note_${DateTime.now().millisecondsSinceEpoch}.m4a';

    await _recorder.start(const RecordConfig(), path: path);
    if (mounted) {
      setState(() {
        _recording = true;
        _recordStartedAt = DateTime.now();
      });
    }
  }

  /// Ids of every landmark that is a hostel - used to filter the picker when
  /// the hostel toggle is on, and to validate a landmark chosen before it.
  Set<String> get _hostelLandmarkIds => {
        for (final g in _landmarkGroups)
          if (_hostelCategories.contains(g.category)) for (final l in g.landmarks) l.id,
      };

  bool get _canAddMore => _attachments.length < AppConfig.maxAttachments;

  bool get _canSubmit =>
      _location != null && _landmark != null && _attachments.isNotEmpty && !_busy && !_recording;

  Future<void> _submit() async {
    if (_location == null) {
      setState(() => _error = 'A complaint needs its location. Retry the GPS fix.');
      return;
    }
    if (_landmark == null) {
      setState(() => _error = 'Choose the nearest place or landmark');
      return;
    }
    if (_attachments.isEmpty) {
      setState(() => _error = 'Add at least one photo, video or voice note');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      final loc = _location!;

      final meta = _attachments
          .map((a) => {
                if (a.durationSec != null) 'durationSec': a.durationSec,
                if (a.at != null) 'lat': a.at!.pin.latitude,
                if (a.at != null) 'lng': a.at!.pin.longitude,
                if (a.at != null) 'capturedAt': a.at!.capturedAt.toIso8601String(),
              })
          .toList();

      final res = await context.read<ApiClient>().upload(
        '/complaints',
        fields: {
          'category': _category,
          // The confirmed pin...
          'lat': '${loc.pin.latitude}',
          'lng': '${loc.pin.longitude}',
          'accuracyM': '${loc.accuracyM}',
          // ...and the raw device reading behind it, so a correction stays
          // auditable rather than silently replacing the truth.
          'gpsLat': '${loc.raw.latitude}',
          'gpsLng': '${loc.raw.longitude}',
          'gpsAccuracyM': '${loc.accuracyM}',
          'locationCapturedAt': loc.capturedAt.toIso8601String(),
          if (_description.text.trim().isNotEmpty) 'description': _description.text.trim(),
          if (_zoneOverrideCode != null) 'zoneCode': '$_zoneOverrideCode',
          'landmarkId': _landmark!.id,
          if (_landmarkNote.text.trim().isNotEmpty)
            'landmarkNote': _landmarkNote.text.trim(),
          if (_isEmergency) 'isEmergency': 'true',
          if (_isHostelComplaint) 'isHostelComplaint': 'true',
          'mediaMeta': jsonEncode(meta),
        },
        files: _attachments.map((a) => a.file).toList(),
      );

      if (mounted) {
        Navigator.of(context).pop(true);
        showSnack(context, res['message'] as String? ?? 'Complaint submitted');
      }
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Report a problem')),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
          child: FilledButton(
            style: _isEmergency
                ? FilledButton.styleFrom(backgroundColor: Palette.critical)
                : null,
            onPressed: _canSubmit ? _submit : null,
            child: _busy
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2.2, color: Colors.white),
                  )
                : Text(
                    _location == null
                        ? 'Lock your location first'
                        : _landmark == null
                            ? 'Choose a place first'
                            : _isEmergency
                                ? 'Send emergency alert'
                                : 'Submit complaint',
                  ),
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 20),
        children: [
          const _SectionLabel('1  ·  WHERE YOU ARE  ·  REQUIRED'),
          const SizedBox(height: 4),
          const Text(
            'Capture the exact spot and lock it. Everything else stays disabled '
            'until you do — the location is what decides the zone.',
            style: TextStyle(fontSize: 12.5, height: 1.35, color: Palette.inkSecondary),
          ),
          const SizedBox(height: 10),
          LocationStep(
            value: _location,
            zone: _detectedZone,
            zoneOutsideBoundary: _zoneOutsideBoundary,
            onChanged: _onLocationChanged,
          ),

          // The pin landed between zones - let the resident correct it.
          if (_location != null && _zoneOutsideBoundary) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Palette.warning.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(11),
                border: Border.all(color: Palette.warning.withValues(alpha: 0.4)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'PICK THE RIGHT ZONE',
                    style: TextStyle(
                      fontSize: 10.5,
                      letterSpacing: 1.4,
                      fontWeight: FontWeight.w700,
                      color: Palette.inkMuted,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    children: [
                      for (var code = 1; code <= 8; code++)
                        ChoiceChip(
                          selected: _zoneOverrideCode == code,
                          onSelected: (s) =>
                              setState(() => _zoneOverrideCode = s ? code : null),
                          label: Text('Zone $code',
                              style: const TextStyle(fontSize: 11.5)),
                          visualDensity: VisualDensity.compact,
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],

          const SizedBox(height: 22),
          const _SectionLabel('2  ·  WHICH BUILDING  ·  REQUIRED'),
          const SizedBox(height: 4),
          const Text(
            'The zone tells us which part of campus. This tells the worker which '
            'building to walk to.',
            style: TextStyle(fontSize: 12.5, height: 1.35, color: Palette.inkSecondary),
          ),
          const SizedBox(height: 10),
          _LandmarkPicker(
            groups: _isHostelComplaint
                ? _landmarkGroups.where((g) => _hostelCategories.contains(g.category)).toList()
                : _landmarkGroups,
            selected: _landmark,
            loading: _loadingLandmarks,
            onSelected: (l) => setState(() => _landmark = l),
          ),
          if (_landmark != null) ...[
            const SizedBox(height: 10),
            TextField(
              controller: _landmarkNote,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                hintText: 'Which part? e.g. second floor washroom (optional)',
                prefixIcon: Icon(Icons.subdirectory_arrow_right, size: 19),
                isDense: true,
              ),
            ),
          ],

          const SizedBox(height: 18),
          _EmergencyToggle(
            value: _isEmergency,
            onChanged: (v) => setState(() {
              _isEmergency = v;
              if (v) _isHostelComplaint = false;
            }),
          ),

          // Only students file hostel complaints - residents live off-campus.
          if (context.watch<Session>().role == Role.student) ...[
            const SizedBox(height: 12),
            _HostelToggle(
              value: _isHostelComplaint,
              onChanged: (v) => setState(() {
                _isHostelComplaint = v;
                if (v) _isEmergency = false;
                // A landmark picked before the toggle was on may not be a
                // hostel - clear it so the requirement is never silently
                // skipped.
                if (v && _landmark != null && !_hostelLandmarkIds.contains(_landmark!.id)) {
                  _landmark = null;
                }
              }),
            ),
          ],

          const SizedBox(height: 22),
          const _SectionLabel('3  ·  WHAT IS THE PROBLEM'),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final entry in categoryLabels.entries)
                ChoiceChip(
                  selected: _category == entry.key,
                  onSelected: (_) => setState(() => _category = entry.key),
                  avatar: Icon(
                    categoryIcons[entry.key],
                    size: 17,
                    color: _category == entry.key ? Colors.white : Palette.inkSecondary,
                  ),
                  label: Text(entry.value),
                  selectedColor: AppTheme.seed,
                  labelStyle: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: _category == entry.key ? Colors.white : Palette.inkPrimary,
                  ),
                  backgroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(9),
                    side: BorderSide(
                      color: _category == entry.key
                          ? AppTheme.seed
                          : Colors.black.withValues(alpha: 0.12),
                    ),
                  ),
                ),
            ],
          ),

          const SizedBox(height: 22),
          const _SectionLabel('4  ·  EVIDENCE  ·  REQUIRED'),
          const SizedBox(height: 4),
          const Text(
            'At least one attachment is required. Capture happens in the app so '
            'the location cannot be faked.',
            style: TextStyle(fontSize: 12.5, height: 1.35, color: Palette.inkSecondary),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _CaptureButton(
                  icon: Icons.photo_camera_outlined,
                  label: 'Photo',
                  onTap: _canAddMore ? _capturePhoto : null,
                ),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: _CaptureButton(
                  icon: Icons.videocam_outlined,
                  label: 'Video',
                  sublabel: '${AppConfig.maxVideoSeconds}s max',
                  onTap: _canAddMore ? _captureVideo : null,
                ),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: _CaptureButton(
                  icon: _recording ? Icons.stop_circle : Icons.mic_none,
                  label: _recording ? 'Stop' : 'Voice',
                  sublabel: _recording ? 'recordingâ€¦' : '${AppConfig.maxAudioSeconds}s max',
                  active: _recording,
                  onTap: (_canAddMore || _recording) ? _toggleRecording : null,
                ),
              ),
            ],
          ),

          if (_attachments.isNotEmpty) ...[
            const SizedBox(height: 14),
            SizedBox(
              height: 100,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: _attachments.length,
                separatorBuilder: (_, __) => const SizedBox(width: 9),
                itemBuilder: (_, i) => _AttachmentTile(
                  attachment: _attachments[i],
                  onRemove: () => setState(() => _attachments.removeAt(i)),
                ),
              ),
            ),
          ],

          const SizedBox(height: 22),
          const _SectionLabel('5  ·  ANYTHING ELSE'),
          const SizedBox(height: 10),
          TextField(
            controller: _description,
            maxLines: 3,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              hintText: 'Where exactly, how bad, since whenâ€¦ (optional)',
            ),
          ),

          if (_error != null) ...[
            const SizedBox(height: 18),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Palette.critical.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Palette.critical.withValues(alpha: 0.3)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.error_outline, color: Palette.critical, size: 19),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text(
                      _error!,
                      style: const TextStyle(
                          color: Palette.critical, height: 1.35, fontSize: 13.5),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// The compulsory "which building" picker.
///
/// A bottom sheet rather than a plain dropdown: twenty-odd places grouped under
/// headings is unreadable in a dropdown on a phone, and the resident needs to
/// find their hostel quickly rather than scroll a flat list.
class _LandmarkPicker extends StatelessWidget {
  final List<LandmarkGroup> groups;
  final Landmark? selected;
  final bool loading;
  final ValueChanged<Landmark> onSelected;

  const _LandmarkPicker({
    required this.groups,
    required this.selected,
    required this.loading,
    required this.onSelected,
  });

  Future<void> _open(BuildContext context) async {
    final picked = await showModalBottomSheet<Landmark>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.75,
        maxChildSize: 0.92,
        builder: (ctx, controller) => ListView(
          controller: controller,
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 28),
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
            const SizedBox(height: 18),
            const Text(
              'Where is the problem?',
              style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 18),
            for (final group in groups) ...[
              Text(
                group.label.toUpperCase(),
                style: const TextStyle(
                  fontSize: 10.5,
                  letterSpacing: 1.6,
                  fontWeight: FontWeight.w700,
                  color: Palette.inkMuted,
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final l in group.landmarks)
                    ChoiceChip(
                      selected: selected?.id == l.id,
                      onSelected: (_) => Navigator.of(ctx).pop(l),
                      label: Text(l.name),
                      selectedColor: AppTheme.seed,
                      labelStyle: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: selected?.id == l.id ? Colors.white : Palette.inkPrimary,
                      ),
                      backgroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(9),
                        side: BorderSide(
                          color: selected?.id == l.id
                              ? AppTheme.seed
                              : Colors.black.withValues(alpha: 0.12),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 20),
            ],
          ],
        ),
      ),
    );

    if (picked != null) onSelected(picked);
  }

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return Container(
        padding: const EdgeInsets.symmetric(vertical: 18),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Palette.grid),
        ),
        child: const SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2.2),
        ),
      );
    }

    final chosen = selected != null;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => _open(context),
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 15),
          decoration: BoxDecoration(
            color: chosen ? AppTheme.seed.withValues(alpha: 0.07) : Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: chosen ? AppTheme.seed : Palette.warning.withValues(alpha: 0.7),
              width: chosen ? 1.8 : 1.4,
            ),
          ),
          child: Row(
            children: [
              Icon(
                chosen ? Icons.place : Icons.add_location_alt_outlined,
                size: 21,
                color: chosen ? AppTheme.seed : Palette.warning,
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Text(
                  chosen ? selected!.name : 'Choose the nearest place',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: chosen ? FontWeight.w700 : FontWeight.w600,
                    color: chosen ? Palette.inkPrimary : Palette.warning,
                  ),
                ),
              ),
              Icon(
                chosen ? Icons.edit : Icons.chevron_right,
                size: 18,
                color: Palette.inkMuted,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Emergency reports go straight out to every officer and on-duty worker,
/// skipping the admin's verification step. Deliberately styled as a serious
/// choice rather than a convenient shortcut - the copy says exactly what
/// happens so nobody flips it to jump the queue.
class _EmergencyToggle extends StatelessWidget {
  final bool value;
  final ValueChanged<bool> onChanged;

  const _EmergencyToggle({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 10, 12),
      decoration: BoxDecoration(
        color: value ? Palette.critical.withValues(alpha: 0.10) : Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: value ? Palette.critical : Colors.black.withValues(alpha: 0.12),
          width: value ? 2 : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                value ? Icons.emergency : Icons.emergency_outlined,
                color: value ? Palette.critical : Palette.inkMuted,
                size: 22,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'This is an emergency',
                  style: TextStyle(
                    fontSize: 15.5,
                    fontWeight: FontWeight.w800,
                    color: value ? Palette.critical : Palette.inkPrimary,
                  ),
                ),
              ),
              Switch(
                value: value,
                activeThumbColor: Palette.critical,
                onChanged: onChanged,
              ),
            ],
          ),
          const SizedBox(height: 2),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Text(
              value
                  ? 'Goes out immediately to every zone officer and every worker '
                      'on duty. No admin check first â€” use this for sewage, '
                      'flooding, broken glass or anything unsafe.'
                  : 'Skips the admin check and alerts every officer and on-duty '
                      'worker at once.',
              style: TextStyle(
                fontSize: 12.5,
                height: 1.35,
                color: value ? Palette.critical : Palette.inkSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// From inside a hostel - forwards straight to the hostel's warden instead of
/// the normal officer queue, and only the warden approves the finished work.
class _HostelToggle extends StatelessWidget {
  final bool value;
  final ValueChanged<bool> onChanged;

  const _HostelToggle({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 10, 12),
      decoration: BoxDecoration(
        color: value ? AppTheme.seed.withValues(alpha: 0.08) : Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: value ? AppTheme.seed : Colors.black.withValues(alpha: 0.12),
          width: value ? 2 : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                value ? Icons.apartment : Icons.apartment_outlined,
                color: value ? AppTheme.seed : Palette.inkMuted,
                size: 22,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'This is from inside a hostel',
                  style: TextStyle(
                    fontSize: 15.5,
                    fontWeight: FontWeight.w800,
                    color: value ? AppTheme.seed : Palette.inkPrimary,
                  ),
                ),
              ),
              Switch(value: value, onChanged: onChanged),
            ],
          ),
          const SizedBox(height: 2),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Text(
              value
                  ? 'Goes straight to the hostel\'s warden instead of the usual '
                      'queue - pick which hostel below. The warden approves the '
                      'finished work, not you.'
                  : 'Tap water, washrooms, or anything inside your hostel building.',
              style: TextStyle(
                fontSize: 12.5,
                height: 1.35,
                color: value ? AppTheme.seed : Palette.inkSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;

  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) => Text(
        text,
        style: const TextStyle(
          fontSize: 10.5,
          letterSpacing: 1.8,
          fontWeight: FontWeight.w700,
          color: Palette.inkMuted,
        ),
      );
}

/// Shows the GPS state, the detected zone, and lets the resident correct the
/// zone when the fix lands on a boundary.
class _CaptureButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? sublabel;
  final bool active;
  final VoidCallback? onTap;

  const _CaptureButton({
    required this.icon,
    required this.label,
    this.sublabel,
    this.active = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final disabled = onTap == null;
    final color = active ? Palette.critical : AppTheme.seed;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 14),
          decoration: BoxDecoration(
            color: active ? Palette.critical.withValues(alpha: 0.09) : Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: disabled
                  ? Colors.black.withValues(alpha: 0.08)
                  : color.withValues(alpha: active ? 0.6 : 0.3),
              width: active ? 2 : 1,
            ),
          ),
          child: Column(
            children: [
              Icon(icon, size: 23, color: disabled ? Palette.inkMuted : color),
              const SizedBox(height: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: disabled ? Palette.inkMuted : Palette.inkPrimary,
                ),
              ),
              if (sublabel != null) ...[
                const SizedBox(height: 1),
                Text(
                  sublabel!,
                  style: const TextStyle(fontSize: 9.5, color: Palette.inkMuted),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _AttachmentTile extends StatelessWidget {
  final _Attachment attachment;
  final VoidCallback onRemove;

  const _AttachmentTile({required this.attachment, required this.onRemove});

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: attachment.type == 'PHOTO'
              ? Image.file(attachment.file, width: 100, height: 100, fit: BoxFit.cover)
              : Container(
                  width: 100,
                  height: 100,
                  color: const Color(0xFFEDF0F3),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        attachment.type == 'VIDEO' ? Icons.videocam : Icons.mic,
                        size: 26,
                        color: Palette.inkSecondary,
                      ),
                      const SizedBox(height: 5),
                      Text(
                        attachment.durationSec != null
                            ? '${attachment.durationSec}s'
                            : attachment.type.toLowerCase(),
                        style: const TextStyle(fontSize: 11, color: Palette.inkSecondary),
                      ),
                    ],
                  ),
                ),
        ),
        Positioned(
          top: 2,
          right: 2,
          child: Material(
            color: Colors.black54,
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: onRemove,
              child: const Padding(
                padding: EdgeInsets.all(4),
                child: Icon(Icons.close, size: 15, color: Colors.white),
              ),
            ),
          ),
        ),
      ],
    );
  }
}


