import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../core/api_client.dart';
import '../core/theme.dart';

/// Small shared widgets used across all four role apps.

class StatusChip extends StatelessWidget {
  final String status;
  final bool compact;

  const StatusChip(this.status, {super.key, this.compact = false});

  @override
  Widget build(BuildContext context) {
    final style = StatusStyle.of(status);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: compact ? 8 : 10, vertical: compact ? 4 : 6),
      decoration: BoxDecoration(
        color: style.color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(style.icon, size: compact ? 13 : 15, color: style.color),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              style.label,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: style.color,
                fontSize: compact ? 11 : 12.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class ZoneChip extends StatelessWidget {
  final String name;
  final String colorHex;

  const ZoneChip({super.key, required this.name, required this.colorHex});

  @override
  Widget build(BuildContext context) {
    final color = colorFromHex(colorHex);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.22),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.6)),
      ),
      child: Text(
        name,
        style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700),
      ),
    );
  }
}

/// Coloured banner used for the "you must do something" callouts.
class InfoBanner extends StatelessWidget {
  final String text;
  final IconData icon;
  final Color color;

  const InfoBanner({
    super.key,
    required this.text,
    this.icon = Icons.info_outline,
    this.color = const Color(0xFF2980B9),
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(text, style: TextStyle(color: color.withValues(alpha: 0.95), height: 1.35)),
          ),
        ],
      ),
    );
  }
}

class EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;

  const EmptyState({super.key, required this.icon, required this.title, this.subtitle});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 52, color: Colors.grey.shade400),
            const SizedBox(height: 14),
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: Colors.grey.shade700,
              ),
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 6),
              Text(
                subtitle!,
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey.shade600, height: 1.4),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Standard async body: spinner, error with retry, or content.
class AsyncBody<T> extends StatelessWidget {
  final AsyncSnapshot<T> snapshot;
  final Widget Function(T data) builder;
  final Future<void> Function()? onRetry;

  const AsyncBody({
    super.key,
    required this.snapshot,
    required this.builder,
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    if (snapshot.connectionState == ConnectionState.waiting) {
      return const Center(child: CircularProgressIndicator());
    }

    if (snapshot.hasError) {
      final err = snapshot.error;
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off, size: 46, color: Colors.redAccent),
              const SizedBox(height: 14),
              Text(
                err is ApiException ? err.message : 'Something went wrong',
                textAlign: TextAlign.center,
                style: const TextStyle(height: 1.4),
              ),
              if (onRetry != null) ...[
                const SizedBox(height: 18),
                OutlinedButton.icon(
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Try again'),
                ),
              ],
            ],
          ),
        ),
      );
    }

    if (!snapshot.hasData) return const SizedBox.shrink();
    return builder(snapshot.data as T);
  }
}

String formatDateTime(DateTime? dt) =>
    dt == null ? '-' : DateFormat('d MMM, h:mm a').format(dt);

String timeAgo(DateTime? dt) {
  if (dt == null) return '-';
  final diff = DateTime.now().difference(dt);
  if (diff.inSeconds < 60) return 'just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
  if (diff.inHours < 24) return '${diff.inHours}h ago';
  if (diff.inDays < 7) return '${diff.inDays}d ago';
  return DateFormat('d MMM').format(dt);
}

String formatDuration(int? minutes) {
  if (minutes == null) return '-';
  if (minutes < 60) return '${minutes}m';
  final h = minutes ~/ 60;
  final m = minutes % 60;
  return m == 0 ? '${h}h' : '${h}h ${m}m';
}

/// A live-style countdown to a deadline, scaling to days for the multi-day
/// task durations an officer or admin can now set. `formatDuration` stays
/// minutes-only for analytics averages, which never run to days.
String? formatCountdown(DateTime? dueAt) {
  if (dueAt == null) return null;
  final diff = dueAt.difference(DateTime.now());
  if (diff.isNegative) {
    final overdue = diff.abs();
    if (overdue.inDays > 0) return 'Overdue by ${overdue.inDays}d';
    if (overdue.inHours > 0) return 'Overdue by ${overdue.inHours}h';
    return 'Overdue by ${overdue.inMinutes}m';
  }
  if (diff.inDays > 0) return '${diff.inDays}d ${diff.inHours % 24}h left';
  if (diff.inHours > 0) return '${diff.inHours}h ${diff.inMinutes % 60}m left';
  return '${diff.inMinutes}m left';
}

/// One-line error/success feedback.
void showSnack(BuildContext context, String message, {bool error = false}) {
  if (!context.mounted) return;
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: error ? Colors.red.shade700 : AppTheme.accent,
        behavior: SnackBarBehavior.floating,
        duration: Duration(seconds: error ? 5 : 3),
      ),
    );
}
