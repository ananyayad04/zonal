import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api_client.dart';
import '../../core/models.dart';
import '../../core/palette.dart';
import '../../core/session.dart';
import '../../shared/complaint_card.dart';
import '../../shared/ui.dart';
import '../shared/complaint_detail_screen.dart';

/// Approved complaints from the viewer's own community.
///
/// Residents see what residents reported; students see what students
/// reported; neither sees the other. The split is enforced by the server on
/// the complaint's snapshotted reporter role — this screen only asks for
/// "mine", and gets back whichever community the account belongs to.
class CommunityScreen extends StatefulWidget {
  const CommunityScreen({super.key});

  @override
  State<CommunityScreen> createState() => _CommunityScreenState();
}

class _CommunityScreenState extends State<CommunityScreen> {
  late Future<List<Complaint>> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<List<Complaint>> _load() async {
    final res = await context.read<ApiClient>().get('/complaints/community');
    return (res['complaints'] as List)
        .map((c) => Complaint.fromJson(c as Map<String, dynamic>))
        .toList();
  }

  Future<void> _refresh() async {
    setState(() => _future = _load());
    await _future;
  }

  @override
  Widget build(BuildContext context) {
    final isStudent = context.watch<Session>().role == Role.student;
    final community = isStudent ? 'students' : 'residents';

    return Scaffold(
      appBar: AppBar(title: Text(isStudent ? 'Student reports' : 'Resident reports')),
      body: FutureBuilder<List<Complaint>>(
        future: _future,
        builder: (context, snapshot) => AsyncBody<List<Complaint>>(
          snapshot: snapshot,
          onRetry: _refresh,
          builder: (complaints) {
            if (complaints.isEmpty) {
              return EmptyState(
                icon: Icons.groups_outlined,
                title: 'Nothing reported yet',
                subtitle: 'Complaints from other $community appear here once '
                    'the admin has checked them.',
              );
            }

            return RefreshIndicator(
              onRefresh: _refresh,
              child: ListView.builder(
                padding: const EdgeInsets.only(top: 8, bottom: 24),
                itemCount: complaints.length + 1,
                itemBuilder: (_, i) {
                  if (i == 0) {
                    return Padding(
                      padding: const EdgeInsets.fromLTRB(18, 6, 18, 12),
                      child: Text(
                        'What other $community have reported around campus. '
                        'Only approved complaints appear here.',
                        style: const TextStyle(
                          fontSize: 12.5,
                          height: 1.4,
                          color: Palette.inkSecondary,
                        ),
                      ),
                    );
                  }

                  final c = complaints[i - 1];
                  return ComplaintCard(
                    complaint: c,
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => ComplaintDetailScreen(complaintId: c.id),
                      ),
                    ),
                  );
                },
              ),
            );
          },
        ),
      ),
    );
  }
}
