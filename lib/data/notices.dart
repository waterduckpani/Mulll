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
import 'remote/live_channel.dart';
import 'remote/push_service.dart';
import 'remote/notices_service.dart';
import 'store.dart';

class NoticesInbox extends ChangeNotifier {
  final List<Notified> _all = [];
  StreamSubscription<AuthState>? _auth;
  StreamSubscription<Map<String, dynamic>>? _live;
  bool _loading = false;

  List<Notified> get all => List.unmodifiable(_all);
  int get unread => _all.where((n) => n.unread).length;
  bool get isLoading => _loading && _all.isEmpty;

  /// Raised for a notice that arrived while the app was open, so the shell can
  /// put it on screen. Only live arrivals: replaying the whole inbox as
  /// banners on every launch would be unusable.
  final ValueNotifier<Notified?> arrived = ValueNotifier(null);

  /// Sends what a local edit generated. Wired to the store's [MullStore.onNotice].
  void attachTo(MullStore store) => store
    ..onNotice = ((notice) => unawaited(NoticesService.send(notice)))
    ..sendNoticeNow = NoticesService.send;

  void start() {
    if (!Backend.isAvailable) return;
    final channel = LiveChannel.instance;
    // Only this account's notices ever reach its topic, so there is nothing
    // to filter here: the server sends a notice to its recipient and no one
    // else can join.
    _live = channel.notices.listen(_onNotice);
    // The icon's badge is the unread count, kept here so it is right the
    // moment the inbox is opened, not at the next push.
    addListener(_syncBadge);
    channel.connected.addListener(_onConnection);
    _auth = Backend.client.auth.onAuthStateChange.listen((state) async {
      final user = state.session?.user.id;
      if (user != null) {
        // Once per account. A token refresh is the same person, and refetching
        // the whole inbox for it every hour bought nothing.
        if (user == _loadedFor) return;
        _loadedFor = user;
        await refresh();
      } else {
        _loadedFor = null;
        _all.clear();
        notifyListeners();
      }
    });
    if (Backend.isSignedIn) {
      _loadedFor = Backend.user?.id;
      unawaited(refresh());
    }
  }

  /// The account whose inbox was last loaded.
  String? _loadedFor;

  void _onNotice(Map<String, dynamic> row) {
    final Notified notice;
    try {
      notice = Notified.fromRow(row);
    } catch (e) {
      debugPrint('mull: unreadable notice ($e)');
      return;
    }
    if (_all.any((n) => n.id == notice.id)) return;
    _all.insert(0, notice);
    arrived.value = notice;
    notifyListeners();
  }

  int? _badge;

  void _syncBadge() {
    if (_badge == unread) return;
    _badge = unread;
    unawaited(PushService.setBadge(unread));
  }

  /// Whatever landed while the socket was down came through nothing.
  void _onConnection() {
    if (LiveChannel.instance.connected.value) unawaited(refresh());
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

  @override
  void dispose() {
    unawaited(_auth?.cancel());
    unawaited(_live?.cancel());
    LiveChannel.instance.connected.removeListener(_onConnection);
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
