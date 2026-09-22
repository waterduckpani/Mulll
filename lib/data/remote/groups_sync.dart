/// Keeping the shared ledger in step with Supabase.
///
/// Local edits apply immediately and are pushed afterwards, so the app never
/// waits on a network call to feel responsive. What goes up is only what
/// changed — each group keeps a print of every row as the server last had it
/// ([Group.acked]) — and what comes down is folded in around anything that has
/// not gone up yet ([MullStore.replaceGroups]). Last write wins per row: enough
/// for flatmates adding expenses minutes apart, and honestly not enough for two
/// people editing the same expense in the same second.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models.dart';
import '../store.dart';
import 'auth_service.dart';
import 'backend.dart';
import 'error_reporter.dart';
import 'live_channel.dart';

class GroupsSync {
  GroupsSync(this._store);

  final MullStore _store;
  Timer? _debounce;
  Timer? _poll;

  /// How often to ask anyway.
  ///
  /// Realtime carries a change in well under a second when it is working, and
  /// it is not always working — a websocket through a phone's radio drops,
  /// reconnects, and says nothing about the events in between. So there is a
  /// poll under it: often while the socket is down, rarely while it is up.
  ///
  /// Every pull fetches every group this account can see, whole. At twenty
  /// seconds regardless, a year of flat expenses was being downloaded three
  /// times a minute for as long as the app was open.
  static const _pollWhileDown = Duration(seconds: 20);
  static const _pollWhileLive = Duration(minutes: 2);

  bool get _live => Backend.isAvailable && Backend.isSignedIn;

  // -------------------------------------------------------------- probes

  /// Whether the project has had the 2026-09-19/20 migrations applied —
  /// schedules, one-to-one ledgers, expense notes, group icons and who
  /// administers a group. One flag, because they went up together.
  ///
  /// Probed rather than assumed, because an upsert naming a column that does
  /// not exist fails the *whole* batch. A phone that has updated ahead of the
  /// database would otherwise stop syncing groups entirely.
  ///
  /// Null means "could not tell". The probe used to cache `false` for any
  /// error at all, so opening the app once with no signal decided for the
  /// rest of the session that the database had none of these columns: roles,
  /// icons and schedules stopped syncing, and offsets went up as ordinary
  /// payments. Only an answer from Postgres about the schema is cached now.
  bool? _extended;

  Future<bool?> _hasExtendedSchema() async =>
      _extended ??= await _probe(() => Backend.client.from('recurring_expenses').select('id').limit(1));

  /// Whether the 2026-09-20 settlement migration is in — soft-deleted
  /// settlements and the offset flag. Its own probe, because it went up later.
  bool? _settlementsExtended;

  Future<bool?> _hasSettlementExtras() async =>
      _settlementsExtended ??= await _probe(() => Backend.client.from('settlements').select('is_offset').limit(1));

  /// True if the query works, false if Postgres says the table or column does
  /// not exist, and null for anything else — no signal, an expired token —
  /// which says nothing about the schema and must not be remembered.
  static Future<bool?> _probe(Future<Object?> Function() query) async {
    try {
      await query();
      return true;
    } on PostgrestException catch (e) {
      const missing = {'42P01', '42703', 'PGRST200', 'PGRST204', 'PGRST205'};
      if (missing.contains(e.code)) {
        debugPrint('mull: this project is missing a migration (${e.message}), run `supabase db push`.');
        return false;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  // ---------------------------------------------------------------- setup

  /// Points the store's group mutations at this sync.
  void attachTo(MullStore store) {
    store
      ..onGroupChanged = ((group) async {
        schedulePush(group.id);
      })
      ..onGroupDeleted = deleteGroup
      ..onLeave = leave
      // [resume] rather than [pull]: every caller of `pullNow()` — a resume, a
      // pull-to-refresh — is someone asking "is this current?", and a dead
      // socket is the most likely reason it is not.
      ..onPullRequested = resume;
  }

  StreamSubscription<AuthState>? _auth;

  /// Follows the session: pull and subscribe on sign-in, drop it all on sign-out.
  ///
  /// Claiming comes before the pull, and the order is the whole point: a seat
  /// only becomes visible to its owner once `claim_invitations()` has filled
  /// in `user_id`, so pulling first shows a new user an empty screen.
  void start() {
    if (!Backend.isAvailable) return;
    _auth = Backend.client.auth.onAuthStateChange.listen((state) async {
      if (state.session != null) {
        await claimThenPull();
        listen();
      } else {
        await stop();
      }
    });
    if (Backend.isSignedIn) {
      unawaited(claimThenPull());
      listen();
    }
  }

  /// Runs on every sign-in and every launch, and after a friend request is
  /// accepted — accepting is what lets a seat waiting on your address be
  /// claimed. Claiming a seat that is already yours is a no-op.
  Future<void> claimThenPull() async {
    await AuthService.claimSeats();
    await pull();
  }

  Future<void> dispose() async {
    await _auth?.cancel();
    _auth = null;
    await stop();
  }

  // ------------------------------------------------------------ exclusion

  /// Pushes and pulls take turns.
  ///
  /// A pull that fetched just before a push landed, and merged just after,
  /// used to hand back the pre-push rows and wipe the tombstones the push had
  /// not finished with. Neither is long, and running them one at a time makes
  /// every merge see a settled picture of what the server has.
  Future<void> _tail = Future.value();

  Future<T> _exclusive<T>(Future<T> Function() task) {
    final result = _tail.then((_) => task());
    _tail = result.then<void>((_) {}, onError: (_) {});
    return result;
  }

  // ------------------------------------------------------------------- pull

  Future<void>? _pulling;
  bool _again = false;

  /// Folds in what the server says this account can see.
  ///
  /// Completes when the pull — and any asked for while it ran — is done, so a
  /// caller can wait for the ledger to be current before acting on it.
  Future<void> pull() {
    if (!_live) return Future.value();
    if (_pulling != null) {
      // Something changed while a pull was in flight. Without a second pass the
      // change is simply missed: the running pull may already have its rows.
      _again = true;
      return _pulling!;
    }
    return _pulling = _pullLoop().whenComplete(() => _pulling = null);
  }

  Future<void> _pullLoop() async {
    var reached = false;
    do {
      _again = false;
      reached = await _exclusive(_pullOnce);
    } while (_again);
    // A successful pull means there is signal, so anything still waiting to go
    // up gets another try. This is the offline queue: edits that failed stay
    // marked unsent in [Group.acked] and are retried here until they land.
    if (reached) await _retryPending();
    // Only a push that failed is trouble. A pull that failed is a phone
    // between towers, or waking from the background a moment before its
    // network does; it used to put "changes haven't synced" under a group
    // that had synced fine, on a phone that was online, because something
    // was mid-push at the time.
    if (reached && !_store.hasPendingChanges) _store.setSyncTrouble(false);
  }

  /// True if the server answered.
  ///
  /// Two questions, not one. First the list of groups this account can see
  /// and each one's revision, which is a few bytes a group; then the full
  /// contents of only the groups whose revision moved since this phone last
  /// had them. It used to be every group, whole, on every change anyone made
  /// and every two minutes besides, which is a year of flat expenses
  /// downloaded again because somebody added a chai to the Goa trip.
  Future<bool> _pullOnce() async {
    if (!_live) return false;
    final extended = await _hasExtendedSchema();
    final settlementExtras = await _hasSettlementExtras();
    // Not knowing the schema is not knowing what to ask for. The ledger on
    // screen stays as it is until the next try.
    if (extended == null || settlementExtras == null) return false;
    try {
      final revs = await _revisions();
      if (revs == null) {
        // A project without the revisions migration: fetch everything, the
        // way every pull used to.
        final groups = await _fetch(null, extended: extended, settlementExtras: settlementExtras);
        _store.replaceGroups(groups, keepLocalSchedules: !extended);
        return true;
      }

      // A group with no record of what the server has cannot push until a pull
      // fills one in, so it is fetched whatever its revision says. Phones that
      // took a group in whole before [MullStore.replaceGroups] recorded it were
      // left holding exactly that, with nothing that would ever fetch it again.
      bool unrecorded(Group? g) => g != null && g.hasReachedServer && g.acked.isEmpty;
      final changed = [
        for (final e in revs.entries)
          if ((_store.groupById(e.key)?.serverRev != e.value || unrecorded(_store.groupById(e.key))) &&
              !_store.pendingGroupDeletes.contains(e.key))
            e.key,
      ];
      final groups = <Group>[];
      // In batches, so a first sign-in with a hundred groups does not build a
      // URL too long for the gateway.
      for (var i = 0; i < changed.length; i += 40) {
        final batch = changed.sublist(i, i + 40 > changed.length ? changed.length : i + 40);
        groups.addAll(await _fetch(batch, extended: extended, settlementExtras: settlementExtras));
      }
      // The revision read in the first question, not a newer one. If the group
      // moved again in between, the next pull sees a mismatch and fetches it
      // once more; the other way round it would be missed.
      for (final g in groups) {
        g.serverRev = revs[g.id];
      }
      _store.replaceGroups(groups, keepLocalSchedules: !extended, present: revs.keys.toList());
      return true;
    } catch (e) {
      // A failed pull leaves what is already on screen alone. Blanking the
      // groups because the train went into a tunnel would be worse than stale.
      debugPrint('mull: pull failed ($e)');
      return false;
    }
  }

  /// Every group this account can see, in the server's order, with its
  /// revision. Null on a project that predates revisions.
  bool _revisionsMissing = false;

  Future<Map<String, int>?> _revisions() async {
    if (_revisionsMissing) return null;
    try {
      final rows = await Backend.client.rpc('my_group_revs');
      return {
        for (final row in rows as List)
          (row as Map)['group_id'] as String: (row['rev'] as num).toInt(),
      };
    } on PostgrestException catch (e) {
      // PGRST202: no such function. Remembered only for that answer; anything
      // else is a failed pull, and the next one asks again.
      if (e.code == 'PGRST202' || e.code == '42883') {
        _revisionsMissing = true;
        return null;
      }
      rethrow;
    }
  }

  /// Groups with everything in them. [ids] null means all of them.
  ///
  /// Deleted rows are filtered out on the server rather than skipped here.
  /// It is less to send, and it is what lets Postgres use the indexes on
  /// group_id, which cover live rows only.
  Future<List<Group>> _fetch(
    List<String>? ids, {
    required bool extended,
    required bool settlementExtras,
  }) async {
    var query = Backend.client
        .from('groups')
        .select('''
          id, name, created_at${extended ? ', kind, icon' : ''},
          members ( id, user_id, name, email, phone, upi_id${extended ? ', role' : ''},
                    account:user_id ( name, upi_id ) ),
          expenses ( id, description, amount, payer_member_id, method, created_at,
                     repeats_monthly, spent_on, deleted_at${extended ? ', recurring_id, note' : ''},
                     expense_shares ( member_id, amount ) )${extended ? ''',
          recurring_expenses ( id, description, amount, payer_member_id, method,
                               frequency, next_due, ends_on, paused, auto_add,
                               last_added_on, created_at, deleted_at,
                               recurring_shares ( member_id, amount ) )''' : ''},
          settlements ( id, from_member_id, to_member_id, amount, status,
                        utr, claimed_at, confirmed_at${settlementExtras ? ', is_offset, deleted_at' : ''} )
        ''')
        .isFilter('deleted_at', null)
        .isFilter('expenses.deleted_at', null);
    if (extended) query = query.isFilter('recurring_expenses.deleted_at', null);
    if (settlementExtras) query = query.isFilter('settlements.deleted_at', null);
    // Named outright, so Postgres looks the groups up by key. Asking for
    // "every group" and letting RLS decide made it check every group in the
    // database against this account, one by one.
    if (ids != null) query = query.inFilter('id', ids);

    final rows = await query.order('created_at');
    final me = Backend.user?.id;
    return [for (final row in rows as List) _group(row as Map<String, dynamic>, me)];
  }

  /// Instants come back in UTC. Shown as they are, a payment made at 1am in
  /// Mumbai was dated the day before.
  static DateTime _instant(Object? v) => DateTime.parse(v as String).toLocal();

  Group _group(Map<String, dynamic> row, String? myUserId) {
    final members = [
      for (final m in (row['members'] as List? ?? const []))
        () {
          // A seat that belongs to a real account takes that account's name and
          // VPA, and a linked seat takes its VPA from *nowhere else*.
          //
          // Settling up opens a UPI app with the payee prefilled, and a handle
          // typed by the payer is a payment to whoever actually owns it — a
          // typo does not fail, it pays a stranger. The only person who can be
          // trusted to enter a VPA is the one being paid. Falling back to the
          // seat's column when the account had none let any member write their
          // own handle onto someone else's seat.
          final account = m['account'] as Map<String, dynamic>?;
          final typedName = m['name'] as String? ?? '';
          final theirName = account?['name'] as String?;
          final linked = m['user_id'] != null;

          return Member(
            id: m['id'] as String,
            name: (theirName != null && theirName.trim().isNotEmpty) ? theirName : typedName,
            isYou: myUserId != null && m['user_id'] == myUserId,
            upiId: linked ? (account?['upi_id'] as String?) : (m['upi_id'] as String?),
            // Read every field the push writes. A field pulled as null is
            // pushed back as null on the next edit, which erases it for everyone.
            email: m['email'] as String?,
            phone: m['phone'] as String?,
            userId: m['user_id'] as String?,
            role: MemberRole.values.byName(m['role'] as String? ?? 'member'),
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
          createdAt: e['created_at'] == null ? null : _instant(e['created_at']),
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
          createdAt: _instant(r['created_at']),
        ),
      );
    }

    final settlements = <Settlement>[];
    for (final s in (row['settlements'] as List? ?? const [])) {
      if (s['deleted_at'] != null) continue;
      settlements.add(
        Settlement(
          id: s['id'] as String,
          fromId: s['from_member_id'] as String,
          toId: s['to_member_id'] as String,
          amount: (s['amount'] as num).toInt(),
          status: SettlementStatus.values.byName(s['status'] as String? ?? 'pending'),
          utr: s['utr'] as String?,
          offset: s['is_offset'] as bool? ?? false,
          date: _instant(s['claimed_at']),
          confirmedAt: s['confirmed_at'] == null ? null : _instant(s['confirmed_at']),
        ),
      );
    }

    return Group(
      id: row['id'] as String,
      name: row['name'] as String? ?? '',
      kind: GroupKind.values.byName(row['kind'] as String? ?? 'group'),
      icon: row['icon'] as String?,
      members: members,
      expenses: expenses,
      settlements: settlements,
      recurring: recurring,
      createdAt: _instant(row['created_at']),
      // It came from the server, so by definition the server has it.
      syncedAt: DateTime.now(),
    );
  }

  // ------------------------------------------------------------------- push

  final Map<String, Timer> _pushTimers = {};

  /// Pushes a group shortly, once edits to it have stopped coming.
  ///
  /// Typing your name in the profile sheet renames your seat in every group,
  /// and pushed on every keystroke that was a request per group per letter.
  void schedulePush(String groupId) {
    _pushTimers[groupId]?.cancel();
    _pushTimers[groupId] = Timer(const Duration(milliseconds: 350), () {
      _pushTimers.remove(groupId);
      unawaited(push(groupId));
    });
  }

  /// Takes you out of a group on the server.
  ///
  /// Anything still waiting to go up is sent first, so leaving does not
  /// throw away the last thing you added.
  Future<bool> leave(String groupId) async {
    if (!_live) return false;
    await push(groupId);
    try {
      await Backend.client.rpc('leave_group', params: {'target_group': groupId});
      return true;
    } catch (e) {
      debugPrint('mull: leave_group failed ($e)');
      if (e is PostgrestException) ErrorReporter.report(e, StackTrace.current, context: 'leave_group');
      return false;
    }
  }

  /// Sends up what has changed in a group since the server last had it.
  ///
  /// By id, not by object: a pull replaces the group objects, and a push
  /// holding the old one would record what it sent on a copy nobody reads.
  Future<bool> push(String groupId) => _exclusive(() => _pushOnce(groupId));

  Future<bool> _pushOnce(String groupId) async {
    if (!_live) return false;
    final me = Backend.user?.id;
    if (me == null) return false;
    final group = _store.groupById(groupId);
    if (group == null) return false;

    // A group synced by an older Mull, which kept no record of what the server
    // had. Every row would look changed and the push would re-send the lot —
    // the overwrite this whole scheme exists to stop. The next pull fills the
    // record in; until then there is nothing safe to send.
    if (group.hasReachedServer && group.acked.isEmpty) return false;

    final extended = await _hasExtendedSchema();
    final settlementExtras = await _hasSettlementExtras();
    if (extended == null || settlementExtras == null) return false;

    final printed = group.printed;
    bool dirty(String key) => group.isDirty(key, printed[key]!);
    // Never accepted by the server — new, or brought back by an undo after the
    // delete had already landed. Those say `deleted_at: null` out loud.
    bool fresh(String key) => !group.acked.containsKey(key);

    final db = Backend.client;
    final sent = <String, String>{};
    // Recorded after each statement rather than at the end, so a failure part
    // way through does not re-send what already landed.
    void landed(Iterable<String> keys) {
      final done = {for (final k in keys) k: printed[k]!};
      sent.addAll(done);
      _store.ackRows(group, done);
    }

    try {
      // Authorship columns are sent, and sending them is *not* the client
      // deciding who wrote what: PostgREST writes an absent column as NULL, and
      // the stamp triggers set the real author on insert and keep it on update.
      // A rename from someone who is not (or is no longer) an admin is refused
      // by guard_group_identity, and statements here run in order, so one
      // refused group row used to stop every expense behind it from syncing.
      // It is not sent; the next pull puts the server's name back.
      if (!group.hasReachedServer || (dirty('g') && group.youAreAdmin)) {
        await db.from('groups').upsert({
          'id': group.id,
          'name': group.name,
          'created_by': me,
          if (extended) 'kind': group.kind.name,
          if (extended) 'icon': group.icon,
          if (fresh('g')) 'deleted_at': null,
        });
        landed(['g']);
      }

      // `user_id` sent plainly, including when null — guard_member_identity
      // coalesces a null against the existing owner, so silence from a client
      // cannot evict anybody. Your own seat may not carry a userId locally, so
      // `isYou` stands in.
      String? ownerOf(Member m) => m.isYou ? me : m.userId;
      final members = [for (final m in group.members) if (dirty('m:${m.id}')) m];
      if (members.isNotEmpty) {
        await db.from('members').upsert([
          for (final m in members)
            {
              'id': m.id,
              'group_id': group.id,
              'user_id': ownerOf(m),
              'name': m.name,
              'email': m.email,
              'phone': m.phone,
              // A linked seat has no VPA of its own; the account does.
              'upi_id': ownerOf(m) == null ? m.upiId : null,
              if (extended) 'role': m.role.name,
            },
        ]);
        landed([for (final m in members) 'm:${m.id}']);
      }

      // Schedules before the expenses that reference them, or the foreign key
      // on `recurring_id` has nothing to point at.
      final schedules = [for (final r in group.recurring) if (dirty('r:${r.id}')) r];
      if (extended && schedules.isNotEmpty) {
        await db.from('recurring_expenses').upsert([
          for (final r in schedules)
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
              if (fresh('r:${r.id}')) 'deleted_at': null,
            },
        ]);
        for (final r in schedules) {
          await _replaceShares('recurring_shares', 'recurring_id', r.id, r.shares);
        }
        landed([for (final r in schedules) 'r:${r.id}']);
      }

      final expenses = [for (final e in group.expenses) if (dirty('e:${e.id}')) e];
      if (expenses.isNotEmpty) {
        await db.from('expenses').upsert([
          for (final e in expenses)
            {
              'id': e.id,
              'group_id': group.id,
              'description': e.description,
              'amount': e.amount,
              'payer_member_id': e.payerId,
              'method': e.method.name,
              // Still sent, and still NOT NULL on the server.
              'repeats_monthly': e.isRecurring,
              'spent_on': _day(e.date),
              'created_by': me,
              if (extended) 'recurring_id': e.recurringId,
              if (extended) 'note': e.note,
              if (fresh('e:${e.id}')) 'deleted_at': null,
            },
        ]);
        for (final e in expenses) {
          await _replaceShares('expense_shares', 'expense_id', e.id, e.shares);
        }
        landed([for (final e in expenses) 'e:${e.id}']);
      }

      // Only the settlements that changed. Re-sending all of them re-sent
      // every stale status this phone held, and the one that was not ours to
      // move took the group's whole sync down with it.
      final settlements = [for (final s in group.settlements) if (dirty('s:${s.id}')) s];
      if (settlements.isNotEmpty) {
        await db.from('settlements').upsert([
          for (final s in settlements)
            {
              'id': s.id,
              'group_id': group.id,
              'from_member_id': s.fromId,
              'to_member_id': s.toId,
              'amount': s.amount,
              'status': s.status.name,
              'utr': s.utr,
              if (settlementExtras) 'is_offset': s.offset,
              'claimed_at': _stamp(s.date),
              'claimed_by': me,
              'confirmed_at': s.confirmedAt == null ? null : _stamp(s.confirmedAt!),
              if (settlementExtras && fresh('s:${s.id}')) 'deleted_at': null,
            },
        ]);
        landed([for (final s in settlements) 's:${s.id}']);
      }

      await _applyTombstones(group, extended: extended, settlementExtras: settlementExtras);
      _store.markGroupSynced(group);
      if (!_store.hasPendingChanges) _store.setSyncTrouble(false);
      return true;
    } catch (e) {
      // Loud on purpose, and the rows that did not land stay marked unsent, so
      // the next successful pull tries them again.
      final session = Backend.session;
      debugPrint(
        'mull: PUSH FAILED for "${group.title}" (${sent.length} rows landed first). $e\n'
        'mull:   uid=${Backend.user?.id} hasSession=${session != null} '
        'expired=${session?.isExpired} expiresAt=${session?.expiresAt}',
      );
      // The server refusing something is a bug to hear about, not weather.
      // Until now it only ever reached the console of a phone on a desk.
      if (e is PostgrestException) {
        ErrorReporter.report(e, StackTrace.current, context: 'push (${sent.length} rows landed first)');
      }
      _store.setSyncTrouble(true);
      return false;
    }
  }

  /// Makes the server's shares for one row exactly [shares].
  ///
  /// An upsert can add and change shares but never remove one, so taking Dev
  /// out of a dinner left his old share on the server, the next pull put it
  /// back, and the split no longer added up to the bill — for everyone.
  Future<void> _replaceShares(String table, String parent, String id, Map<String, int> shares) async {
    final db = Backend.client;
    await db.from(table).upsert([
      for (final entry in shares.entries) {parent: id, 'member_id': entry.key, 'amount': entry.value},
    ]);
    await db.from(table).delete().eq(parent, id).not('member_id', 'in', shares.keys.toList());
  }

  /// Anything this phone has not managed to send yet: groups with unsent rows
  /// or deletions, and groups deleted outright.
  Future<void> _retryPending() async {
    if (!_live) return;
    for (final id in [..._store.pendingGroupDeletes]) {
      await deleteGroup(id);
    }
    for (final group in [..._store.groups.where((g) => g.hasPendingChanges)]) {
      await push(group.id);
    }
  }

  /// Passes on the deletions this phone made.
  ///
  /// Soft deletes where the table has a `deleted_at`, because a balance that
  /// changes should leave a trace. Members are removed outright — a seat is not
  /// history; the expenses referencing it are. Each kind is tried on its own,
  /// and anything that fails keeps its tombstone for the next push.
  Future<void> _applyTombstones(
    Group group, {
    required bool extended,
    required bool settlementExtras,
  }) async {
    if (group.tombstones.isEmpty) return;
    final db = Backend.client;
    final done = <Tombstone>[];

    Future<void> attempt(Tombstone t, Future<void> Function() call) async {
      try {
        await call();
        done.add(t);
      } catch (e) {
        debugPrint('mull: could not delete ${t.kind.name} ${t.id} ($e)');
      }
    }

    for (final t in [...group.tombstones]) {
      switch (t.kind) {
        case TombstoneKind.expense:
          await attempt(
            t,
            () => db.from('expenses').update({'deleted_at': _stamp(DateTime.now())}).eq('id', t.id),
          );
        case TombstoneKind.recurring:
          if (!extended) continue;
          await attempt(
            t,
            () => db.from('recurring_expenses').update({'deleted_at': _stamp(DateTime.now())}).eq('id', t.id),
          );
        case TombstoneKind.settlement:
          if (!settlementExtras) continue;
          await attempt(
            t,
            () => db.from('settlements').update({'deleted_at': _stamp(DateTime.now())}).eq('id', t.id),
          );
        case TombstoneKind.member:
          await attempt(t, () => db.from('members').delete().eq('id', t.id));
      }
    }

    _store.clearTombstones(group, done);
  }

  /// An instant, said in a way Postgres cannot misread.
  ///
  /// `toIso8601String()` on a local time writes no offset, and Postgres reads
  /// a naive timestamp as UTC — so a delete made at 23:00 IST was stored five
  /// and a half hours in the future. Going through UTC puts the `Z` back on.
  static String _stamp(DateTime t) => t.toUtc().toIso8601String();

  /// A `date` column wants a date, not an instant. Sending the ISO timestamp
  /// works until someone in IST adds rent at half past midnight and it lands on
  /// the day before.
  static String _day(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  /// Soft delete: a balance that silently changes is a balance nobody trusts.
  ///
  /// Retried until it lands. It used to be tried once, and a delete made with
  /// no signal was forgotten and the group came back on the next pull.
  Future<void> deleteGroup(String groupId) async {
    if (!_live) return;
    await _exclusive(() async {
      if (!_store.pendingGroupDeletes.contains(groupId)) return;
      try {
        await Backend.client.from('groups').update({'deleted_at': _stamp(DateTime.now())}).eq('id', groupId);
        _store.clearGroupDelete(groupId);
      } on PostgrestException catch (e) {
        debugPrint('mull: deleteGroup refused ($e)');
        // A refusal is final — the server has said this account may not. The
        // group comes back on the next pull, which is the truth.
        if (e.code == '42501') _store.clearGroupDelete(groupId);
      } catch (e) {
        debugPrint('mull: deleteGroup failed, will retry ($e)');
      }
    });
  }

  // --------------------------------------------------------------- realtime

  StreamSubscription<String>? _changes;

  /// Pulls when the server says a group changed, and catches up whenever the
  /// socket comes back.
  void listen() {
    if (!_live || _changes != null) return;
    final live = LiveChannel.instance;
    _changes = live.groupChanged.listen((_) => _bump());
    live.connected.addListener(_onConnection);
    live.open();
    _onConnection();
  }

  void _onConnection() {
    if (LiveChannel.instance.connected.value) {
      // Whatever happened while it was down came through nothing.
      _startPolling(_pollWhileLive);
      unawaited(pull());
    } else {
      _startPolling(_pollWhileDown);
    }
  }

  /// The backstop under realtime. Only runs while the app is in the
  /// foreground, because iOS suspends timers the moment it is not.
  void _startPolling(Duration every) {
    _poll?.cancel();
    _poll = Timer.periodic(every, (_) {
      if (_live) unawaited(pull());
    });
  }

  /// A push touches several rows in quick succession — an expense, then its
  /// shares — so coalesce the nudges into a single pull.
  void _bump() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), pull);
  }

  /// Brings everything back up after a spell in the background, and answers
  /// "is this current?" for a pull-to-refresh.
  ///
  /// The pull is awaited either way. It used to be skipped when the channel
  /// needed rebuilding, so a caller waiting on fresh data got none — and the
  /// schedules that add themselves ran against a copy that was out of date.
  Future<void> resume() async {
    if (!_live) return;
    if (_changes == null) listen();
    LiveChannel.instance.open();
    await pull();
  }

  Future<void> stop() async {
    _debounce?.cancel();
    _poll?.cancel();
    _poll = null;
    for (final t in _pushTimers.values) {
      t.cancel();
    }
    _pushTimers.clear();
    await _changes?.cancel();
    _changes = null;
    LiveChannel.instance.connected.removeListener(_onConnection);
  }
}
