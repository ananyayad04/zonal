import 'dart:async';

import 'package:flutter/material.dart';

import '../core/models.dart';
import '../core/palette.dart';
import '../core/theme.dart';
import 'authed_image.dart';
import 'ui.dart';

/// The complaint row used everywhere.
///
/// The left edge carries the zone's colour - the one place zone identity is
/// expressed as colour in a list - and the zone name is always printed beside
/// it, so the colour is never doing the work alone.
class ComplaintCard extends StatelessWidget {
  final Complaint complaint;
  final VoidCallback? onTap;
  final Widget? trailing;

  /// Extra row under the summary - used for the officer's Allot button and
  /// the resident's confirm/reject pair.
  final Widget? action;

  /// Show who filed it - Resident or Student. Staff screens turn this on so a
  /// student report can be told from a resident one without opening it. The
  /// community feeds leave it off: everything there is from one community
  /// already, so a badge on every row would say nothing.
  final bool showReporterKind;

  const ComplaintCard({
    super.key,
    required this.complaint,
    this.onTap,
    this.trailing,
    this.action,
    this.showReporterKind = false,
  });

  @override
  Widget build(BuildContext context) {
    final zoneColor = colorFromHex(complaint.zone?.colorHex ?? '#0072B2');
    final thumb = complaint.beforeMedia.where((m) => m.type == 'PHOTO').firstOrNull;

    return Card(
      clipBehavior: Clip.antiAlias,
      shape: complaint.isEmergency
          ? RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
              side: const BorderSide(color: Palette.critical, width: 2),
            )
          : null,
      child: InkWell(
        onTap: onTap,
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Emergencies take over the zone stripe - the urgency outranks
              // the zone identity here.
              Container(
                width: 5,
                color: complaint.isEmergency ? Palette.critical : zoneColor,
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(13, 12, 13, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (complaint.isEmergency) ...[
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 7, vertical: 3),
                              decoration: BoxDecoration(
                                color: Palette.critical,
                                borderRadius: BorderRadius.circular(5),
                              ),
                              child: const Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.emergency, size: 11, color: Colors.white),
                                  SizedBox(width: 4),
                                  Text(
                                    'EMERGENCY',
                                    style: TextStyle(
                                      fontSize: 9.5,
                                      letterSpacing: 0.9,
                                      fontWeight: FontWeight.w800,
                                      color: Colors.white,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 7),
                      ],
                      if (showReporterKind &&
                          reporterRoles.contains(complaint.reporterRole)) ...[
                        _ReporterKindBadge(role: complaint.reporterRole),
                        const SizedBox(height: 7),
                      ],
                      Row(
                        children: [
                          Text(
                            complaint.ref,
                            style: const TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.4,
                              color: Palette.inkSecondary,
                            ),
                          ),
                          const SizedBox(width: 8),
                          if (complaint.zone != null)
                            Expanded(
                              child: Text(
                                complaint.zone!.name,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: Palette.inkMuted,
                                ),
                              ),
                            )
                          else
                            const Spacer(),
                          if (complaint.isOverdue)
                            const Padding(
                              padding: EdgeInsets.only(left: 6),
                              child: Icon(Icons.schedule,
                                  size: 15, color: Palette.critical),
                            ),
                        ],
                      ),
                      const SizedBox(height: 7),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (thumb != null) ...[
                            AuthedImage(
                              path: thumb.url,
                              width: 52,
                              height: 52,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            const SizedBox(width: 11),
                          ],
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Icon(
                                      categoryIcons[complaint.category] ?? Icons.more_horiz,
                                      size: 15,
                                      color: Palette.inkSecondary,
                                    ),
                                    const SizedBox(width: 5),
                                    Expanded(
                                      child: Text(
                                        categoryLabels[complaint.category] ??
                                            complaint.category,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontSize: 14.5,
                                          fontWeight: FontWeight.w700,
                                          color: Palette.inkPrimary,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                // Where to walk to. More useful to a worker
                                // than anything else on this card.
                                if (complaint.landmark != null) ...[
                                  const SizedBox(height: 4),
                                  Row(
                                    children: [
                                      const Icon(Icons.place,
                                          size: 13, color: AppTheme.seed),
                                      const SizedBox(width: 4),
                                      Expanded(
                                        child: Text(
                                          complaint.landmarkNote?.isNotEmpty ?? false
                                              ? '${complaint.landmark} · ${complaint.landmarkNote}'
                                              : complaint.landmark!,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            fontSize: 12.5,
                                            fontWeight: FontWeight.w700,
                                            color: AppTheme.seed,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                                if (complaint.description?.isNotEmpty ?? false) ...[
                                  const SizedBox(height: 3),
                                  Text(
                                    complaint.description!,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 12.5,
                                      height: 1.3,
                                      color: Palette.inkSecondary,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                          if (trailing != null) trailing!,
                        ],
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(child: StatusChip(complaint.status, compact: true)),
                          const SizedBox(width: 8),
                          Text(
                            timeAgo(complaint.submittedAt),
                            style: const TextStyle(fontSize: 11, color: Palette.inkMuted),
                          ),
                        ],
                      ),
                      // Shown at the point of decision: an officer allotting
                      // this needs to know the spot was cleaned days ago, or
                      // they will just send someone to clean it again.
                      if (complaint.isRecurrence) ...[
                        const SizedBox(height: 7),
                        Row(
                          children: [
                            const Icon(Icons.replay, size: 14, color: Palette.warning),
                            const SizedBox(width: 5),
                            Expanded(
                              child: Text(
                                'Cleaned ${complaint.recurrenceDays} days ago and dirty again',
                                style: const TextStyle(
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w600,
                                  color: Palette.warning,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                      if (complaint.isCrossZone) ...[
                        const SizedBox(height: 7),
                        Row(
                          children: [
                            const Icon(Icons.handshake_outlined,
                                size: 14, color: Color(0xFF7A52CC)),
                            const SizedBox(width: 5),
                            Text(
                              'Worker borrowed from ${complaint.lendingZone?.name ?? 'another zone'}',
                              style: const TextStyle(
                                fontSize: 11.5,
                                fontWeight: FontWeight.w600,
                                color: Color(0xFF7A52CC),
                              ),
                            ),
                          ],
                        ),
                      ],
                      // What to cover and how long is left - set by whoever
                      // allotted this, shown to whoever is looking at it.
                      if (complaint.workInstructions?.isNotEmpty ?? false) ...[
                        const SizedBox(height: 7),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Icon(Icons.notes, size: 14, color: AppTheme.seed),
                            const SizedBox(width: 5),
                            Expanded(
                              child: Text(
                                complaint.workInstructions!,
                                style: const TextStyle(
                                  fontSize: 12,
                                  height: 1.3,
                                  fontWeight: FontWeight.w600,
                                  color: AppTheme.seed,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                      if (complaint.slaDueAt != null &&
                          !_terminalStatuses.contains(complaint.status)) ...[
                        const SizedBox(height: 7),
                        _CountdownRow(
                          dueAt: complaint.slaDueAt!,
                          overdue: complaint.isOverdue,
                        ),
                      ],
                      if (action != null) ...[
                        const SizedBox(height: 11),
                        action!,
                      ],
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

extension _FirstOrNull<E> on Iterable<E> {
  E? get firstOrNull => isEmpty ? null : first;
}

const _terminalStatuses = {'CLOSED', 'AUTO_CLOSED', 'REJECTED_INVALID'};

/// A ticking "Xd Yh left" / "Overdue by Xh" row. Recomputes once a minute -
/// day/hour-scale deadlines never need finer than that.
class _CountdownRow extends StatefulWidget {
  final DateTime dueAt;
  final bool overdue;

  const _CountdownRow({required this.dueAt, required this.overdue});

  @override
  State<_CountdownRow> createState() => _CountdownRowState();
}

class _CountdownRowState extends State<_CountdownRow> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = formatCountdown(widget.dueAt);
    if (text == null) return const SizedBox.shrink();
    final color = widget.overdue ? Palette.critical : Palette.inkMuted;
    return Row(
      children: [
        Icon(Icons.timer_outlined, size: 14, color: color),
        const SizedBox(width: 5),
        Text(
          text,
          style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: color),
        ),
      ],
    );
  }
}

/// Says whether a complaint came from the resident community or the student
/// one. Shown only to staff, who work both.
class _ReporterKindBadge extends StatelessWidget {
  const _ReporterKindBadge({required this.role});

  final Role role;

  @override
  Widget build(BuildContext context) {
    final isStudent = role == Role.student;
    // Two of the colourblind-safe hues, kept distinct from the status colours
    // so a badge is never mistaken for a state.
    final color = isStudent ? const Color(0xFF7A52CC) : const Color(0xFF0072B2);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isStudent ? Icons.school_outlined : Icons.home_outlined,
            size: 11,
            color: color,
          ),
          const SizedBox(width: 4),
          Text(
            isStudent ? 'STUDENT' : 'RESIDENT',
            style: TextStyle(
              fontSize: 9.5,
              letterSpacing: 0.9,
              fontWeight: FontWeight.w800,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}
