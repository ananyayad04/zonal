import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'core/api_client.dart';
import 'core/models.dart';
import 'core/session.dart';
import 'core/theme.dart';
import 'features/auth/login_screen.dart';
import 'features/admin/admin_home.dart';
import 'features/officer/officer_home.dart';
import 'features/officer/officer_pending_screen.dart';
import 'features/resident/resident_home.dart';
import 'features/worker/worker_home.dart';
import 'features/supervisor/supervisor_home.dart';
import 'features/warden/warden_home.dart';

import 'core/config.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Restore a saved server address before the first request goes out.
  await AppConfig.load();
  runApp(const ZonalApp());
}

class ZonalApp extends StatelessWidget {
  const ZonalApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        Provider<ApiClient>(create: (_) => ApiClient()),
        ChangeNotifierProvider<Session>(
          create: (ctx) => Session(ctx.read<ApiClient>())..restore(),
        ),
      ],
      child: MaterialApp(
        title: 'Smart Clean Campus',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light(),
        home: const _RoleRouter(),
      ),
    );
  }
}

/// Sends each account to its own app. Four roles, four completely different
/// home screens - the same binary serves all of them.
class _RoleRouter extends StatelessWidget {
  const _RoleRouter();

  @override
  Widget build(BuildContext context) {
    final session = context.watch<Session>();

    if (session.isRestoring) {
      return const Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.cleaning_services, size: 56, color: AppTheme.seed),
              SizedBox(height: 20),
              CircularProgressIndicator(),
            ],
          ),
        ),
      );
    }

    if (!session.isLoggedIn) return const LoginScreen();

    return switch (session.role) {
      // Students and residents get the same screens. They differ only in
      // which community feed their complaints appear in, which the server
      // decides from the account.
      Role.resident || Role.student => const ResidentHome(),
      Role.worker => const WorkerHome(),
      // An officer who has not been appointed yet owns no zone, and the
      // dashboard assumes one throughout. Send them to the waiting screen
      // instead of a dashboard that would read as broken.
      Role.officer => session.user?.awaitingVerification == true
          ? const OfficerPendingScreen()
          : const OfficerHome(),
      Role.admin => const AdminHome(),
      // Created directly by the Admin, always active immediately - no
      // "awaiting verification" variant needed for either.
      Role.workerSupervisor => const SupervisorHome(),
      Role.warden => const WardenHome(),
      Role.unknown => const _UnknownRole(),
    };
  }
}

class _UnknownRole extends StatelessWidget {
  const _UnknownRole();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 48, color: Colors.redAccent),
              const SizedBox(height: 16),
              const Text(
                'This account has no recognised role.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 16),
              ),
              const SizedBox(height: 20),
              OutlinedButton(
                onPressed: () => context.read<Session>().logout(),
                child: const Text('Sign out'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
