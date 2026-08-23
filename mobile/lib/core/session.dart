import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api_client.dart';
import 'models.dart';

/// Holds the logged-in user and the auth token, and is the single place the
/// rest of the app talks to the API through.
class Session extends ChangeNotifier {
  Session(this.api);

  final ApiClient api;

  static const _tokenKey = 'zonal.token';

  AppUser? _user;
  bool _restoring = true;
  int _unread = 0;

  AppUser? get user => _user;
  bool get isRestoring => _restoring;
  bool get isLoggedIn => _user != null;
  Role get role => _user?.role ?? Role.unknown;
  int get unreadCount => _unread;

  /// Reload a saved session on app launch.
  Future<void> restore() async {
    _restoring = true;
    notifyListeners();

    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(_tokenKey);

      if (saved != null && saved.isNotEmpty) {
        api.token = saved;
        final res = await api.get('/auth/me');
        _user = AppUser.fromJson(res['user'] as Map<String, dynamic>);
        _unread = res['unreadNotifications'] as int? ?? 0;
      }
    } catch (_) {
      // Expired or invalid token - fall back to the login screen.
      await _clearToken();
      _user = null;
    } finally {
      _restoring = false;
      notifyListeners();
    }
  }

  Future<void> login(String email, String password) async {
    final res = await api.post('/auth/login', {'email': email, 'password': password});
    await _applyAuth(res);
  }

  Future<String> register({
    required String name,
    required String email,
    required String password,
    String? phone,
    required Role role,
    int? zoneCode,
    File? idProof,
  }) async {
    final fields = <String, String>{
      'name': name,
      'email': email,
      'password': password,
      'role': switch (role) {
        Role.worker => 'WORKER',
        Role.officer => 'OFFICER',
        Role.student => 'STUDENT',
        _ => 'RESIDENT',
      },
      if (phone != null && phone.isNotEmpty) 'phone': phone,
      if (zoneCode != null) 'zoneCode': '$zoneCode',
    };

    final res = await api.upload(
      '/auth/register',
      fields: fields,
      files: idProof != null ? [idProof] : const [],
      fileField: 'idProof',
    );

    await _applyAuth(res);
    return res['message'] as String? ?? 'Registered';
  }

  Future<void> _applyAuth(Map<String, dynamic> res) async {
    final token = res['token'] as String;
    api.token = token;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_tokenKey, token);

    _user = AppUser.fromJson(res['user'] as Map<String, dynamic>);
    notifyListeners();
  }

  /// Re-pull the user - used after a worker's duty toggle or admin approval so
  /// the UI reflects their new state without a full re-login.
  Future<void> refreshUser() async {
    if (!isLoggedIn) return;
    try {
      final res = await api.get('/auth/me');
      _user = AppUser.fromJson(res['user'] as Map<String, dynamic>);
      _unread = res['unreadNotifications'] as int? ?? 0;
      notifyListeners();
    } on ApiException catch (e) {
      if (e.isAuthError) await logout();
    }
  }

  Future<void> refreshUnreadCount() async {
    if (!isLoggedIn) return;
    try {
      final res = await api.get('/notifications');
      _unread = res['unread'] as int? ?? 0;
      notifyListeners();
    } catch (_) {
      // Badge count is cosmetic - never surface a failure for it.
    }
  }

  Future<void> logout() async {
    await _clearToken();
    _user = null;
    _unread = 0;
    notifyListeners();
  }

  Future<void> _clearToken() async {
    api.token = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_tokenKey);
  }
}
