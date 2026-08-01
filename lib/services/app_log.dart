import 'dart:collection';
import 'dart:io' show Platform;
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../config/local_first_sync_config.dart';

/// How an operation ended.
///
/// Deliberately coarser than an HTTP status: the useful question when reading
/// logs back is "will this retry", not "which 4xx was it".
enum LogResult { ok, transient, permanent, skipped, unknown }

/// Structured, redacted diagnostics (task brief phase 8).
///
/// Two properties matter more than the field list:
///
/// 1. **Redaction happens here, not at the call site.** Every key and every
///    value passes through [_redact] before it can reach a sink. A call site
///    that hands over a whole response map cannot leak a token by forgetting,
///    which is the failure mode a "never log secrets" convention actually has.
/// 2. **Retention is bounded.** Release builds keep the last
///    [_bufferLimit] events in memory for in-app support and print nothing.
///
/// Correlation: [begin] mints an id that is echoed to WordPress in the
/// `X-Qtoys-Request-Id` header (see [correlationHeader]), so one identifier
/// spans the Flutter call and the plugin that served it.
class AppLog {
  AppLog._();

  /// Header carrying [OperationLog.correlationId] to the server.
  static const String correlationHeader = 'X-Qtoys-Request-Id';

  static const int _bufferLimit = 200;
  static const int _maxValueLength = 200;

  static final Queue<String> _recent = Queue<String>();
  static final Random _random = Random();

  static String _appVersion = 'unknown';
  static String? _role;

  /// Anonymous per-install id. Never derived from the account, so it cannot be
  /// used to re-identify a user from logs alone.
  static final String _sessionId = _randomId(8);

  /// Called once from `main`.
  static void configure({required String appVersion}) {
    _appVersion = appVersion;
  }

  /// Role is worth having on every event; identity is not.
  static void setRole(String? role) => _role = role;

  /// Events retained in this process, oldest first. For an in-app diagnostics
  /// screen or a support export — already redacted.
  static List<String> get recent => List.unmodifiable(_recent);

  static void clearForTest() => _recent.clear();

  /// Starts a timed operation. Call [OperationLog.end] to emit it.
  static OperationLog begin(String operation, {Map<String, Object?>? fields}) {
    return OperationLog._(
      operation: operation,
      correlationId: _randomId(12),
      startedAt: DateTime.now(),
      opening: fields,
    );
  }

  /// One-off event with no duration.
  static void event(
    String operation, {
    LogResult result = LogResult.ok,
    Map<String, Object?>? fields,
  }) {
    _emit(_format(
      operation: operation,
      correlationId: _randomId(12),
      result: result,
      fields: fields,
    ));
  }

  static String _format({
    required String operation,
    required String correlationId,
    required LogResult result,
    Duration? duration,
    Map<String, Object?>? fields,
  }) {
    final parts = <String>[
      'op=$operation',
      'cid=$correlationId',
      'result=${result.name}',
      if (duration != null) 'ms=${duration.inMilliseconds}',
      'sid=$_sessionId',
      'ver=$_appVersion',
      'plat=${_platform()}',
      if (_role != null) 'role=$_role',
    ];

    if (fields != null) {
      for (final entry in fields.entries) {
        parts.add('${_safeKey(entry.key)}=${_redact(entry.key, entry.value)}');
      }
    }
    return parts.join(' ');
  }

  static void _emit(String line) {
    _recent.addLast(line);
    while (_recent.length > _bufferLimit) {
      _recent.removeFirst();
    }
    // Release builds retain but do not print: console output on a shipped app
    // is readable over USB and buys nothing.
    if (LocalFirstSyncConfig.diagnosticsEnabled) {
      debugPrint('[App] $line');
    }
  }

  static String _platform() {
    try {
      return '${Platform.operatingSystem}/${Platform.operatingSystemVersion}';
    } catch (_) {
      return 'unknown';
    }
  }

  // ------------------------------------------------------------- redaction

  /// Field names whose value is never safe to record, matched as substrings so
  /// `new_password`, `cart_token` and `HTTP_AUTHORIZATION` are all caught.
  static const List<String> _forbiddenKeyParts = <String>[
    'password',
    'passwd',
    'secret',
    'token',
    'jwt',
    'authorization',
    'auth',
    'cookie',
    'nonce',
    'credential',
    'consumer_key',
    'apikey',
    'api_key',
    'session',
    'card',
    'cvv',
    'otp',
    'code',
  ];

  /// A JWT anywhere inside a value, e.g. an error string that quoted a header.
  static final RegExp _jwtLike =
      RegExp(r'eyJ[A-Za-z0-9_-]{4,}\.[A-Za-z0-9_-]{4,}(\.[A-Za-z0-9_-]*)?');

  static final RegExp _bearerLike =
      RegExp(r'[Bb]earer\s+[A-Za-z0-9._~+/-]+=*');

  static String _safeKey(String key) => key.replaceAll(RegExp(r'\s+'), '_');

  static String _redact(String key, Object? value) {
    final lowerKey = key.toLowerCase();
    for (final part in _forbiddenKeyParts) {
      if (lowerKey.contains(part)) return '***';
    }
    if (value == null) return 'null';

    var text = value.toString();
    text = text.replaceAll(_jwtLike, '***');
    text = text.replaceAll(_bearerLike, 'Bearer ***');
    text = text.replaceAll(RegExp(r'\s+'), ' ').trim();

    if (text.length > _maxValueLength) {
      text = '${text.substring(0, _maxValueLength)}…';
    }
    // Spaces would break the key=value framing.
    return text.contains(' ') ? '"$text"' : text;
  }

  static String _randomId(int length) {
    const alphabet = 'abcdefghijklmnopqrstuvwxyz0123456789';
    return String.fromCharCodes(
      Iterable<int>.generate(
        length,
        (_) => alphabet.codeUnitAt(_random.nextInt(alphabet.length)),
      ),
    );
  }
}

/// A timed operation opened by [AppLog.begin].
class OperationLog {
  OperationLog._({
    required this.operation,
    required this.correlationId,
    required DateTime startedAt,
    Map<String, Object?>? opening,
  })  : _startedAt = startedAt,
        _fields = <String, Object?>{...?opening};

  final String operation;
  final String correlationId;
  final DateTime _startedAt;
  final Map<String, Object?> _fields;

  bool _ended = false;

  /// Headers to attach to the outbound request so the server can log the same
  /// correlation id. Contains no credentials by construction.
  Map<String, String> get headers =>
      <String, String>{AppLog.correlationHeader: correlationId};

  /// Adds context discovered while the operation runs (queue depth, revision,
  /// retry count). Redacted at emit time like everything else.
  void add(String key, Object? value) => _fields[key] = value;

  void end({
    LogResult result = LogResult.ok,
    int? httpStatus,
    Map<String, Object?>? fields,
  }) {
    // Guarded because an operation ended twice would report a duration that
    // silently includes the caller's own error handling.
    if (_ended) return;
    _ended = true;

    if (httpStatus != null) _fields['status'] = httpStatus;
    if (fields != null) _fields.addAll(fields);

    AppLog._emit(AppLog._format(
      operation: operation,
      correlationId: correlationId,
      result: result,
      duration: DateTime.now().difference(_startedAt),
      fields: _fields,
    ));
  }
}
