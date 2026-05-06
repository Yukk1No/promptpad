import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Settings-controlled in-memory calibration log buffer. Replaces the
/// compile-time `--dart-define=CADENCE_CALIBRATION` gate so testers
/// without Xcode/adb access can collect data via an in-app export.
///
/// Format is byte-compatible with the previous CADENCE log lines so
/// `benchmark/cadence/calibrate.py` parses the export unchanged:
///   `CADENCE: {"t":..., "kind":"result", ...}`
///
/// Buffer is bounded at [_maxLines]; oldest entries drop on overflow
/// to keep memory predictable across long sessions.
class DebugLog {
  static const _prefsKey = 'debug_mode';
  static const int _maxLines = 10000;

  static bool _enabled = false;
  static final List<String> _buffer = [];

  static bool get enabled => _enabled;
  static int get bufferedLineCount => _buffer.length;

  /// Read the persisted toggle. Call once from `main()` so the rest of
  /// the app can use [enabled] synchronously.
  static Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _enabled = prefs.getBool(_prefsKey) ?? false;
  }

  /// Persist the toggle. Clears the buffer when transitioning off → on
  /// so the next session doesn't carry stale entries; preserves it on
  /// on → off so the user can still export what they captured.
  static Future<void> setEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsKey, value);
    if (value && !_enabled) _buffer.clear();
    _enabled = value;
  }

  /// Append a structured event. No-op when disabled, so call sites pay
  /// only a flag check in the common path.
  static void log(String kind, [Map<String, Object?> extra = const {}]) {
    if (!_enabled) return;
    final line = 'CADENCE: ${jsonEncode({
          't': DateTime.now().millisecondsSinceEpoch,
          'kind': kind,
          ...extra,
        })}';
    if (kDebugMode) {
      // ignore: avoid_print
      print(line);
    }
    _buffer.add(line);
    if (_buffer.length > _maxLines) {
      _buffer.removeRange(0, _buffer.length - _maxLines);
    }
  }

  static String dump() => _buffer.join('\n');

  static void clear() => _buffer.clear();

  /// Write the buffer to a timestamped file in the app's temporary
  /// directory. Returns the absolute path so a caller can hand it to
  /// `share_plus`.
  static Future<String> writeToTempFile() async {
    final dir = await getTemporaryDirectory();
    final ts = DateTime.now().toIso8601String().replaceAll(':', '-');
    final file = File('${dir.path}/promptpad-calibration-$ts.log');
    await file.writeAsString(dump());
    return file.path;
  }
}
