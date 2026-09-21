/// Reaching a locked phone.
///
/// A notice already arrives while Mull is open, over [LiveChannel]. This is
/// the other half: the device token, handed to the server so the `push` edge
/// function can send each notice through APNs as well.
///
/// What a push says is decided on the server, from the notice row, so every
/// device and every build words it the same. What happens on a tap is decided
/// here: the inbox opens.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'backend.dart';

class PushService {
  static const _channel = MethodChannel('mull/push');

  static String? _token;
  static String _environment = 'production';
  static StreamSubscription<AuthState>? _auth;

  /// Goes up by one each time a notification is tapped. The shell listens and
  /// opens the inbox.
  static final ValueNotifier<int> opened = ValueNotifier(0);

  static void start() {
    _channel.setMethodCallHandler(_handle);
    if (!Backend.isAvailable) return;
    // A token that arrived before sign-in, or belonged to the last account on
    // this phone, is (re)claimed by whoever signs in.
    _auth ??= Backend.client.auth.onAuthStateChange.listen((state) {
      if (state.session != null) unawaited(_sendToServer());
    });
    unawaited(_takeOpened());
  }

  static Future<void> _handle(MethodCall call) async {
    switch (call.method) {
      case 'token':
        final args = (call.arguments as Map).cast<String, Object?>();
        _token = args['token'] as String?;
        _environment = args['environment'] as String? ?? 'production';
        await _sendToServer();
      case 'opened':
        await _takeOpened();
    }
  }

  /// Asks the first time, and re-registers on every launch after.
  ///
  /// Called once someone is signed in and past onboarding, from the home
  /// screen, so the question comes with the app it is about on screen behind
  /// it rather than as the first thing a new install says.
  static Future<void> ensure() async {
    if (!Backend.isSignedIn) return;
    final status = await _invoke<String>('status');
    switch (status) {
      case 'notDetermined':
        await _invoke<bool>('request');
      case 'authorized' || 'provisional' || 'ephemeral':
        await _invoke<void>('register');
      default:
        // Denied. Settings is where that is changed, and asking again from
        // here does nothing on iOS.
        break;
    }
  }

  /// Stops this phone getting the account's pushes. Before signing out, while
  /// the session can still say whose token it is.
  static Future<void> forget() async {
    final token = _token;
    if (token == null || !Backend.isSignedIn) return;
    try {
      await Backend.client.rpc('unregister_push_token', params: {'device_token': token});
    } catch (e) {
      debugPrint('mull: unregister_push_token failed ($e)');
    }
  }

  /// The number on the app icon: unread notices.
  static Future<void> setBadge(int count) => _invoke<void>('setBadge', count);

  static Future<void> _sendToServer() async {
    final token = _token;
    if (token == null || !Backend.isSignedIn) return;
    try {
      await Backend.client.rpc(
        'register_push_token',
        params: {'device_token': token, 'apns_env': _environment},
      );
    } catch (e) {
      debugPrint('mull: register_push_token failed ($e)');
    }
  }

  static Future<void> _takeOpened() async {
    final payload = await _invoke<Object?>('takeOpened');
    if (payload != null) opened.value++;
  }

  /// Null when there is no native side: tests, and anything not iOS.
  static Future<T?> _invoke<T>(String method, [Object? arguments]) async {
    try {
      return await _channel.invokeMethod<T>(method, arguments);
    } on MissingPluginException {
      return null;
    } on PlatformException catch (e) {
      debugPrint('mull: push $method failed ($e)');
      return null;
    }
  }
}
