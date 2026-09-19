/// Your inbox: what other people have told you.
///
/// Kept apart from [MullStore] on purpose. The store is the ledger, it is
/// written to disk on every edit, and it is the thing the app is *about*.
/// Notices are account state, they live on the server, and nothing is lost by
/// holding them only in memory — a fresh launch asks for them again.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'remote/backend.dart';
import 'remote/notices_service.dart';
import 'store.dart';

class NoticesInbox extends ChangeNotifier {
  final List<Notified> _all = [];
  RealtimeChannel? _channel;
  StreamSubscription<AuthState>? _auth;
  bool _loading = false;

  List<Notified> get all => List.unmodifiable(_all);
  int get unread => _all.where((n) => n.unread).length;
  bool get isLoading => _loading && _all.isEmpty;

  /// Raised for a notice that arrived while the app was open, so the shell can
  /// put it on screen. Only live arrivals: replaying the whole inbox as
  /// banners on every launch would be unusable.
  final ValueNotifier<Notified?> arrived = ValueNotifier(null);

  /// Sends what a local edit generated. Wired to the store's [MullStore.onNotice].
  void attachTo(MullStore store) => store.onNotice = (notice) => unawaited(NoticesService.send(notice));

  void start() {
    if (!Backend.isAvailable) return;
    _auth = Backend.client.auth.onAuthStateChange.listen((state) async {
      if (state.session != null) {
        await refresh();
        _listen();
      } else {
        _all.clear();
        notifyListeners();
        await _stop();
      }
    });
    if (Backend.isSignedIn) {
      unawaited(refresh());
      _listen();
    }
  }

  Future<void> refresh() async {
    if (!Backend.isSignedIn) return;
    _loading = true;
    final fetched = await NoticesService.list();
    _loading = false;
    _all
      ..clear()
      ..addAll(fetched);
    notifyListeners();
  }

  /// Subscribed to this account's rows only.
  ///
  /// The filter is a courtesy, not the protection: RLS already means the socket
  /// never carries anyone else's notices. It is here so the server does not
  /// bother evaluating rows that were never going to arrive.
  void _listen() {
    final me = Backend.user?.id;
    if (me == null || _channel != null) return;
    _channel = Backend.client.channel('mull-notices-$me')
      ..onPostgresChanges(
        event: PostgresChangeEvent.insert,
        schema: 'public',
        table: 'notices',
        filter: PostgresChangeFilter(
          type: PostgresChangeFilterType.eq,
          column: 'recipient_id',
          value: me,
        ),
        callback: (payload) {
          final notice = Notified.fromRow(payload.newRecord);
          if (_all.any((n) => n.id == notice.id)) return;
          _all.insert(0, notice);
          arrived.value = notice;
          notifyListeners();
        },
      )
      ..subscribe();
  }

  /// Called when the inbox is opened. Marks what is on screen as seen — both
  /// here and on the server, so the badge does not come back on the next pull
  /// or on the other device.
  Future<void> markAllRead() async {
    final ids = [for (final n in _all) if (n.unread) n.id];
    if (ids.isEmpty) return;
    final at = DateTime.now();
    for (var i = 0; i < _all.length; i++) {
      if (_all[i].unread) {
        _all[i] = Notified(
          id: _all[i].id,
          kind: _all[i].kind,
          title: _all[i].title,
          body: _all[i].body,
          at: _all[i].at,
          groupId: _all[i].groupId,
          amount: _all[i].amount,
          readAt: at,
        );
      }
    }
    notifyListeners();
    await NoticesService.markRead(ids);
  }

  Future<void> _stop() async {
    final channel = _channel;
    _channel = null;
    if (channel != null) await Backend.client.removeChannel(channel);
  }

  @override
  void dispose() {
    unawaited(_auth?.cancel());
    unawaited(_stop());
    arrived.dispose();
    super.dispose();
  }
}

/// Makes the inbox reachable from any widget, the way [StoreScope] does the
/// ledger.
class NoticesScope extends InheritedNotifier<NoticesInbox> {
  const NoticesScope({super.key, required NoticesInbox inbox, required super.child})
    : super(notifier: inbox);

  static NoticesInbox? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<NoticesScope>()?.notifier;

  static NoticesInbox? read(BuildContext context) =>
      context.getInheritedWidgetOfExactType<NoticesScope>()?.notifier;
}

extension NoticesContext on BuildContext {
  /// Null in tests and previews that do not wrap a scope — every caller has to
  /// cope with an app that simply has no inbox.
  NoticesInbox? get notices => NoticesScope.of(this);
  NoticesInbox? get readNotices => NoticesScope.read(this);
}
