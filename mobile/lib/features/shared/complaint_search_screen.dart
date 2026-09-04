import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api_client.dart';
import '../../core/palette.dart';
import 'complaint_detail_screen.dart';

/// Jump straight to a complaint from its ref ("SC81713") - the way a phone
/// call actually names one - instead of hunting through whichever queue it
/// happens to be sitting in right now.
class ComplaintSearchScreen extends StatefulWidget {
  const ComplaintSearchScreen({super.key});

  @override
  State<ComplaintSearchScreen> createState() => _ComplaintSearchScreenState();
}

class _ComplaintSearchScreenState extends State<ComplaintSearchScreen> {
  final _ref = TextEditingController();
  final _focus = FocusNode();
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _focus.requestFocus());
  }

  @override
  void dispose() {
    _ref.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final ref = _ref.text.trim();
    if (ref.isEmpty) {
      setState(() => _error = 'Enter a complaint reference, e.g. SC81713');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      final res = await context.read<ApiClient>().get('/complaints/by-ref/$ref');
      if (mounted) {
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => ComplaintDetailScreen(complaintId: res['id'] as String),
          ),
        );
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
      appBar: AppBar(title: const Text('Find a complaint')),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Enter the reference code - the same one shown to the person '
              'who filed it, e.g. on a phone call.',
              style: TextStyle(fontSize: 13.5, height: 1.4, color: Palette.inkSecondary),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _ref,
              focusNode: _focus,
              autofocus: true,
              textCapitalization: TextCapitalization.characters,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _search(),
              decoration: const InputDecoration(
                labelText: 'Reference',
                hintText: 'SC81713',
                prefixIcon: Icon(Icons.tag),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: const TextStyle(color: Palette.critical, fontSize: 13)),
            ],
            const SizedBox(height: 18),
            FilledButton(
              onPressed: _busy ? null : _search,
              child: _busy
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2.2, color: Colors.white),
                    )
                  : const Text('Find'),
            ),
          ],
        ),
      ),
    );
  }
}
