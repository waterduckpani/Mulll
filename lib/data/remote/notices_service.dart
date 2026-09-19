/// Telling people things, inside Mull.
///
/// The point of this app is that the ledger stops living in a WhatsApp group,
/// and a reminder that opens WhatsApp is the one feature guaranteeing the
/// chat stays open. So a reminder is a row in `notices` now, addressed to one
/// person, delivered to their app.
///
/// Two limits are deliberate and both live on the server. Who may be told is
/// checked against group membership, so knowing a uuid is not enough to write
/// into somebody's inbox; and a reminder is counted, twice a day per pair, so
/// the cap is not something a reinstall clears.
///
/// What this is *not* is push. There are no device tokens here and nothing
/// reaches a locked phone: a notice arrives while Mull is open, or it is
/// waiting in the inbox the next time it is. Adding APNs later means an edge
/// function reading this same table, not a different shape of data.
library;

import 'package:flutter/foundation.dart';

import '../store.dart';
import 'backend.dart';

/// One notice, as the person receiving it sees it.
class Notified {
  const Notified({
    required this.id,
    required this.kind,
    required this.title,
    required this.body,
    required this.at,
    this.groupId,
    this.amount,
    this.readAt,
  });

  final String id;
  final NoticeKind kind;
  final String title;
  final String body;
  final DateTime at;
  final String? groupId;
  final int? amount;
  final DateTime? readAt;

  bool get unread => readAt == null;

  factory Notified.fromRow(Map<String, dynamic> row) => Notified(
    id: row['id'] as String,
    kind: NoticeKindWire.read(row['kind'] as String?),
    title: row['title'] as String? ?? '',
    body: row['body'] as String? ?? '',
    at: DateTime.parse(row['created_at'] as String).toLocal(),
    groupId: row['group_id'] as String?,
    amount: (row['amount'] as num?)?.toInt(),
    readAt: row['read_at'] == null ? null : DateTime.parse(row['read_at'] as String).toLocal(),
  );
}

/// What happened when you tried to chase someone.
enum ReminderOutcome {
  sent,

  /// Today's two are used up. Not an error and not phrased as one.
  outOfTurns,

  /// No signal, or the server said no.
  failed,
}

class NoticesService {
  static const _columns = 'id, kind, title, body, amount, group_id, created_at, read_at';

  static Future<List<Notified>> list({int limit = 60}) async {
    if (!Backend.isAvailable || !Backend.isSignedIn) return const [];
    try {
      final rows = await Backend.client
          .from('notices')
          .select(_columns)
          .order('created_at', ascending: false)
          .limit(limit);
      return [for (final row in rows as List) Notified.fromRow(row as Map<String, dynamic>)];
    } catch (e) {
      debugPrint('mull: notices list failed ($e)');
      return const [];
    }
  }

  static Future<void> markRead(Iterable<String> ids) async {
    if (!Backend.isAvailable || ids.isEmpty) return;
    try {
      await Backend.client
          .from('notices')
          .update({'read_at': DateTime.now().toUtc().toIso8601String()})
          .inFilter('id', ids.toList());
    } catch (e) {
      debugPrint('mull: markRead failed ($e)');
    }
  }

  /// Sends everything a local change generated.
  ///
  /// Fire and forget on purpose. The edit has already applied locally and been
  /// pushed; a notification that did not go out is worth a line in the log and
  /// is not worth failing an expense over.
  static Future<void> send(Notice notice) async {
    if (!Backend.isAvailable || !Backend.isSignedIn || notice.to.isEmpty) return;
    try {
      await Backend.client.rpc(
        'notify',
        params: {
          'target_group': notice.groupId,
          'recipients': notice.to,
          'notice': notice.kind.wire,
          'title': notice.title,
          'body': notice.body,
          'amount': notice.amount,
        },
      );
    } catch (e) {
      debugPrint('mull: notify failed ($e)');
    }
  }

  /// Chases one person, if today's allowance has anything left in it.
  static Future<ReminderOutcome> remind({
    required String toUserId,
    String? groupId,
    required String title,
    String body = '',
    int? amount,
  }) async {
    if (!Backend.isAvailable || !Backend.isSignedIn) return ReminderOutcome.failed;
    try {
      final outcome = await Backend.client.rpc(
        'send_reminder',
        params: {
          'target': toUserId,
          'target_group': groupId,
          'title': title,
          'body': body,
          'amount': amount,
        },
      );
      return outcome == 'sent' ? ReminderOutcome.sent : ReminderOutcome.outOfTurns;
    } catch (e) {
      debugPrint('mull: send_reminder failed ($e)');
      return ReminderOutcome.failed;
    }
  }

  /// How many more reminders this account may send that person today.
  ///
  /// Asked before the button is drawn rather than after it is pressed. A
  /// "Remind" that fails on tap teaches people to tap it twice.
  static Future<int?> remindersLeft(String toUserId) async {
    if (!Backend.isAvailable || !Backend.isSignedIn) return null;
    try {
      final left = await Backend.client.rpc('reminders_left', params: {'target': toUserId});
      return (left as num?)?.toInt();
    } catch (e) {
      debugPrint('mull: reminders_left failed ($e)');
      return null;
    }
  }
}
