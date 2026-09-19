/// Keeping the shared ledger in step with Supabase.
///
/// The shape of this is deliberately lopsided. Local edits apply immediately
/// and are pushed afterwards, so the app never waits on a network call to feel
/// responsive; pulls replace what is here, because the server is what everyone
/// else in the group can see. Last write wins per row — enough for a group of
/// flatmates adding expenses minutes apart, and honestly not enough for two
/// people editing the same expense at the same second.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models.dart';
import '../store.dart';
import 'auth_service.dart';
import 'backend.dart';

class GroupsSync {
  GroupsSync(this._store);

  final MullStore _store;
  RealtimeChannel? _channel;
  Timer? _debounce;
  bool _busy = false;

  bool get _live => Backend.isAvailable && Backend.isSignedIn;

  /// Whether the project has had `20260919120000_recurring_and_direct.sql`
  /// applied — schedules, one-to-one ledgers and expense notes.
  ///
  /// Probed once rather than assumed, because an upsert naming a column that
  /// does not exist fails the *whole* batch. Without this, a phone that has
  /// updated ahead of the database would stop syncing groups entirely, and the
  /// symptom would be "my expenses vanished on my other phone" rather than
  /// anything pointing at a migration.
  bool? _extended;

  Future<bool> _hasExtendedSchema() async {
    if (_extended != null) return _extended!;
    try {
      await Backend.client.from('recurring_expenses').select('id').limit(1);
      _extended = true;
    } catch (_) {
      _extended = false;
      debugPrint(
        'mull: this project predates the recurring migration — run `supabase db push`. '
        'Groups still sync; schedules and notes stay on this phone until then.',
      );
    }
    return _extended!;
  }

  /// Points the store's group mutations at this sync.
  void attachTo(MullStore store) {
    store
      ..onGroupChanged = push
      ..onGroupDeleted = deleteGroup;
  }

  StreamSubscription<AuthState>? _auth;

  /// Follows the session: pull and subscribe on sign-in, drop it all on sign-out.
  ///
  /// Claiming comes before the pull, and the order is the whole point. A seat
  /// invited by email only becomes visible to its owner once `claim_seats()`
  /// has filled in `user_id` — pull first and RLS correctly shows them nothing,
  /// so a brand new user's first sight of Mull is an empty screen and the
  /// history they were invited to arrives only on some later launch.
  void start() {
    if (!Backend.isAvailable) return;
    _auth = Backend.client.auth.onAuthStateChange.listen((state) async {
      if (state.session != null) {
        await _claimThenPull();
        listen();
      } else {
        await stop();
      }
    });
    if (Backend.isSignedIn) {
      unawaited(_claimThenPull());
      listen();
    }
  }

  /// Runs on every sign-in *and* every launch, not just the first: someone can
  /// be invited while you are away, and the seat should be waiting when you
  /// open the app rather than after the next unrelated change. Claiming a seat
  /// that is already yours is a no-op, so repeating it costs one round trip.
  Future<void> _claimThenPull() async {
    await AuthService.claimSeats();
    await pull();
    await _retryUnsynced();
  }

  /// Sends up anything the server has never acknowledged.
  ///
  /// Mull applies a group edit locally and pushes afterwards, so a push that
  /// fails — no signal, or a server that said no — leaves a group that exists
  /// only on this phone. Without this it stays that way until something else
  /// happens to touch it, which for a finished trip is never.
  Future<void> _retryUnsynced() async {
    if (!_live) return;
    for (final group in [..._store.groups.where((g) => !g.hasReachedServer)]) {
      await push(group);
    }
  }

  Future<void> dispose() async {
    await _auth?.cancel();
    _auth = null;
    await stop();
  }

  // ------------------------------------------------------------------- pull

  /// Replaces local groups with what the server says this account can see.
  Future<void> pull() async {
    if (!_live || _busy) return;
    _busy = true;
    try {
      final extended = await _hasExtendedSchema();
      final rows = await Backend.client
          .from('groups')
          .select('''
            id, name, created_at${extended ? ', kind' : ''},
            members ( id, user_id, name, email, phone, upi_id,
                      account:user_id ( name, upi_id ) ),
            expenses ( id, description, amount, payer_member_id, method,
                       repeats_monthly, spent_on, deleted_at${extended ? ', recurring_id, note' : ''},
                       expense_shares ( member_id, amount ) )${extended ? ''',
            recurring_expenses ( id, description, amount, payer_member_id, method,
                                 frequency, next_due, ends_on, paused, auto_add,
                                 last_added_on, created_at, deleted_at,
                                 recurring_shares ( member_id, amount ) )''' : ''},
            settlements ( id, from_member_id, to_member_id, amount, status,
                          utr, claimed_at, confirmed_at )
          ''')
          .isFilter('deleted_at', null)
          .order('created_at');

      final me = Backend.user?.id;
      final groups = [for (final row in rows as List) _group(row as Map<String, dynamic>, me)];
      _store.replaceGroups(groups, keepLocalSchedules: !extended);
    } catch (e) {
      // A failed pull leaves what is already on screen alone. Blanking the
      // groups because the train went into a tunnel would be worse than stale.
      debugPrint('mull: pull failed ($e)');
    } finally {
      _busy = false;
    }
  }

  Group _group(Map<String, dynamic> row, String? myUserId) {
    final members = [
      for (final m in (row['members'] as List? ?? const []))
        () {
          // A seat that belongs to a real account takes that account's name and
          // VPA in preference to whatever was typed when the seat was made.
          //
          // This matters most for the VPA. Settling up opens a UPI app with the
          // payee prefilled, and a handle typed by the payer is a payment to
          // whoever actually owns it — a typo does not fail, it pays a stranger,
          // and nothing undoes it. The only person who can be trusted to enter
          // a VPA is the one being paid. Their profile also follows them when
          // they change bank, which a copy taken at invite time never would.
          final account = m['account'] as Map<String, dynamic>?;
          final typedName = m['name'] as String? ?? '';
          final theirName = account?['name'] as String?;

          return Member(
            id: m['id'] as String,
            name: (theirName != null && theirName.trim().isNotEmpty) ? theirName : typedName,
            isYou: myUserId != null && m['user_id'] == myUserId,
            upiId: account?['upi_id'] as String? ?? m['upi_id'] as String?,
            // Read every field the push writes. A field pulled as null is
            // pushed back as null on the next edit, so forgetting one here does
            // not merely lose it locally — it erases it for everyone.
            email: m['email'] as String?,
            phone: m['phone'] as String?,
            userId: m['user_id'] as String?,
          );
        }(),
    ];

    final expenses = <Expense>[];
    for (final e in (row['expenses'] as List? ?? const [])) {
      if (e['deleted_at'] != null) continue;
      expenses.add(
        Expense(
          id: e['id'] as String,
          description: e['description'] as String? ?? '',
          amount: (e['amount'] as num).toInt(),
          payerId: e['payer_member_id'] as String,
          shares: {
            for (final s in (e['expense_shares'] as List? ?? const []))
              s['member_id'] as String: (s['amount'] as num).toInt(),
          },
          method: SplitMethod.values.byName(e['method'] as String? ?? 'equal'),
          recurringId: e['recurring_id'] as String?,
          note: e['note'] as String?,
          date: DateTime.parse(e['spent_on'] as String),
        ),
      );
    }

    final recurring = <Recurring>[];
    for (final r in (row['recurring_expenses'] as List? ?? const [])) {
      if (r['deleted_at'] != null) continue;
      recurring.add(
        Recurring(
          id: r['id'] as String,
          description: r['description'] as String? ?? '',
          amount: (r['amount'] as num).toInt(),
          payerId: r['payer_member_id'] as String,
          shares: {
            for (final s in (r['recurring_shares'] as List? ?? const []))
              s['member_id'] as String: (s['amount'] as num).toInt(),
          },
          method: SplitMethod.values.byName(r['method'] as String? ?? 'equal'),
          frequency: Frequency.values.byName(r['frequency'] as String? ?? 'monthly'),
          nextDue: DateTime.parse(r['next_due'] as String),
          endsOn: r['ends_on'] == null ? null : DateTime.parse(r['ends_on'] as String),
          paused: r['paused'] as bool? ?? false,
          autoAdd: r['auto_add'] as bool? ?? false,
          lastAddedOn: r['last_added_on'] == null ? null : DateTime.parse(r['last_added_on'] as String),
          createdAt: DateTime.parse(r['created_at'] as String),
        ),
      );
    }

    final settlements = [
      for (final s in (row['settlements'] as List? ?? const []))
        Settlement(
          id: s['id'] as String,
          fromId: s['from_member_id'] as String,
          toId: s['to_member_id'] as String,
          amount: (s['amount'] as num).toInt(),
          status: SettlementStatus.values.byName(s['status'] as String? ?? 'pending'),
          utr: s['utr'] as String?,
          date: DateTime.parse(s['claimed_at'] as String),
          confirmedAt: s['confirmed_at'] == null ? null : DateTime.parse(s['confirmed_at'] as String),
        ),
    ];

    return Group(
      id: row['id'] as String,
      name: row['name'] as String? ?? '',
      kind: GroupKind.values.byName(row['kind'] as String? ?? 'group'),
      members: members,
      expenses: expenses,
      settlements: settlements,
      recurring: recurring,
      createdAt: DateTime.parse(row['created_at'] as String),
      // It came from the server, so by definition the server has it.
      syncedAt: DateTime.now(),
    );
  }

  // ------------------------------------------------------------------- push

  /// Sends a whole group up. Small enough to be worth doing wholesale rather
  /// than tracking which field changed.
  Future<void> push(Group group) async {
    if (!_live) return;
    final me = Backend.user?.id;
    if (me == null) return;

    final extended = await _hasExtendedSchema();

    try {
      final db = Backend.client;
      // Authorship columns are sent, and sending them is *not* the client
      // deciding who wrote what.
      //
      // Leaving them out looked cleaner and did not work: PostgREST writes an
      // absent column as NULL rather than letting its default apply, so every
      // group arrived with created_by = null and was refused by the insert
      // policy. A column default cannot help when the payload always overrides
      // it with an explicit null.
      //
      // Postgres has the last word regardless — the stamp triggers set these on
      // insert and restore them on update — so what goes up here only has to be
      // non-null. Whatever we send, a row keeps the author it actually had.
      await db.from('groups').upsert({
        'id': group.id,
        'name': group.name,
        'created_by': me,
        if (extended) 'kind': group.kind.name,
      });

      // One batch, and `user_id` sent plainly — including when it is null.
      //
      // This used to be two carefully separated calls, to stop a stale local
      // null from overwriting a seat someone had claimed server-side. That
      // never actually worked: PostgREST writes a column absent from the
      // payload as NULL rather than leaving it alone, so the omission the
      // whole scheme depended on was not an omission at all.
      //
      // The rule now lives in Postgres, where it belongs — guard_member_identity
      // coalesces a null against the existing owner, so silence from a client
      // cannot evict anybody. Saying it once, on the server, beats every client
      // being careful forever.
      //
      // Your own seat may not carry a userId locally — addGroup builds it from
      // the profile, which has no account id in it — so `isYou` stands in.
      String? ownerOf(Member m) => m.isYou ? me : m.userId;

      await db.from('members').upsert([
        for (final m in group.members)
          {
            'id': m.id,
            'group_id': group.id,
            'user_id': ownerOf(m),
            'name': m.name,
            'email': m.email,
            'phone': m.phone,
            // A seat with an account behind it has no VPA of its own — the
            // account has one, and the pull reads it from there. Writing our
            // copy back would pin a snapshot that goes stale the day they
            // change bank.
            'upi_id': ownerOf(m) == null ? m.upiId : null,
          },
      ]);

      // Schedules go up before the expenses that reference them, or the foreign
      // key on `recurring_id` has nothing to point at.
      if (extended && group.recurring.isNotEmpty) {
        await db.from('recurring_expenses').upsert([
          for (final r in group.recurring)
            {
              'id': r.id,
              'group_id': group.id,
              'description': r.description,
              'amount': r.amount,
              'payer_member_id': r.payerId,
              'method': r.method.name,
              'frequency': r.frequency.name,
              'next_due': _day(r.nextDue),
              'ends_on': r.endsOn == null ? null : _day(r.endsOn!),
              'paused': r.paused,
              'auto_add': r.autoAdd,
              'last_added_on': r.lastAddedOn == null ? null : _day(r.lastAddedOn!),
              'created_by': me,
            },
        ]);
        await db.from('recurring_shares').upsert([
          for (final r in group.recurring)
            for (final entry in r.shares.entries)
              {'recurring_id': r.id, 'member_id': entry.key, 'amount': entry.value},
        ]);
      }

      if (group.expenses.isNotEmpty) {
        await db.from('expenses').upsert([
          for (final e in group.expenses)
            {
              'id': e.id,
              'group_id': group.id,
              'description': e.description,
              'amount': e.amount,
              'payer_member_id': e.payerId,
              'method': e.method.name,
              // Still sent, and still NOT NULL on the server. It is derived
              // now — true exactly when the expense came off a schedule — but
              // a NOT NULL column that stops being sent is a failed push, so
              // it keeps being sent.
              'repeats_monthly': e.isRecurring,
              'spent_on': _day(e.date),
              'created_by': me,
              if (extended) 'recurring_id': e.recurringId,
              if (extended) 'note': e.note,
            },
        ]);
        await db.from('expense_shares').upsert([
          for (final e in group.expenses)
            for (final entry in e.shares.entries)
              {'expense_id': e.id, 'member_id': entry.key, 'amount': entry.value},
        ]);
      }

      if (group.settlements.isNotEmpty) {
        await db.from('settlements').upsert([
          for (final s in group.settlements)
            {
              'id': s.id,
              'group_id': group.id,
              'from_member_id': s.fromId,
              'to_member_id': s.toId,
              'amount': s.amount,
              'status': s.status.name,
              'utr': s.utr,
              'claimed_at': s.date.toIso8601String(),
              'claimed_by': me,
              'confirmed_at': s.confirmedAt?.toIso8601String(),
            },
        ]);
      }
      _store.markGroupSynced(group);
    } catch (e) {
      // Loud on purpose. A push that fails quietly leaves the app looking
      // perfectly fine while nothing it shows exists anywhere else, and the
      // only symptom arrives much later as "my group disappeared".
      //
      // The session is printed alongside because the two failures look
      // identical from here: a policy that genuinely says no, and a request
      // that arrived without a token and so matched no policy at all. Postgres
      // reports both as 42501.
      final session = Backend.session;
      debugPrint(
        'mull: PUSH FAILED for "${group.title}" — it is on this phone only. $e\n'
        'mull:   uid=${Backend.user?.id} hasSession=${session != null} '
        'expired=${session?.isExpired} expiresAt=${session?.expiresAt}',
      );
    }
  }

  /// A `date` column wants a date, not an instant. Sending the ISO timestamp
  /// works until someone in IST adds rent at half past midnight and it lands on
  /// the day before.
  static String _day(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  /// Soft delete: a balance that silently changes is a balance nobody trusts.
  Future<void> deleteGroup(String groupId) async {
    if (!_live) return;
    try {
      await Backend.client
          .from('groups')
          .update({'deleted_at': DateTime.now().toIso8601String()})
          .eq('id', groupId);
    } catch (e) {
      debugPrint('mull: deleteGroup failed ($e)');
    }
  }

  // --------------------------------------------------------------- realtime

  /// Re-pulls when anyone else in a group changes something.
  void listen() {
    if (!_live || _channel != null) return;
    _channel = Backend.client.channel('mull-groups')
      ..onPostgresChanges(event: PostgresChangeEvent.all, schema: 'public', table: 'expenses', callback: _bump)
      ..onPostgresChanges(event: PostgresChangeEvent.all, schema: 'public', table: 'settlements', callback: _bump)
      ..onPostgresChanges(event: PostgresChangeEvent.all, schema: 'public', table: 'members', callback: _bump)
      ..onPostgresChanges(event: PostgresChangeEvent.all, schema: 'public', table: 'groups', callback: _bump)
      ..onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: 'recurring_expenses',
        callback: _bump,
      )
      ..subscribe();
  }

  /// Several rows usually change together — one expense is a row plus a share
  /// per person — so coalesce them into a single pull.
  void _bump(PostgresChangePayload _) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), pull);
  }

  Future<void> stop() async {
    _debounce?.cancel();
    final channel = _channel;
    _channel = null;
    if (channel != null) await Backend.client.removeChannel(channel);
  }
}
