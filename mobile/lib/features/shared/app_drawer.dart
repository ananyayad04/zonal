import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/models.dart';
import '../../core/palette.dart';
import '../../core/session.dart';
import '../../core/theme.dart';
import 'notifications_screen.dart';

/// Bell with an unread badge. Sits in every role's app bar.
class NotificationBell extends StatelessWidget {
  const NotificationBell({super.key});

  @override
  Widget build(BuildContext context) {
    final unread = context.watch<Session>().unreadCount;

    return Stack(
      alignment: Alignment.center,
      children: [
        IconButton(
          tooltip: 'Notifications',
          icon: const Icon(Icons.notifications_none),
          onPressed: () async {
            await Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const NotificationsScreen()),
            );
            if (context.mounted) context.read<Session>().refreshUnreadCount();
          },
        ),
        if (unread > 0)
          Positioned(
            top: 9,
            right: 8,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
              decoration: BoxDecoration(
                color: Palette.critical,
                borderRadius: BorderRadius.circular(9),
                border: Border.all(color: AppTheme.seed, width: 1.5),
              ),
              constraints: const BoxConstraints(minWidth: 17),
              child: Text(
                unread > 99 ? '99+' : '$unread',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 9.5,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class AppDrawer extends StatelessWidget {
  const AppDrawer({super.key});

  @override
  Widget build(BuildContext context) {
    final session = context.watch<Session>();
    final user = session.user;
    if (user == null) return const Drawer();

    final roleLabel = switch (user.role) {
      Role.resident => 'Resident',
      Role.student => 'Student',
      Role.worker => 'Cleaning worker',
      Role.officer => 'Zone officer',
      Role.admin => 'Campus admin',
      Role.unknown => 'Unknown',
    };

    final zone = user.zone ?? user.worker?.zone;

    return Drawer(
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.fromLTRB(20, 26, 20, 22),
              color: AppTheme.seed,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  CircleAvatar(
                    radius: 25,
                    backgroundColor: Colors.white.withValues(alpha: 0.18),
                    child: Text(
                      user.name.isEmpty ? '?' : user.name[0].toUpperCase(),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 21,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    user.name,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    user.email,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.75),
                      fontSize: 12.5,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.16),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          roleLabel.toUpperCase(),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 9.5,
                            letterSpacing: 1.1,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      if (zone != null) ...[
                        const SizedBox(width: 7),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                          decoration: BoxDecoration(
                            color: colorFromHex(zone.colorHex),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(
                            zone.name.toUpperCase(),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 9.5,
                              letterSpacing: 1.1,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            ListTile(
              leading: const Icon(Icons.notifications_none),
              title: const Text('Notifications'),
              trailing: session.unreadCount > 0
                  ? Container(
                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                      decoration: BoxDecoration(
                        color: Palette.critical,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        '${session.unreadCount}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    )
                  : null,
              onTap: () {
                Navigator.of(context).pop();
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const NotificationsScreen()),
                );
              },
            ),
            const Spacer(),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.logout, color: Palette.critical),
              title: const Text('Sign out', style: TextStyle(color: Palette.critical)),
              onTap: () async {
                Navigator.of(context).pop();
                await context.read<Session>().logout();
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}
