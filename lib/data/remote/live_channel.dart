/// The one socket Mull keeps open: a private topic for this account.
///
/// The server says two things on it, both from triggers (see the 2026-09-21
/// `scale_privacy_push` migration): `group_changed`, carrying only a group id,
/// and `notice`, carrying a new notice whole. Nothing about the ledger rows
/// travels here; a change is a nudge to pull, and the pull is what reads them.
///
/// It replaced a subscription to the database change stream on six tables.
/// That checked every change to any row against every connected user, which
/// is the part of Supabase that stops scaling first. A topic only its owner
/// may join costs one message per person who needs to know.
///
/// Shared, because [GroupsSync] and [NoticesInbox] both listen and two joins
/// of one topic on one socket close each other.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'backend.dart';

class LiveChannel {
  LiveChannel._();

  static final instance = LiveChannel._();

  final _groupChanged = StreamController<String>.broadcast();
  final _notices = StreamController<Map<String, dynamic>>.broadcast();

  /// A group id, each time someone changes something in it.
  Stream<String> get groupChanged => _groupChanged.stream;

  /// A notice row, the moment it is written for you.
  Stream<Map<String, dynamic>> get notices => _notices.stream;

  /// True while subscribed. Listeners use the rising edge to catch up on
  /// whatever happened while the socket was down.
  final ValueNotifier<bool> connected = ValueNotifier(false);

  RealtimeChannel? _channel;
  StreamSubscription<AuthState>? _auth;
  Timer? _reconnect;
  int _retries = 0;
  bool _stopping = false;

  void start() {
    if (!Backend.isAvailable || _auth != null) return;
    _auth = Backend.client.auth.onAuthStateChange.listen((state) {
      if (state.session != null) {
        open();
      } else {
        unawaited(_close());
      }
    });
    if (Backend.isSignedIn) open();
  }

  /// Joins, if not already joined. Safe to call on every resume.
  void open() {
    final me = Backend.user?.id;
    if (!Backend.isAvailable || me == null || _channel != null) return;
    _channel = Backend.client.channel('user:$me', opts: const RealtimeChannelConfig(private: true))
      ..onBroadcast(
        event: 'group_changed',
        callback: (message) {
          final id = _payload(message)['group_id'];
          if (id is String) _groupChanged.add(id);
        },
      )
      ..onBroadcast(
        event: 'notice',
        callback: (message) => _notices.add(_payload(message)),
      )
      ..subscribe((status, error) {
        switch (status) {
          case RealtimeSubscribeStatus.subscribed:
            _retries = 0;
            connected.value = true;
          case RealtimeSubscribeStatus.channelError:
          case RealtimeSubscribeStatus.timedOut:
          case RealtimeSubscribeStatus.closed:
            connected.value = false;
            if (!_stopping) debugPrint('mull: live channel $status ($error)');
            _rebuild();
        }
      });
  }

  /// The client hands over the whole message; the trigger's jsonb is inside it.
  static Map<String, dynamic> _payload(Map<String, dynamic> message) {
    final inner = message['payload'];
    return inner is Map ? Map<String, dynamic>.from(inner) : message;
  }

  /// Builds the channel again after it failed.
  ///
  /// The socket authenticates with the token it had when it joined, and a
  /// token lasts an hour. A session left open overnight woke to an expired
  /// token and a failed join that nothing retried. A new channel joins with
  /// whatever token is current. Backed off and capped, so a tunnel does not
  /// spend the battery reconnecting.
  void _rebuild() {
    if (_stopping || !Backend.isSignedIn) return;
    final channel = _channel;
    _channel = null;
    if (channel != null) unawaited(Backend.client.removeChannel(channel));
    final wait = Duration(seconds: [2, 5, 15, 30, 60][_retries.clamp(0, 4)]);
    _retries++;
    _reconnect?.cancel();
    _reconnect = Timer(wait, () {
      if (Backend.isSignedIn && _channel == null) open();
    });
  }

  Future<void> _close() async {
    _stopping = true;
    _reconnect?.cancel();
    _reconnect = null;
    _retries = 0;
    connected.value = false;
    final channel = _channel;
    _channel = null;
    // removeChannel fires `closed` on the way out; the flag keeps that from
    // scheduling a reconnect to a session that no longer exists.
    if (channel != null) await Backend.client.removeChannel(channel);
    _stopping = false;
  }
}
