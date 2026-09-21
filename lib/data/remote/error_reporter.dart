/// What went wrong on people's phones, sent to Mull's own database in Mumbai.
///
/// A crash-reporting service would have meant a second company, abroad,
/// holding traces from an Indian app, for what this needs: the error, where
/// in the code it happened, and how often. `report_error()` stores exactly
/// that, deduplicated, with emails and ids scrubbed out server-side. Read it
/// in the dashboard: Table editor -> error_reports, newest `last_seen` first.
///
/// Native crashes (the app vanishing rather than a Dart error) are not here.
/// Apple collects those: Xcode -> Window -> Organizer -> Crashes, and each
/// TestFlight build's crash feedback in App Store Connect.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'backend.dart';

class ErrorReporter {
  /// Set by the build scripts: `--dart-define=MULL_BUILD=1.0.0 (42)`.
  static const _build = String.fromEnvironment('MULL_BUILD');

  /// A screen that throws on every frame should not become a thousand
  /// requests. The server counts repeats anyway; this only saves the traffic.
  static const _perSession = 25;
  static int _sent = 0;
  static final Set<String> _seen = {};

  /// Release builds only. In debug the error is already on the console, and
  /// development mistakes would bury the real ones.
  static void install() {
    if (!kReleaseMode) return;
    final previous = FlutterError.onError;
    FlutterError.onError = (details) {
      previous?.call(details);
      report(details.exception, details.stack, context: details.context?.toDescription());
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      report(error, stack);
      return true;
    };
  }

  static void report(Object error, StackTrace? stack, {String? context}) {
    if (!Backend.isAvailable || _sent >= _perSession) return;
    final message = error.toString();
    final trace = stack?.toString() ?? '';
    final key = '${error.runtimeType}|${message.length > 120 ? message.substring(0, 120) : message}';
    if (!_seen.add(key)) return;
    _sent++;
    unawaited(_send(error.runtimeType.toString(), message, trace, context ?? ''));
  }

  static Future<void> _send(String kind, String message, String stack, String context) async {
    try {
      await Backend.client.rpc('report_error', params: {
        'kind': kind,
        'message': message,
        // The top of the trace is where the answer is.
        'stack': stack.split('\n').take(40).join('\n'),
        'context': context,
        'app_version': _build,
        'os': '${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
      });
    } catch (_) {
      // Reporting a failure to report would loop. It is dropped.
    }
  }
}
