import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

import 'config.dart';

/// Content type for an upload, worked out from the file extension.
///
/// `MultipartFile.fromPath` does not sniff the file - without this every
/// upload is sent as `application/octet-stream`, which the server rejects
/// because it cannot tell a photo from a voice note.
MediaType? contentTypeFor(String path) {
  final dot = path.lastIndexOf('.');
  if (dot == -1) return null;

  return switch (path.substring(dot + 1).toLowerCase()) {
    'jpg' || 'jpeg' => MediaType('image', 'jpeg'),
    'png' => MediaType('image', 'png'),
    'webp' => MediaType('image', 'webp'),
    'heic' => MediaType('image', 'heic'),
    'mp4' => MediaType('video', 'mp4'),
    'mov' => MediaType('video', 'quicktime'),
    'webm' => MediaType('video', 'webm'),
    'm4a' => MediaType('audio', 'mp4'),
    'aac' => MediaType('audio', 'aac'),
    'wav' => MediaType('audio', 'wav'),
    'mp3' => MediaType('audio', 'mpeg'),
    _ => null,
  };
}

/// Error carrying the message the API actually sent, so the UI can show the
/// real reason ("Ramesh is already on another task") instead of a generic
/// failure.
class ApiException implements Exception {
  final int statusCode;
  final String message;
  final Map<String, dynamic>? details;

  ApiException(this.statusCode, this.message, [this.details]);

  bool get isAuthError => statusCode == 401;

  @override
  String toString() => message;
}

class ApiClient {
  ApiClient();

  /// Set by [Session] on login and cleared on logout.
  String? token;

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        if (token != null) 'Authorization': 'Bearer $token',
      };

  Uri _uri(String path, [Map<String, dynamic>? query]) {
    final cleaned = query?.map((k, v) => MapEntry(k, v?.toString()))
      ?..removeWhere((_, v) => v == null);
    return Uri.parse('${AppConfig.apiUrl}$path').replace(
      queryParameters: cleaned?.isEmpty ?? true ? null : cleaned?.cast<String, String>(),
    );
  }

  Map<String, dynamic> _decode(http.Response res) {
    late final dynamic body;
    try {
      body = res.body.isEmpty ? <String, dynamic>{} : jsonDecode(res.body);
    } catch (_) {
      throw ApiException(res.statusCode, 'Server returned an unreadable response');
    }

    final map = body is Map<String, dynamic> ? body : <String, dynamic>{'data': body};

    if (res.statusCode >= 400) {
      throw ApiException(
        res.statusCode,
        map['error'] as String? ?? 'Request failed (${res.statusCode})',
        map['details'] as Map<String, dynamic>?,
      );
    }
    return map;
  }

  Future<T> _guard<T>(Future<T> Function() run) async {
    try {
      return await run();
    } on SocketException {
      // Always name the address that failed. Without it this message sent
      // people hunting for a USB problem while the app was quietly pointed at
      // a stale server saved during an earlier session.
      final url = AppConfig.baseUrl;
      final local = url.contains('localhost') || url.contains('127.0.0.1');

      throw ApiException(
        0,
        'Cannot reach the server at\n$url\n\n${local ? 'That is this phone itself. Tap the server address below '
                'and enter the real one, or run:\n'
                'adb reverse tcp:4000 tcp:4000' : 'Tap the server address below to change it, or check '
                'that you have internet.'}',
      );
    } on HttpException {
      throw ApiException(0, 'Network error. Check that the backend is running.');
    }
  }

  Future<Map<String, dynamic>> get(String path, {Map<String, dynamic>? query}) =>
      _guard(() async => _decode(await http.get(_uri(path, query), headers: _headers)));

  Future<Map<String, dynamic>> put(String path, [Map<String, dynamic>? body]) =>
      _guard(() async => _decode(
            await http.put(
              _uri(path),
              headers: _headers,
              body: jsonEncode(body ?? const {}),
            ),
          ));

  Future<Map<String, dynamic>> post(String path, [Map<String, dynamic>? body]) =>
      _guard(() async => _decode(
            await http.post(
              _uri(path),
              headers: _headers,
              body: jsonEncode(body ?? const {}),
            ),
          ));

  Future<Map<String, dynamic>> delete(String path) =>
      _guard(() async => _decode(await http.delete(_uri(path), headers: _headers)));

  /// Multipart upload used by complaint filing and proof-of-work.
  ///
  /// [files] are attached under the given field name; [fields] carries the
  /// text payload (category, lat/lng, mediaMeta JSON, ...).
  Future<Map<String, dynamic>> upload(
    String path, {
    required Map<String, String> fields,
    List<File> files = const [],
    String fileField = 'media',
  }) =>
      _guard(() async {
        final request = http.MultipartRequest('POST', _uri(path));
        if (token != null) request.headers['Authorization'] = 'Bearer $token';
        request.fields.addAll(fields);

        for (final file in files) {
          request.files.add(
            await http.MultipartFile.fromPath(
              fileField,
              file.path,
              contentType: contentTypeFor(file.path),
            ),
          );
        }

        final streamed = await request.send();
        return _decode(await http.Response.fromStream(streamed));
      });
}

