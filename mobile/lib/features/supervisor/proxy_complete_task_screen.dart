import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../../core/api_client.dart';
import '../../core/config.dart';
import '../../core/location_service.dart';
import '../../core/models.dart';
import '../../core/palette.dart';
import '../../shared/authed_image.dart';
import '../../shared/ui.dart';

/// The supervisor completes a worker's task on their behalf - same proof-of-
/// work requirement as the worker's own CompleteTaskScreen, since a worker
/// with no phone at all still needs an after-photo for the reporter to judge.
/// The supervisor's own location is captured as the after-photo's location,
/// same as it would be for the worker taking it themselves.
class ProxyCompleteTaskScreen extends StatefulWidget {
  final Complaint complaint;

  const ProxyCompleteTaskScreen({super.key, required this.complaint});

  @override
  State<ProxyCompleteTaskScreen> createState() => _ProxyCompleteTaskScreenState();
}

class _ProxyCompleteTaskScreenState extends State<ProxyCompleteTaskScreen> {
  final _note = TextEditingController();
  final List<File> _photos = [];

  GeoFix? _fix;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _acquireLocation();
  }

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _acquireLocation() async {
    try {
      final fix = await LocationService.current();
      if (mounted) setState(() => _fix = fix);
    } catch (_) {
      // Not blocking - the complaint's own coordinates are the fallback.
    }
  }

  Future<void> _capture() async {
    if (_photos.length >= AppConfig.maxAttachments) return;
    final picked = await ImagePicker().pickImage(
      source: ImageSource.camera,
      imageQuality: 75,
      maxWidth: 1920,
    );
    if (picked != null && mounted) setState(() => _photos.add(File(picked.path)));
  }

  Future<void> _submit() async {
    if (_photos.isEmpty) {
      setState(() => _error = 'Take at least one photo of the finished work');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      final meta = _photos
          .map((_) => {
                if (_fix != null) 'lat': _fix!.lat,
                if (_fix != null) 'lng': _fix!.lng,
                if (_fix != null) 'capturedAt': _fix!.at.toIso8601String(),
              })
          .toList();

      final res = await context.read<ApiClient>().upload(
        '/admin/complaints/${widget.complaint.id}/complete-for-worker',
        fields: {
          if (_note.text.trim().isNotEmpty) 'note': _note.text.trim(),
          'mediaMeta': jsonEncode(meta),
        },
        files: _photos,
      );

      if (mounted) {
        Navigator.of(context).pop(true);
        showSnack(context, res['message'] as String? ?? 'Marked done');
      }
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final worker = widget.complaint.worker?.name ?? 'the worker';

    return Scaffold(
      appBar: AppBar(title: Text('Finish ${widget.complaint.ref}')),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
          child: FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Palette.good),
            onPressed: _busy || _photos.isEmpty ? null : _submit,
            child: _busy
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2.2, color: Colors.white),
                  )
                : const Text('Mark done'),
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 20),
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Palette.inkPrimary.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                const Icon(Icons.info_outline, size: 17, color: Palette.inkSecondary),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    'You are completing this on behalf of $worker, using your own '
                    'camera for the proof photo.',
                    style: const TextStyle(fontSize: 12.5, height: 1.35, color: Palette.inkSecondary),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),

          if (widget.complaint.beforeMedia.where((m) => m.type == 'PHOTO').isNotEmpty) ...[
            const Text(
              'WHAT WAS REPORTED',
              style: TextStyle(
                fontSize: 10.5,
                letterSpacing: 1.8,
                fontWeight: FontWeight.w700,
                color: Palette.inkMuted,
              ),
            ),
            const SizedBox(height: 10),
            SizedBox(
              height: 130,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: widget.complaint.beforeMedia.where((m) => m.type == 'PHOTO').length,
                separatorBuilder: (_, __) => const SizedBox(width: 9),
                itemBuilder: (_, i) => AuthedImage(
                  path: widget.complaint.beforeMedia.where((m) => m.type == 'PHOTO').toList()[i].url,
                  width: 165,
                  height: 130,
                  borderRadius: BorderRadius.circular(11),
                ),
              ),
            ),
            const SizedBox(height: 24),
          ],

          const Text(
            'PHOTO OF THE FINISHED WORK',
            style: TextStyle(
              fontSize: 10.5,
              letterSpacing: 1.8,
              fontWeight: FontWeight.w700,
              color: Palette.inkMuted,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'Required. The resident compares this with the original photo before '
            'they close the complaint.',
            style: TextStyle(fontSize: 12.5, height: 1.35, color: Palette.inkSecondary),
          ),
          const SizedBox(height: 12),

          if (_photos.isNotEmpty) ...[
            SizedBox(
              height: 130,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: _photos.length,
                separatorBuilder: (_, __) => const SizedBox(width: 9),
                itemBuilder: (_, i) => Stack(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(11),
                      child: Image.file(_photos[i], width: 165, height: 130, fit: BoxFit.cover),
                    ),
                    Positioned(
                      top: 4,
                      right: 4,
                      child: Material(
                        color: Colors.black54,
                        shape: const CircleBorder(),
                        child: InkWell(
                          customBorder: const CircleBorder(),
                          onTap: () => setState(() => _photos.removeAt(i)),
                          child: const Padding(
                            padding: EdgeInsets.all(4),
                            child: Icon(Icons.close, size: 16, color: Colors.white),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
          ],

          OutlinedButton.icon(
            onPressed: _photos.length >= AppConfig.maxAttachments ? null : _capture,
            icon: const Icon(Icons.photo_camera_outlined),
            label: Text(_photos.isEmpty ? 'Take photo' : 'Add another photo'),
          ),

          const SizedBox(height: 22),
          const Text(
            'NOTE',
            style: TextStyle(
              fontSize: 10.5,
              letterSpacing: 1.8,
              fontWeight: FontWeight.w700,
              color: Palette.inkMuted,
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _note,
            maxLines: 3,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              hintText: 'Anything the resident or officer should know (optional)',
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
                      style: const TextStyle(color: Palette.critical, height: 1.35, fontSize: 13.5),
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
