import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../core/dates.dart';
import '../core/money.dart';
import '../core/split.dart';
import '../core/upi_receipt.dart';
import 'models.dart';

/// How many reminders one person may send another, and over what.
///
/// Two. One is a favour to both sides; the second is a fair "did you see
/// this?"; the third is nagging, and an app that makes nagging effortless is
/// an app people leave. A rolling day rather than a calendar one, because
/// midnight is not a reset anybody experiences — two at 11pm and two more at
/// 12:05am is four buzzes inside ten minutes and technically within the rules.
///
/// This copy is so the button can say so before it is pressed. The limit that
/// actually holds is counted on the server, where reinstalling does not clear
/// it.
const kNudgesPerDay = 2;
const kNudgeWindow = Duration(hours: 24);

/// Single source of truth. Local-first: everything is persisted to one JSON file.
class MullStore extends ChangeNotifier {
  MullStore._(this._file);

  final File? _file;
  Timer? _saveTimer;

  Profile profile = Profile();
  final List<Group> groups = [];

  /// Injectable for tests.
  DateTime Function() clock = DateTime.now;
  DateTime now() => clock();

  /// Pushes a changed group to the server. Set once the backend is up; left
  /// null in tests and in a signed-out app, where groups are simply local.
  Future<void> Function(Group group)? onGroupChanged;

  /// Called after a group is deleted, so the server can tombstone it.
  Future<void> Function(String groupId)? onGroupDeleted;

  /// Asks the backend for everything again. Set alongside the push hooks; null
  /// in tests and in a signed-out app, where there is nothing to ask.
  Future<void> Function()? onPullRequested;

  /// Tells the people a local change actually affects that it happened.
  ///
  /// Only fired by real edits made on this phone. A pull replaces the whole
  /// ledger and must stay silent, or every device would announce everyone
  /// else's work back to them.
  void Function(Notice notice)? onNotice;

  /// What to call a member *in a sentence somebody else will read*.
  ///
  /// [shortName] answers "You" for your own seat, which is right on every
  /// screen in this app and wrong in every notification it sends: "You says
  /// they sent you ₹500" is what that produces on the other person's phone.
  String _theirNameFor(Member m) {
    final name = (m.isYou ? profile.name : m.name).trim();
    return name.isEmpty ? 'Someone' : name.split(' ').first;
  }

  void _tell(Notice? notice) {
    if (notice == null || notice.to.isEmpty) return;
    onNotice?.call(notice);
  }

  /// The account ids of the people in a group who could actually be told —
  /// a placeholder seat has nobody behind it — minus yourself.
  List<String> _reachable(Group group, Iterable<String> memberIds) {
    final me = group.you?.id;
    final seen = <String>{};
    return [
      for (final id in memberIds)
        if (id != me)
          if (group.memberById(id)?.userId case final user? when seen.add(user)) user,
    ];
  }

  /// Fetches the shared ledger now rather than waiting for a realtime event.
  ///
  /// Realtime is the fast path and not a guarantee — a socket that dropped in
  /// a tunnel reconnects silently and the events that happened meanwhile are
  /// simply gone. Anything that wants to be *sure* the screen is current (a
  /// resume, a pull-to-refresh, a poll) comes through here.
  Future<void> pullNow() async => onPullRequested?.call();

  /// Local edit first, network afterwards — the UI should never wait on a
  /// round trip to feel like it worked.
  void _commitGroup(Group group) {
    _commit();
    onGroupChanged?.call(group);
  }

  /// Folds what the server sent into what is on this phone.
  ///
  /// The server is the authority on every row this phone has not changed. A
  /// row that *has* been changed here and not yet accepted — its print differs
  /// from [Group.acked] — keeps the local version, and so does a row the
  /// server has never seen. This used to replace everything, which meant an
  /// edit whose push had failed (no signal, a refused policy) was erased by
  /// the next pull, twenty seconds later, from the phone that made it.
  ///
  /// A row the server used to have and no longer returns was deleted by
  /// somebody else and goes, edited here or not: an edit to something that no
  /// longer exists has nowhere to land. A row this phone deleted stays deleted
  /// until its tombstone has been passed on, even if the server still has it.
  ///
  /// [keepLocalSchedules] is for a project that has not had the recurring
  /// migration applied: the server cannot carry schedules, so an answer with
  /// none means "this server does not do schedules", not "they were deleted".
  void replaceGroups(List<Group> incoming, {bool keepLocalSchedules = false}) {
    final held = {for (final g in groups) g.id: g};

    // A group the server has never acknowledged survives a pull it is missing
    // from: the push has not landed yet, or failed. A group it *has* seen and
    // no longer returns was deleted, or you left it.
    final unsynced = [
      for (final g in groups)
        if (!g.hasReachedServer && !incoming.any((i) => i.id == g.id)) g,
    ];

    final merged = <Group>[
      for (final server in incoming)
        if (!pendingGroupDeletes.contains(server.id))
          held[server.id] == null
              ? server
              : _merge(held[server.id]!, server, keepLocalSchedules: keepLocalSchedules),
    ];

    groups
      ..clear()
      ..addAll(merged)
      ..addAll(unsynced);
    _commit();
  }

  Group _merge(Group local, Group server, {required bool keepLocalSchedules}) {
    final before = local.acked;
    // A group synced by a version of Mull that kept no record of what the
    // server had. There is nothing to tell a local edit from a stale copy by,
    // so the server wins this once, which is what every pull used to do.
    final legacy = before.isEmpty && local.hasReachedServer;
    final gone = {for (final t in local.tombstones) '${t.kind.name}:${t.id}'};

    List<T> rows<T>(
      String prefix,
      TombstoneKind kind,
      List<T> mine,
      List<T> theirs,
      String Function(T) idOf,
      String Function(T) printOf,
    ) {
      final localById = {for (final r in mine) idOf(r): r};
      final out = <T>[];
      for (final row in theirs) {
        final id = idOf(row);
        if (gone.contains('${kind.name}:$id')) continue;
        final here = localById[id];
        final changedHere = here != null && !legacy && before['$prefix:$id'] != printOf(here);
        out.add(changedHere ? here : row);
      }
      final served = {for (final r in theirs) idOf(r)};
      for (final row in mine) {
        final id = idOf(row);
        // Never accepted by the server, so not a deletion: still on its way up.
        if (!served.contains(id) && !before.containsKey('$prefix:$id')) out.add(row);
      }
      return out;
    }

    final members = rows<Member>(
      'm', TombstoneKind.member, local.members, server.members, (m) => m.id, (m) => m.syncPrint,
    );
    // When you last chased someone is this phone's business and has no column
    // anywhere, so it has to survive a pull or every refresh re-arms the nudge.
    for (final member in members) {
      if (member.nudges.isEmpty) {
        member.nudges.addAll(local.memberById(member.id)?.nudges ?? const []);
      }
    }

    // Only an admin's rename is kept — anyone else's would be refused by the
    // server, and holding it here would hold it forever.
    final groupChangedHere = !legacy && local.youAreAdmin && before['g'] != local.groupPrint;
    final acked = Map.of(server.printed);
    final recurring = keepLocalSchedules && server.recurring.isEmpty
        ? local.recurring
        : rows<Recurring>(
            'r', TombstoneKind.recurring, local.recurring, server.recurring, (r) => r.id, (r) => r.syncPrint,
          );
    if (keepLocalSchedules && server.recurring.isEmpty) {
      for (final e in before.entries) {
        if (e.key.startsWith('r:')) acked[e.key] = e.value;
      }
    }

    return Group(
      id: server.id,
      name: groupChangedHere ? local.name : server.name,
      kind: server.kind,
      icon: groupChangedHere ? local.icon : server.icon,
      members: members,
      expenses: rows<Expense>(
        'e', TombstoneKind.expense, local.expenses, server.expenses, (e) => e.id, (e) => e.syncPrint,
      ),
      settlements: rows<Settlement>(
        's', TombstoneKind.settlement, local.settlements, server.settlements, (s) => s.id, (s) => s.syncPrint,
      ),
      recurring: recurring,
      tombstones: local.tombstones,
      acked: acked,
      createdAt: server.createdAt,
      syncedAt: server.syncedAt,
    );
  }

  /// Groups deleted on this phone that the server has not yet been told
  /// about. Kept, and persisted, for the same reason as [Group.tombstones]: a
  /// delete made with no signal used to be forgotten, and the next pull
  /// handed the group straight back.
  final Set<String> pendingGroupDeletes = {};

  /// The sync saying the server has the deletion.
  void clearGroupDelete(String groupId) {
    if (pendingGroupDeletes.remove(groupId)) _commit();
  }

  /// Records that the server accepted these rows as they were printed.
  void ackRows(Group group, Map<String, String> prints) {
    if (prints.isEmpty) return;
    group.acked.addAll(prints);
    _commit();
  }

  /// Set by the sync when a push or pull has failed and cleared once
  /// everything has gone up. Not persisted: it describes this session.
  bool syncTrouble = false;

  void setSyncTrouble(bool value) {
    if (syncTrouble == value) return;
    syncTrouble = value;
    notifyListeners();
  }

  /// Whether anything on this phone has not reached the server yet.
  bool get hasPendingChanges =>
      pendingGroupDeletes.isNotEmpty || groups.any((g) => g.hasPendingChanges);

  /// Notes that the server has taken a copy. Local-only: re-pushing here would
  /// loop, since a push is what got us here.
  void markGroupSynced(Group group) {
    group.syncedAt = now();
    _commit();
  }

  /// Records that a row was deleted here, so the push can say so.
  ///
  /// An upsert cannot express a deletion — it only ever says "this row
  /// exists" — so without this the row lived on server-side and the next pull
  /// handed it straight back, moving everyone's balance with it.
  void _tombstone(Group group, String id, TombstoneKind kind) {
    if (group.tombstones.any((t) => t.id == id && t.kind == kind)) return;
    group.tombstones.add(Tombstone(id: id, kind: kind));
  }

  /// Undo, before the delete has been anywhere. Takes the tombstone back off
  /// rather than letting a push chase a row that is on screen again.
  void _untombstone(Group group, String id, TombstoneKind kind) {
    group.tombstones.removeWhere((t) => t.id == id && t.kind == kind);
  }

  /// The sync saying it has passed these on. Dropping them here is safe: the
  /// row is soft-deleted server-side now, so no pull can bring it back.
  void clearTombstones(Group group, Iterable<Tombstone> applied) {
    if (applied.isEmpty) return;
    final done = {for (final t in applied) '${t.kind.name}:${t.id}'};
    group.tombstones.removeWhere((t) => done.contains('${t.kind.name}:${t.id}'));
    _commit();
  }

  // ---------------------------------------------------------------- lifecycle

  static Future<MullStore> load() async {
    final dir = await getApplicationSupportDirectory();
    final file = File('${dir.path}/mull.json');
    final store = MullStore._(file);
    if (await file.exists()) {
      try {
        store._fromJson(jsonDecode(await file.readAsString()) as Map<String, dynamic>);
      } catch (e) {
        debugPrint('mull: could not read store, starting fresh ($e)');
        await file.copy('${dir.path}/mull.corrupt.${DateTime.now().millisecondsSinceEpoch}.json');
      }
    }
    return store;
  }

  /// In-memory store for tests and previews.
  factory MullStore.memory() => MullStore._(null);

  /// Loads a saved file straight in. Only for tests — the real path is [load],
  /// which has a disk read and a corruption fallback wrapped around this.
  @visibleForTesting
  void debugRestore(Map<String, dynamic> saved) => _fromJson(saved);

  /// Reads the file, including one written by a version of Mull that still had
  /// a wishlist in it.
  ///
  /// Wishlist, spends and lists are simply not read: they were always private
  /// to the phone, they are still in the file, and a version that reads them
  /// back has to have somewhere to put them. Groups carry over untouched,
  /// which is the part that was ever shared with anyone.
  void _fromJson(Map<String, dynamic> j) {
    profile = Profile.fromJson((j['profile'] as Map).cast());
    groups
      ..clear()
      ..addAll((j['groups'] as List? ?? []).map((e) => Group.fromJson((e as Map).cast())));
    pendingGroupDeletes
      ..clear()
      ..addAll((j['pendingGroupDeletes'] as List? ?? const []).cast<String>());
    _adoptLegacyRepeats(j);
  }

  /// Turns the old `repeatsMonthly` flag into a real schedule.
  ///
  /// The flag marked an expense as "this happens again" and nothing more — the
  /// app had to guess, by description, whether next month's had been added.
  /// Each flagged expense becomes one [Recurring] due a month after it, which
  /// is what the flag was always trying to say.
  void _adoptLegacyRepeats(Map<String, dynamic> j) {
    final saved = (j['groups'] as List? ?? []).cast<Map>();
    for (final raw in saved) {
      final group = groups.where((g) => g.id == raw['id']).firstOrNull;
      if (group == null || group.recurring.isNotEmpty) continue;

      final flagged = <String, Expense>{};
      for (final e in (raw['expenses'] as List? ?? const []).cast<Map>()) {
        if (e['repeatsMonthly'] != true) continue;
        final expense = group.expenses.where((x) => x.id == e['id']).firstOrNull;
        // Only the most recent of a repeated description becomes the schedule;
        // the earlier copies are its history, not three separate rents.
        if (expense == null) continue;
        final key = expense.description.trim().toLowerCase();
        final held = flagged[key];
        if (held == null || expense.date.isAfter(held.date)) flagged[key] = expense;
      }

      for (final expense in flagged.values) {
        final schedule = Recurring(
          description: expense.description,
          amount: expense.amount,
          payerId: expense.payerId,
          shares: Map.of(expense.shares),
          method: expense.method,
          frequency: Frequency.monthly,
          nextDue: addMonths(dayOf(expense.date), 1),
          lastAddedOn: dayOf(expense.date),
        );
        // Catch a schedule up to the present rather than letting it fire once
        // for every month the app was on the old version.
        if (schedule.nextDue.isBefore(dayOf(now()))) schedule.advance(now());
        group.recurring.add(schedule);
        expense.recurringId = schedule.id;
      }
    }
  }

  Map<String, dynamic> toJson() => {
    'version': 2,
    'profile': profile.toJson(),
    'groups': groups.map((e) => e.toJson()).toList(),
    'pendingGroupDeletes': pendingGroupDeletes.toList(),
  };

  void _commit() {
    notifyListeners();
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 250), flush);
  }

  Future<void> flush() async {
    _saveTimer?.cancel();
    final file = _file;
    if (file == null) return;
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(jsonEncode(toJson()), flush: true);
    await tmp.rename(file.path);
  }

  /// Re-evaluates time-based state — call on resume.
  ///
  /// Deliberately does *not* run the schedules that add themselves. Whoever
  /// runs those has to say what they created, and only the shell can put a
  /// toast on the screen; doing it here as well meant resume silently
  /// materialised them and the announcement found nothing left to announce.
  void refresh() => _commit();

  // ----------------------------------------------------------------- profile

  void completeOnboarding({required String name}) {
    profile
      ..name = name.trim()
      ..onboarded = true;
    _renameYourSeats();
    _commit();
  }

  /// Takes what the account already knows and finishes onboarding with it.
  ///
  /// Signing in on a new phone is not signing up. The account has a name and a
  /// UPI ID on it already, so asking for them again is asking a question the
  /// server can answer — and the answer it gets is whatever the person types
  /// the second time, which then overwrites the real one.
  void adoptAccount({required String name, String? upiId}) {
    profile
      ..name = name.trim()
      ..onboarded = true;
    if (upiId != null && upiId.trim().isNotEmpty) profile.upiId = upiId.trim();
    _renameYourSeats();
    _commit();
  }

  void updateProfile(void Function(Profile p) edit) {
    edit(profile);
    _renameYourSeats();
    _commit();
  }

  /// Your seat in every group carries your name, so changing it has to reach
  /// them — otherwise the people you split with keep seeing whatever you were
  /// called the day you made the group.
  void _renameYourSeats() {
    final name = profile.name.trim();
    if (name.isEmpty) return;
    for (final group in groups) {
      final you = group.you;
      if (you == null || you.name == name) continue;
      you.name = name;
      onGroupChanged?.call(group);
    }
  }

  // ------------------------------------------------------------------ groups

  /// [friends] are people with a Mull account, seated with `userId` attached so
  /// their name and UPI ID come from their own profile. [others] are bare names
  /// — placeholders for people who are not on Mull, which still need to work:
  /// you should be able to split tonight's dinner without everyone at the table
  /// installing something first.
  Group addGroup(
    String name,
    List<String> others, {
    List<Member> friends = const [],
    GroupKind kind = GroupKind.group,
    String? icon,
  }) {
    final group = Group(
      name: name.trim(),
      kind: kind,
      icon: icon,
      members: [
        // Whoever starts a group runs it. Not a privilege so much as an
        // answer: somebody has to be able to rename it, remove the person who
        // left, and eventually delete it, and "the person who made it" is the
        // only answer that needs no ceremony.
        Member(
          name: profile.name.isEmpty ? 'You' : profile.name,
          isYou: true,
          upiId: profile.upiId,
          role: MemberRole.admin,
        ),
        ...friends,
        for (final n in others)
          if (n.trim().isNotEmpty) Member(name: n.trim()),
      ],
    );
    groups.add(group);
    _commitGroup(group);
    _tell(
      Notice(
        to: _reachable(group, group.members.map((m) => m.id)),
        groupId: group.id,
        kind: NoticeKind.addedToGroup,
        title: '${_theirNameFor(group.you!)} added you to ${group.name}',
        body: '${group.members.length} people',
      ),
    );
    return group;
  }

  /// The one-to-one ledger with someone, made on first use.
  ///
  /// Not every debt belongs to a trip. You covered their cab; there is no
  /// "group" there and inventing one called "Me and Ritu" is the thing people
  /// hate about split apps. Underneath it is still a two-seat group, so it
  /// settles, syncs and simplifies exactly like the rest.
  Group directWith({
    required String name,
    String? userId,
    String? email,
    String? phone,
    String? upiId,
  }) {
    final existing = groups.where((g) {
      if (!g.isDirect) return false;
      final other = g.counterpart;
      if (other == null) return false;
      if (userId != null && other.userId != null) return other.userId == userId;
      if (email != null && other.email != null) {
        return other.email!.toLowerCase() == email.toLowerCase();
      }
      return other.name.trim().toLowerCase() == name.trim().toLowerCase();
    }).firstOrNull;
    if (existing != null) return existing;

    final group = Group(
      name: name.trim(),
      kind: GroupKind.direct,
      members: [
        // Both seats, because a one-to-one ledger has no hierarchy in it.
        // "What I owe Ritu" belongs to the two of you equally, and whoever
        // happened to open it first holding it hostage is not a power the
        // relationship has.
        Member(
          name: profile.name.isEmpty ? 'You' : profile.name,
          isYou: true,
          upiId: profile.upiId,
          role: MemberRole.admin,
        ),
        Member(
          name: name.trim(),
          userId: userId,
          email: email,
          phone: phone,
          upiId: upiId,
          role: MemberRole.admin,
        ),
      ],
    );
    groups.add(group);
    _commitGroup(group);
    return group;
  }

  Group? groupById(String id) => groups.where((g) => g.id == id).firstOrNull;

  /// Real groups — what the home screen lists under GROUPS.
  List<Group> get namedGroups => _ordered(groups.where((g) => !g.isDirect));

  /// One-to-one ledgers, under PEOPLE.
  List<Group> get directLedgers => _ordered(groups.where((g) => g.isDirect));

  /// What you owe first, then what you are owed, then whatever is settled.
  ///
  /// Not newest-first, and not by last activity. The home screen is a list of
  /// things to deal with, and the ₹6,250 you owe on the flat is more of a thing
  /// to deal with than the trip that ended square — even if somebody confirmed
  /// a payment on the trip an hour ago. Settled ledgers stay visible, because
  /// they are still who you split with, but they stop competing for the top.
  ///
  /// Sorted by direction before size, because sorting on the size alone put a
  /// ₹500 debt of yours above a ₹400 someone owes you and then swapped the two
  /// the moment either moved. A list whose rows change places while you are
  /// reading it is a list you stop trusting; money you owe is also the more
  /// urgent half, so it goes on top and stays there.
  List<Group> _ordered(Iterable<Group> of) => [...of]..sort((a, b) {
    int rank(Group g) => switch (g.yourBalance) { < 0 => 0, > 0 => 1, _ => 2 };
    final byDirection = rank(a).compareTo(rank(b));
    if (byDirection != 0) return byDirection;
    final byAmount = b.yourBalance.abs().compareTo(a.yourBalance.abs());
    if (byAmount != 0) return byAmount;
    return b.createdAt.compareTo(a.createdAt);
  });

  void updateGroup(Group group) => _commitGroup(group);

  /// Only an admin may delete a group — the server refuses anyone else, and
  /// a delete the server refuses used to vanish here and reappear on the next
  /// pull. Someone who is not an admin leaves instead.
  bool deleteGroup(Group group) {
    if (!group.youAreAdmin) return false;
    groups.removeWhere((g) => g.id == group.id);
    if (group.hasReachedServer) pendingGroupDeletes.add(group.id);
    _commit();
    onGroupDeleted?.call(group.id);
    return true;
  }

  /// Undo. The delete may already have reached the server, so the group's row
  /// is marked unsent, which makes the push say `deleted_at: null` out loud —
  /// an upsert that leaves the column alone would bring it back on this phone
  /// only, and the next pull would take it away again.
  void restoreGroup(Group group) {
    if (groups.any((g) => g.id == group.id)) return;
    pendingGroupDeletes.remove(group.id);
    group.acked.remove('g');
    groups.add(group);
    _commitGroup(group);
  }

  Member? addMember(Group group, String name) {
    if (name.trim().isEmpty) return null;
    final member = Member(name: name.trim());
    group.members.add(member);
    _commitGroup(group);
    return member;
  }

  /// Seats someone you are already friends with.
  ///
  /// The difference from [addMember] is `userId`: the seat arrives already
  /// attached to their account, so there is nothing to claim later and — more
  /// to the point — their UPI ID comes from their own profile rather than being
  /// typed in by you. A VPA entered by the payer is a payment to whoever
  /// happens to own that handle, and a typo pays a stranger successfully.
  Member? addFriendAsMember(
    Group group, {
    required String userId,
    required String name,
    String? email,
    String? upiId,
  }) {
    if (group.members.any((m) => m.userId == userId)) return null;
    final member = Member(name: name.trim(), userId: userId, email: email, upiId: upiId);
    group.members.add(member);
    _commitGroup(group);
    // Being put into a group is the one thing that happens *to* someone rather
    // than in front of them. Without this, the first they know of it is a
    // balance that appeared overnight.
    _tell(
      Notice(
        to: [userId],
        groupId: group.id,
        kind: NoticeKind.addedToGroup,
        title: '${_theirNameFor(group.you ?? member)} added you to ${group.title}',
        body: '${group.members.length} people',
      ),
    );
    return member;
  }

  /// Refuses to remove anyone the ledger still depends on — deleting a person
  /// who paid for dinner would silently rewrite what everyone else owes.
  ///
  /// Two different refusals live here and they are worth telling apart. The
  /// arithmetic one is absolute: nobody, admin or not, may remove a seat the
  /// ledger still references. The other is about authority — taking someone
  /// out of a group is an admin's decision — and it does not apply to leaving,
  /// which is always yours.
  bool canRemoveMember(Group group, Member member) {
    if (member.isYou || group.isDirect) return false;
    if (!group.youAreAdmin) return false;
    return !_ledgerNeeds(group, member);
  }

  bool _ledgerNeeds(Group group, Member member) {
    final involved = group.expenses.any((e) => e.payerId == member.id || e.shares.containsKey(member.id));
    final settled = group.settlements.any((s) => s.fromId == member.id || s.toId == member.id);
    final scheduled = group.recurring.any((r) => r.payerId == member.id || r.shares.containsKey(member.id));
    return involved || settled || scheduled;
  }

  /// Why the app will not remove someone, in the words it should say.
  String? whyMemberStays(Group group, Member member) {
    if (member.isYou || group.isDirect) return null;
    if (_ledgerNeeds(group, member)) {
      return 'They have paid for something or owe a share. Removing them would '
          'quietly change what everyone else owes.';
    }
    if (!group.youAreAdmin) return 'Only an admin can take someone out of a group.';
    return null;
  }

  bool removeMember(Group group, Member member) {
    if (!canRemoveMember(group, member)) return false;
    group.members.removeWhere((m) => m.id == member.id);
    _tombstone(group, member.id, TombstoneKind.member);
    _commitGroup(group);
    return true;
  }

  // -------------------------------------------------------------------- admin

  /// Hands the group over, or takes it back.
  ///
  /// Refuses to leave a group with nobody running it. That state cannot be
  /// repaired from inside the app: there would be no one who could rename it,
  /// remove the person who moved out, or delete it when the trip is over.
  bool setAdmin(Group group, Member member, bool admin) {
    if (!group.youAreAdmin || group.isDirect) return false;
    if (member.isAdmin == admin) return true;
    if (!admin && group.admins.length < 2) return false;
    member.role = admin ? MemberRole.admin : MemberRole.member;
    _commitGroup(group);
    return true;
  }

  /// Leaving is always yours to do — but not at the cost of the ledger's
  /// arithmetic, and not if it would leave the group unadministered.
  String? whyYouCannotLeave(Group group) {
    final you = group.you;
    if (you == null) return null;
    if (group.isDirect) return null;
    if (_ledgerNeeds(group, you)) {
      return 'You have paid for something or owe a share here. Settle up first, '
          'or the numbers stop adding up for everyone else.';
    }
    if (you.isAdmin && group.admins.length < 2 && group.members.length > 1) {
      return 'You are the only admin. Make someone else one first, so the group '
          'still has somebody who can run it.';
    }
    return null;
  }

  bool leaveGroup(Group group) {
    final you = group.you;
    if (you == null || whyYouCannotLeave(group) != null) return false;
    group.members.removeWhere((m) => m.id == you.id);
    // Your seat has to be deleted on the server too, or the group is handed
    // straight back by the next pull and leaving does nothing at all. The push
    // below carries the tombstone while the group is still in hand.
    _tombstone(group, you.id, TombstoneKind.member);
    _commitGroup(group);
    // Gone from this phone as well: without a seat in it there is nothing here
    // to see, and the next pull will not return it.
    groups.removeWhere((g) => g.id == group.id);
    _commit();
    return true;
  }

  /// The mark a group carries in a list. Null means the app draws the default.
  void setGroupIcon(Group group, String? icon) {
    if (!group.youAreAdmin) return;
    group.icon = icon;
    _commitGroup(group);
  }

  void setUpiId(Member member, String? upiId) {
    final value = upiId?.trim();
    member.upiId = value == null || value.isEmpty ? null : value;
    if (member.isYou) profile.upiId = member.upiId;
    final owner = groups.where((g) => g.members.any((m) => m.id == member.id)).firstOrNull;
    if (owner != null) {
      _commitGroup(owner);
    } else {
      _commit();
    }
  }

  void setPhone(Member member, String? phone) {
    final value = phone?.trim();
    member.phone = value == null || value.isEmpty ? null : value;
    final owner = groups.where((g) => g.members.any((m) => m.id == member.id)).firstOrNull;
    if (owner != null) _commitGroup(owner);
  }

  // ---------------------------------------------------------------- expenses

  Expense addExpense(
    Group group, {
    String? id,
    required String description,
    required int amount,
    required String payerId,
    required Map<String, int> shares,
    SplitMethod method = SplitMethod.equal,
    String? recurringId,
    String? note,
    DateTime? date,
  }) {
    final expense = Expense(
      id: id,
      description: description.trim(),
      amount: amount,
      payerId: payerId,
      shares: Map.of(shares),
      method: method,
      recurringId: recurringId,
      note: note?.trim().isEmpty ?? true ? null : note!.trim(),
      date: date ?? now(),
    );
    group.expenses.add(expense);
    _commitGroup(group);
    _tell(_expenseNotice(group, expense));
    return expense;
  }

  /// Everyone whose money this expense moves, and nobody else.
  ///
  /// The parties are the people in the split plus whoever paid — not the
  /// group. Eight flatmates should not each get a buzz because two of them
  /// split a chai, and a member who sat this one out has nothing to check.
  Notice? _expenseNotice(Group group, Expense expense) {
    final payer = group.memberById(expense.payerId);
    final to = _reachable(group, {expense.payerId, ...expense.shares.keys});
    if (to.isEmpty || payer == null) return null;
    // Deliberately impersonal. One notice carries one sentence to several
    // people, so anything phrased as "your share" would be *this* phone's
    // share read out to everybody else. The group screen is one tap away and
    // knows what each person owes.
    // The title names whoever typed it in, like an edit or a delete does. The
    // payer is a different fact: "Sahil added Chai" when Ananya added it and
    // said Sahil paid reads as Sahil having done something he did not.
    final adder = group.you ?? payer;
    final paidBy = payer.id == adder.id ? '' : ' · ${_theirNameFor(payer)} paid';
    return Notice(
      to: to,
      groupId: group.id,
      kind: NoticeKind.expenseAdded,
      title: '${_theirNameFor(adder)} added ${expense.description}',
      body: '${inr(expense.amount)} · ${group.isDirect ? 'with you' : group.title}$paidBy',
      amount: expense.amount,
    );
  }

  /// An edit is a balance change for everyone in the split, so it is
  /// announced like one.
  ///
  /// Adding an expense told people and changing one did not, which meant a
  /// ₹500 dinner could become a ₹5,000 one and the only sign was a number
  /// moving on somebody's home screen. The whole claim-and-confirm design
  /// rests on nothing about the money changing quietly.
  void updateExpense(Group group, Expense expense, {Expense? before}) {
    _commitGroup(group);
    final payer = group.memberById(expense.payerId);
    final to = _reachable(group, {
      expense.payerId,
      ...expense.shares.keys,
      if (before != null) before.payerId,
      if (before != null) ...before.shares.keys,
    });
    if (to.isEmpty || payer == null) return;
    final amountMoved = before != null && before.amount != expense.amount;
    _tell(
      Notice(
        to: to,
        groupId: group.id,
        kind: NoticeKind.expenseChanged,
        title: '${_theirNameFor(group.you ?? payer)} changed ${expense.description}',
        body: amountMoved
            ? '${inr(before.amount)} → ${inr(expense.amount)} · ${group.isDirect ? 'with you' : group.title}'
            : '${inr(expense.amount)} · ${group.isDirect ? 'with you' : group.title}',
        amount: expense.amount,
      ),
    );
  }

  /// Everyone an expense used to involve, told that it is gone.
  Notice? _expenseGoneNotice(Group group, Expense expense) {
    final to = _reachable(group, {expense.payerId, ...expense.shares.keys});
    final payer = group.memberById(expense.payerId);
    if (to.isEmpty || payer == null) return null;
    return Notice(
      to: to,
      groupId: group.id,
      kind: NoticeKind.expenseRemoved,
      title: '${_theirNameFor(group.you ?? payer)} deleted ${expense.description}',
      body: '${inr(expense.amount)} · ${group.isDirect ? 'with you' : group.title}',
      amount: expense.amount,
    );
  }

  void removeExpense(Group group, Expense expense) {
    group.expenses.removeWhere((e) => e.id == expense.id);
    _tombstone(group, expense.id, TombstoneKind.expense);
    _commitGroup(group);
    _tell(_expenseGoneNotice(group, expense));
  }

  void restoreExpense(Group group, Expense expense) {
    if (group.expenses.any((e) => e.id == expense.id)) return;
    group.expenses.add(expense);
    _untombstone(group, expense.id, TombstoneKind.expense);
    // Marked unsent, so the push clears `deleted_at` if the delete already
    // landed. See [restoreGroup].
    group.acked.remove('e:${expense.id}');
    _commitGroup(group);
  }

  // --------------------------------------------------------------- recurring

  Recurring addRecurring(
    Group group, {
    required String description,
    required int amount,
    required String payerId,
    required Map<String, int> shares,
    SplitMethod method = SplitMethod.equal,
    Frequency frequency = Frequency.monthly,
    required DateTime startsOn,
    DateTime? endsOn,
    bool autoAdd = false,
  }) {
    final schedule = Recurring(
      description: description.trim(),
      amount: amount,
      payerId: payerId,
      shares: Map.of(shares),
      method: method,
      frequency: frequency,
      nextDue: dayOf(startsOn),
      endsOn: endsOn == null ? null : dayOf(endsOn),
      autoAdd: autoAdd,
    );
    group.recurring.add(schedule);
    _commitGroup(group);
    return schedule;
  }

  void updateRecurring(Group group, Recurring schedule) => _commitGroup(group);

  void removeRecurring(Group group, Recurring schedule) {
    group.recurring.removeWhere((r) => r.id == schedule.id);
    _tombstone(group, schedule.id, TombstoneKind.recurring);
    // The expenses it already produced are real money that changed hands, so
    // they stay. They simply stop belonging to a schedule.
    for (final e in group.expenses) {
      if (e.recurringId == schedule.id) e.recurringId = null;
    }
    _commitGroup(group);
  }

  void restoreRecurring(Group group, Recurring schedule) {
    if (group.recurring.any((r) => r.id == schedule.id)) return;
    group.recurring.add(schedule);
    _untombstone(group, schedule.id, TombstoneKind.recurring);
    group.acked.remove('r:${schedule.id}');
    _commitGroup(group);
  }

  void setRecurringPaused(Group group, Recurring schedule, bool paused) {
    schedule.paused = paused;
    // Coming back from a pause should not fire off every period that went by
    // while it was off — the point of pausing was that those did not happen.
    if (!paused && schedule.nextDue.isBefore(dayOf(now()))) {
      schedule.nextDue = dayOf(now());
    }
    _commitGroup(group);
  }

  /// Everything owed right now, across every group, soonest first.
  List<(Group, Recurring)> get dueRecurring {
    final t = now();
    final out = [
      for (final g in groups)
        for (final r in g.recurring)
          if (r.isDue(t)) (g, r),
    ];
    out.sort((a, b) => a.$2.nextDue.compareTo(b.$2.nextDue));
    return out;
  }

  /// What is coming but has not landed yet — the next two weeks.
  List<(Group, Recurring)> get upcomingRecurring {
    final t = now();
    final horizon = dayOf(t).add(const Duration(days: 14));
    final out = [
      for (final g in groups)
        for (final r in g.recurring)
          if (r.isActive && !r.isDue(t) && !r.nextDue.isAfter(horizon)) (g, r),
    ];
    out.sort((a, b) => a.$2.nextDue.compareTo(b.$2.nextDue));
    return out;
  }

  /// Turns a due schedule into a real expense and moves it on.
  ///
  /// [amount] and [shares] are overridable because the whole reason this is a
  /// confirmation rather than a cron job is that the rent went up, or Dev was
  /// away this month. What is confirmed is what gets recorded.
  Expense addDue(
    Group group,
    Recurring schedule, {
    int? amount,
    Map<String, int>? shares,
    String? payerId,
    DateTime? date,
  }) {
    final on = dayOf(date ?? schedule.nextDue);
    // The same id on every phone for the same schedule and day. Every member
    // of a flat sees the rent fall due, and a schedule set to add itself does
    // so on each of their phones at once; with random ids that was the rent
    // charged four times. See [stableId].
    final id = stableId('${schedule.id}|${on.year}-${on.month}-${on.day}');
    final already = group.expenses.where((e) => e.id == id).firstOrNull;
    if (already != null) {
      schedule
        ..lastAddedOn = on
        ..advance(now());
      _commitGroup(group);
      return already;
    }
    final expense = addExpense(
      group,
      id: id,
      description: schedule.description,
      amount: amount ?? schedule.amount,
      payerId: payerId ?? schedule.payerId,
      shares: shares ?? schedule.shares,
      method: schedule.method,
      recurringId: schedule.id,
      date: on,
    );
    // A confirmed change is the new normal — next month should not ask about
    // the old rent again.
    if (amount != null) schedule.amount = amount;
    if (shares != null) schedule.shares = Map.of(shares);
    if (payerId != null) schedule.payerId = payerId;
    schedule
      ..lastAddedOn = on
      ..advance(now());
    _commitGroup(group);
    return expense;
  }

  /// "Not this month." Moves the schedule on without recording anything.
  void skipDue(Group group, Recurring schedule) {
    schedule.advance(now());
    _commitGroup(group);
  }

  /// Materialises every schedule that was told to add itself.
  ///
  /// Returns what it created so the app can say so. Silence would be the
  /// failure mode that matters here: an expense nobody was told about is one
  /// nobody checked, and it is moving real money between real people.
  List<(Group, Expense)> runAutoRecurring() {
    final made = <(Group, Expense)>[];
    for (final (group, schedule) in dueRecurring) {
      if (!schedule.autoAdd) continue;
      made.add((group, addDue(group, schedule)));
    }
    return made;
  }

  // -------------------------------------------------------------- settle up

  /// Records a payment — as a fact if there is nobody who could dispute it, as
  /// a claim if there is.
  ///
  /// Confirming is the payee's call, so recording money you *received* settles
  /// it outright. Recording money you *sent* leaves it pending until they say
  /// it landed. The exception is a seat nobody has claimed: a placeholder
  /// cannot confirm anything, so waiting on one would leave the debt hanging
  /// forever with no way to clear it.
  Settlement settleUp(
    Group group, {
    required String fromId,
    required String toId,
    required int amount,
    String? utr,
  }) {
    final me = group.you?.id;
    final payee = group.memberById(toId);
    final needsConfirming = me != toId && (payee?.isLinked ?? false);
    final settlement = Settlement(
      fromId: fromId,
      toId: toId,
      amount: amount,
      utr: utr,
      date: now(),
      status: needsConfirming ? SettlementStatus.pending : SettlementStatus.confirmed,
      confirmedAt: needsConfirming ? null : now(),
    );
    group.settlements.add(settlement);
    _commitGroup(group);
    // Settling is between two people even in a group of eight, so this goes to
    // the other end of the payment and stops there. The group does not need to
    // know, and telling it would turn every transfer into a public notice.
    final other = fromId == me ? toId : fromId;
    final mover = group.memberById(fromId);
    if (mover != null) {
      _tell(
        Notice(
          to: _reachable(group, [other]),
          groupId: group.id,
          kind: NoticeKind.settlementClaimed,
          title: needsConfirming
              ? '${_theirNameFor(mover)} says they sent you ${inr(amount)}'
              : '${_theirNameFor(mover)} settled ${inr(amount)}',
          body: needsConfirming
              ? 'Check it landed, then confirm it in ${group.title}'
              : group.title,
          amount: amount,
        ),
      );
    }
    return settlement;
  }

  /// Everything still waiting on somebody, in either direction.
  ///
  /// A disputed claim counts. It used to fall out of every list the moment it
  /// was disputed — not pending, not confirmed — so the payer was told once,
  /// in a notification they could miss, and then it was as if nothing had
  /// happened. A disagreement about money is the last thing an app should be
  /// quiet about.
  List<(Group, Settlement)> get openClaims => [
    for (final g in groups)
      for (final s in g.settlements)
        if (s.status != SettlementStatus.confirmed) (g, s),
  ];

  /// Claims you made that the other person has not answered, and the ones
  /// they have said never arrived. The half of the loop Mull never showed.
  List<(Group, Settlement)> get claimsAwaitingOthers => [
    for (final (g, s) in openClaims)
      if (s.fromId == g.you?.id) (g, s),
  ];

  // ------------------------------------------------- settling with a person

  /// Each ledger you share with someone, and what it is worth between the two
  /// of you. Positive means they owe you there.
  List<(Group, int)> ledgersWith(Standing standing) {
    final out = <(Group, int)>[];
    for (final group in groups) {
      final me = group.you?.id;
      final seat = standing.seats[group.id];
      if (me == null || seat == null) continue;
      final amount = group.pairBalance(me, seat);
      if (amount != 0) out.add((group, amount));
    }
    // Biggest first, so a payment clears whole ledgers rather than leaving a
    // trail of small remainders behind it.
    out.sort((a, b) => b.$2.abs().compareTo(a.$2.abs()));
    return out;
  }

  /// Whether one payment may be spread across this person's ledgers.
  ///
  /// Not when they were matched across groups by name alone. Showing two
  /// seats both called "Kabir" as one person is a guess worth making on
  /// screen; writing a confirmed offset or a payment between them is not,
  /// because if they are two people it moves money between strangers.
  bool canSettleAcross(Standing standing) => !standing.byNameOnly || ledgersWith(standing).length <= 1;

  /// Whether this person has debts pointing both ways that could cancel.
  bool canNetOff(Standing standing) {
    if (standing.byNameOnly) return false;
    final ledgers = ledgersWith(standing);
    return ledgers.any((l) => l.$2 > 0) && ledgers.any((l) => l.$2 < 0);
  }

  /// What would cancel if you netted off — the money neither of you has to
  /// send.
  int netOffAmount(Standing standing) {
    final up = ledgersWith(standing).where((l) => l.$2 > 0).fold(0, (s, l) => s + l.$2);
    final down = ledgersWith(standing).where((l) => l.$2 < 0).fold(0, (s, l) => s - l.$2);
    return up < down ? up : down;
  }

  /// Cancels equal and opposite debts with one person, across ledgers.
  ///
  /// This is the arithmetic everybody does in their head and no split app was
  /// doing for them. You owe Ananya 2,000 on the trip, she owes you 3,000 on
  /// the flat; nobody sends 5,000 in two directions, they send 1,000 once. The
  /// two 2,000s are written into both ledgers as offsets so each one is
  /// honestly square, and what is left is a single real payment.
  ///
  /// Confirmed on the spot, and it is the one place that is right to do so: no
  /// money is claimed to have moved, and neither person's net position changes
  /// by a rupee. There is nothing for the other side to verify.
  List<Settlement> netOff(Standing standing) {
    if (!canNetOff(standing)) return const [];
    final owed = [for (final l in ledgersWith(standing)) if (l.$2 > 0) l];
    final owing = [for (final l in ledgersWith(standing)) if (l.$2 < 0) (l.$1, -l.$2)];
    final written = <Settlement>[];
    var i = 0;
    var j = 0;
    var credit = owed.isEmpty ? 0 : owed.first.$2;
    var debit = owing.isEmpty ? 0 : owing.first.$2;

    while (i < owed.length && j < owing.length) {
      final amount = credit < debit ? credit : debit;
      if (amount > 0) {
        // In the ledger where they owe you, they have effectively paid you.
        written.add(_writeOffset(owed[i].$1, standing, theyPayYou: true, amount: amount));
        // In the ledger where you owe them, you have effectively paid them.
        written.add(_writeOffset(owing[j].$1, standing, theyPayYou: false, amount: amount));
      }
      credit -= amount;
      debit -= amount;
      if (credit == 0) {
        i++;
        if (i < owed.length) credit = owed[i].$2;
      }
      if (debit == 0) {
        j++;
        if (j < owing.length) debit = owing[j].$2;
      }
    }

    if (written.isNotEmpty) {
      final total = written.fold(0, (s, w) => s + w.amount) ~/ 2;
      _tell(
        Notice(
          to: [?standing.member.userId],
          groupId: null,
          kind: NoticeKind.nettedOff,
          title: '${_theirNameFor(_anySeatOf(standing) ?? standing.member)} netted off '
              '${inr(total)} with you',
          body: 'Debts pointing both ways cancelled. Nothing moved.',
          amount: total,
        ),
      );
    }
    return written;
  }

  /// Your own seat, for a sentence somebody else reads.
  Member? _anySeatOf(Standing standing) =>
      standing.groups.isEmpty ? null : standing.groups.first.you;

  Settlement _writeOffset(
    Group group,
    Standing standing, {
    required bool theyPayYou,
    required int amount,
  }) {
    final me = group.you!.id;
    final them = standing.seats[group.id]!;
    final settlement = Settlement(
      fromId: theyPayYou ? them : me,
      toId: theyPayYou ? me : them,
      amount: amount,
      status: SettlementStatus.confirmed,
      offset: true,
      date: now(),
      confirmedAt: now(),
    );
    group.settlements.add(settlement);
    _commitGroup(group);
    return settlement;
  }

  /// Records a real payment with one person, spread across the ledgers it
  /// clears.
  ///
  /// Nets off first, so the payment only ever has to cover what is genuinely
  /// left. Then it fills the largest ledger, then the next — which is what
  /// makes a part payment behave: 500 against 1,800 clears nothing outright
  /// and leaves one ledger 1,300 short rather than three ledgers all a bit
  /// short.
  List<Settlement> settleAcross(
    Standing standing, {
    required int amount,
    String? utr,
  }) {
    if (amount <= 0 || !canSettleAcross(standing)) return const [];
    netOff(standing);

    // Re-read: netting off has just moved every ledger.
    final ledgers = ledgersWith(standing);
    final theyOwe = standing.amount > 0;
    var left = amount;
    final written = <Settlement>[];

    for (final (group, balance) in ledgers) {
      if (left <= 0) break;
      // Only ledgers pointing the way the money is going.
      if (theyOwe && balance <= 0) continue;
      if (!theyOwe && balance >= 0) continue;
      final here = balance.abs() < left ? balance.abs() : left;
      final me = group.you!.id;
      final them = standing.seats[group.id]!;
      written.add(
        settleUp(
          group,
          fromId: theyOwe ? them : me,
          toId: theyOwe ? me : them,
          amount: here,
          utr: utr,
        ),
      );
      left -= here;
    }
    return written;
  }

  void confirmSettlement(Group group, Settlement settlement) {
    settlement
      ..status = SettlementStatus.confirmed
      ..confirmedAt = now();
    _commitGroup(group);
    final payer = group.memberById(settlement.fromId);
    if (payer == null) return;
    _tell(
      Notice(
        to: _reachable(group, [settlement.fromId]),
        groupId: group.id,
        kind: NoticeKind.settlementConfirmed,
        title: '${_theirNameFor(group.you ?? payer)} confirmed your ${inr(settlement.amount)}',
        body: 'That clears it in ${group.title}',
        amount: settlement.amount,
      ),
    );
  }

  /// "It turned up after all." Turns a dispute back into an open claim.
  ///
  /// Disputing was a one-way door: the claim stopped being pending, so it
  /// vanished from every list that could have acted on it, and the only way
  /// back was deleting the record entirely. A payment held up for two days and
  /// then found is an ordinary thing and should not cost anybody their
  /// evidence.
  void reopenSettlement(Group group, Settlement settlement) {
    if (settlement.status != SettlementStatus.disputed) return;
    settlement.status = SettlementStatus.pending;
    _commitGroup(group);
  }

  /// "I never got that." Keeps the record rather than deleting it, so the
  /// disagreement is visible to everyone instead of turning into a silent
  /// balance change.
  void disputeSettlement(Group group, Settlement settlement) {
    settlement
      ..status = SettlementStatus.disputed
      ..confirmedAt = null;
    _commitGroup(group);
    final payer = group.memberById(settlement.fromId);
    if (payer == null) return;
    // The one notice the app owes somebody more than any other. A disputed
    // payment that nobody is told about is a balance the payer believes is
    // clear and the payee believes is not, and the two of them find out weeks
    // later in an argument.
    _tell(
      Notice(
        to: _reachable(group, [settlement.fromId]),
        groupId: group.id,
        kind: NoticeKind.settlementDisputed,
        title: '${_theirNameFor(group.you ?? payer)} has not seen your ${inr(settlement.amount)}',
        body: 'It is still open in ${group.title}',
        amount: settlement.amount,
      ),
    );
  }

  /// Whether *you* may take a payment off the record.
  ///
  /// Only the two people it is between. A settlement is the evidence that a
  /// debt was cleared, and a third party in a group of eight being able to
  /// delete it — silently reopening money between two other people — was a
  /// long-press away.
  bool canRemoveSettlement(Group group, Settlement settlement) {
    final me = group.you?.id;
    return me != null && (settlement.fromId == me || settlement.toId == me);
  }

  /// Why the app will not remove it, in the words it should say.
  String? whySettlementStays(Group group, Settlement settlement) =>
      canRemoveSettlement(group, settlement)
          ? null
          : 'This payment is between two other people. Only they can take it '
              'off the record.';

  bool removeSettlement(Group group, Settlement settlement) {
    if (!canRemoveSettlement(group, settlement)) return false;
    group.settlements.removeWhere((s) => s.id == settlement.id);
    _tombstone(group, settlement.id, TombstoneKind.settlement);
    _commitGroup(group);
    // Removing a confirmed payment puts a debt back. The other end of it finds
    // out now rather than from a balance that moved overnight.
    final you = group.you;
    if (you == null) return true;
    final other = settlement.fromId == you.id ? settlement.toId : settlement.fromId;
    _tell(
      Notice(
        to: _reachable(group, [other]),
        groupId: group.id,
        kind: NoticeKind.settlementRemoved,
        title: '${_theirNameFor(you)} removed a ${inr(settlement.amount)} payment',
        body: settlement.clearsDebt
            ? 'That debt is open again in ${group.title}'
            : group.title,
        amount: settlement.amount,
      ),
    );
    return true;
  }

  void restoreSettlement(Group group, Settlement settlement) {
    if (group.settlements.any((s) => s.id == settlement.id)) return;
    group.settlements.add(settlement);
    _untombstone(group, settlement.id, TombstoneKind.settlement);
    group.acked.remove('s:${settlement.id}');
    _commitGroup(group);
  }

  /// The debt a UPI receipt most likely pays off.
  ///
  /// Matched on the payee's VPA first and the amount second, across every
  /// group, because the person sharing a receipt is not thinking about which
  /// group it belongs to. Returns null rather than guessing when nothing lines
  /// up — a receipt filed against the wrong debt is worse than one filed by
  /// hand.
  (Group, Transfer)? matchReceipt(UpiReceipt receipt) {
    if (receipt.failed) return null;
    final vpa = receipt.payeeUpiId?.toLowerCase();
    final amount = receipt.amount;
    if (vpa == null && amount == null) return null;

    final byAmountOnly = <(Group, Transfer)>[];
    for (final group in groups) {
      final me = group.you?.id;
      if (me == null) continue;
      for (final transfer in simplify(group.balances)) {
        if (transfer.from != me) continue; // only debts you are the one paying
        final payee = group.memberById(transfer.to);
        if (payee == null) continue;

        final vpaMatches = vpa != null && payee.upiId?.toLowerCase() == vpa;
        final amountMatches = amount != null && transfer.amount == amount;
        if (vpaMatches && (amountMatches || amount == null)) return (group, transfer);
        if (amountMatches) byAmountOnly.add((group, transfer));
      }
    }
    // One debt of that amount and nothing else it could be: take it. Two, and
    // the honest answer is none — it used to keep whichever it happened to see
    // first, which is iteration order deciding who got paid. A receipt filed
    // against the wrong debt is worse than one filed by hand.
    return byAmountOnly.length == 1 ? byAmountOnly.first : null;
  }

  /// Every claim across every group that is waiting on you.
  List<(Group, Settlement)> get confirmationsForYou => [
    for (final g in groups)
      for (final s in g.awaitingYourConfirmation) (g, s),
  ];

  // --------------------------------------------------------------- reminders

  /// How the same person is recognised across ledgers.
  ///
  /// An account id when there is one, then an email, then the name. The last
  /// is a guess and knowingly so: two seats both typed "Kabir" are treated as
  /// one person, which is right far more often than it is wrong, and the only
  /// alternative is chasing the same friend twice for the same money.
  String _personKey(Member m) =>
      m.userId ?? (m.email?.trim().toLowerCase().isNotEmpty ?? false
          ? m.email!.trim().toLowerCase()
          : m.name.trim().toLowerCase());

  /// Where you stand with every person you share a ledger with, netted.
  ///
  /// This is the number the app should have been showing all along. Owing
  /// Ananya 2,000 on the Goa trip while she owes you 3,000 on the flat is one
  /// fact — she owes you 1,000 — and Mull used to report it as two, then chase
  /// her for the larger half.
  ///
  /// Netted on [Group.pairBalance] rather than on the simplified transfers,
  /// because "what do I owe Ananya" has to mean Ananya. Simplification is an
  /// answer to a different question and belongs to the group screen that asks
  /// it.
  List<Standing> get standings {
    final byPerson = <String, Standing>{};
    for (final group in groups) {
      final me = group.you?.id;
      if (me == null) continue;
      for (final other in group.members) {
        if (other.isYou) continue;
        final amount = group.pairBalance(me, other.id);
        final key = _personKey(other);
        final held = byPerson[key];
        // Somebody square in this ledger is still somebody you split with, so
        // they keep their seat in the list — but a ledger that contributes
        // nothing is not one worth naming under their name.
        byPerson[key] = Standing(
          member: held?.member ?? other,
          amount: (held?.amount ?? 0) + amount,
          groups: [...?held?.groups, if (amount != 0) group],
          seats: {...?held?.seats, group.id: other.id},
          // The same person holds a separate seat in every group, and each
          // seat carries its own record of being chased. Netting the debt but
          // not the reminders would hand you a fresh allowance per group,
          // which is the same three messages this is meant to prevent.
          //
          // The longest history wins rather than the union of them. Every
          // nudge stamps *all* of that person's seats at the same instant, so
          // the fullest list is the true one — and merging them would depend
          // on two DateTimes written in the same breath comparing equal,
          // which is a coincidence to rely on rather than a rule.
          nudges: _longer(held?.nudges, other.nudges),
          byNameOnly: (held?.byNameOnly ?? true) && other.userId == null &&
              (other.email?.trim().isEmpty ?? true),
        );
      }
    }
    return byPerson.values.toList()
      ..sort((a, b) {
        // You owe, then you are owed, then square — the same order the ledger
        // list uses, so the two halves of the home screen read the same way.
        int rank(Standing s) => switch (s.amount) { < 0 => 0, > 0 => 1, _ => 2 };
        final byDirection = rank(a).compareTo(rank(b));
        if (byDirection != 0) return byDirection;
        final byAmount = b.magnitude.compareTo(a.magnitude);
        if (byAmount != 0) return byAmount;
        return a.member.name.toLowerCase().compareTo(b.member.name.toLowerCase());
      });
  }

  /// Everyone who owes you on balance, biggest first.
  List<Standing> get owedToYou => [
    for (final s in standings)
      if (s.theyOweYou) s,
  ];

  /// Everyone you owe on balance, biggest first. The half of the ledger Mull
  /// never used to show.
  List<Standing> get youOweThem => [
    for (final s in standings)
      if (s.youOwe) s,
  ];

  /// Where you stand with one person, or null if you share no ledger.
  Standing? standingWith(Member member) {
    final key = _personKey(member);
    return standings.where((s) => _personKey(s.member) == key).firstOrNull;
  }

  static List<DateTime> _longer(List<DateTime>? a, List<DateTime> b) =>
      (a?.length ?? 0) >= b.length ? [...?a] : [...b];

  /// How many more times you may chase this person today.
  int nudgesLeft(Standing standing) {
    final cutoff = now().subtract(kNudgeWindow);
    final spent = standing.nudges.where((n) => n.isAfter(cutoff)).length;
    return (kNudgesPerDay - spent).clamp(0, kNudgesPerDay);
  }

  bool canNudge(Standing standing) => standing.theyOweYou && nudgesLeft(standing) > 0;

  /// The message a nudge carries. Short, and it ends with the way to pay.
  ///
  /// Still written as plain sentences rather than as a screenful of fields.
  /// It arrives inside Mull now, but it is the same words either way, and
  /// someone reading "Ananya · ₹500 · Goa" on a lock screen should not have to
  /// open anything to know what is being asked.
  ///
  /// The amount is the netted one, so it can never ask for money you are
  /// holding half of yourself.
  String nudgeMessage(Standing standing) {
    final where = standing.groups.length == 1
        ? ' for ${standing.groups.first.title}'
        : ' across ${standing.groups.length} ledgers';
    final upi = profile.upiId;
    return [
      'Hey ${shortName(standing.member)}, ${inr(standing.amount)}$where when you get a chance.',
      if (upi != null) 'My UPI is $upi.',
      'No rush.',
    ].join(' ');
  }

  void markNudged(Standing standing) {
    final at = now();
    final cutoff = at.subtract(kNudgeWindow);
    for (final group in groups) {
      // Their seat in this group, by id rather than by name: the same person
      // is a different seat in every ledger, and matching on what they are
      // called breaks the moment somebody is renamed.
      final seatId = standing.seats[group.id];
      final seat = seatId == null ? null : group.memberById(seatId);
      if (seat == null) continue;
      seat.nudges
        // Anything older than the window can never affect the count again, and
        // keeping it would grow this list forever in a file the app rewrites
        // on every edit.
        ..removeWhere((n) => !n.isAfter(cutoff))
        ..add(at);
    }
    standing.nudges.add(at);
    _commit();
  }

  /// Brings the local count up to what the server just told us it is.
  ///
  /// The two can drift honestly: the allowance is per account, and a reminder
  /// sent from another phone never touched this one's copy. When the server
  /// says the allowance is gone, it is gone — arguing with it only means the
  /// button stays lit over a call that will keep being refused.
  void spendNudges(Standing standing) {
    var guard = 0;
    while (nudgesLeft(standing) > 0 && guard++ <= kNudgesPerDay) {
      markNudged(standing);
    }
  }

  // ---------------------------------------------------------------- readouts

  /// The expenses a later settlement has already cleared.
  ///
  /// There is no "paid" flag on an expense, and there should not be: an expense
  /// is a fact about a bill, not a debt. But there *is* an honest reading of
  /// "settled" available for free. Replay the ledger oldest first, and every
  /// time every balance in the group passes through zero, everything up to
  /// that moment has been paid for. Those rows stay in the ledger and stop
  /// asking for attention.
  Set<String> settledExpenses(Group group) {
    // By day, then by the moment it was written down. An expense only carries
    // a day once it has been through the server, so comparing it to a payment's
    // exact time put everything added on a day before every payment that day.
    final events = <(DateTime, DateTime, Object)>[
      for (final e in group.expenses) (dayOf(e.date), e.createdAt, e),
      for (final s in group.settlements)
        if (s.clearsDebt) (dayOf(s.date.toLocal()), s.date, s),
    ]..sort((a, b) {
        final byDay = a.$1.compareTo(b.$1);
        return byDay != 0 ? byDay : a.$2.compareTo(b.$2);
      });

    final net = <String, int>{};
    final seen = <String>[];
    final settled = <String>{};

    for (final (_, _, event) in events) {
      if (event is Expense) {
        net.update(event.payerId, (v) => v + event.amount, ifAbsent: () => event.amount);
        event.shares.forEach(
          (id, share) => net.update(id, (v) => v - share, ifAbsent: () => -share),
        );
        seen.add(event.id);
      } else if (event is Settlement) {
        net.update(event.fromId, (v) => v + event.amount, ifAbsent: () => event.amount);
        net.update(event.toId, (v) => v - event.amount, ifAbsent: () => -event.amount);
      }
      // Square, and something has happened since the last time it was square.
      if (seen.isNotEmpty && net.values.every((v) => v == 0)) {
        settled.addAll(seen);
        seen.clear();
      }
    }
    return settled;
  }

  /// Everything that happened in the group, newest first.
  List<Object> activity(Group group) =>
      [...group.expenses, ...group.settlements]..sort((a, b) {
        final da = a is Expense ? a.date : (a as Settlement).date;
        final db = b is Expense ? b.date : (b as Settlement).date;
        return db.compareTo(da);
      });

  /// Your position across everything at once — the number on the home screen.
  ///
  /// Negative means you owe. Pending claims deliberately do not move it: until
  /// the person owed says the money landed, it has not.
  int get netAcrossAll => groups.fold(0, (s, g) => s + g.yourBalance);

  /// Split out, because "₹3,850 all in" hides the fact that you are owed
  /// ₹12,000 by one person and owe ₹15,850 to another.
  ///
  /// Counted per person rather than per group, so the two halves agree with
  /// the names underneath them. Summing groups would report owing Ananya on
  /// the trip *and* being owed by her on the flat, when netted she is one
  /// number in one direction — and the person reading it cannot reconcile a
  /// total that counts somebody twice.
  int get totalYouOwe => standings.fold(0, (s, p) => s + (p.youOwe ? p.magnitude : 0));
  int get totalOwedToYou => standings.fold(0, (s, p) => s + (p.theyOweYou ? p.amount : 0));

  bool get isAllSquare => groups.every((g) => g.yourBalance == 0);

  String displayName(Member m) => m.isYou ? 'You' : m.name;

  String shortName(Member m) => m.isYou ? 'You' : m.name.split(' ').first;

  /// The group's state as a message you can paste into WhatsApp.
  ///
  /// Plain text on purpose: the people who need to read it may not have Mull,
  /// and an unreadable summary is the same as no summary.
  String groupSummary(Group group) {
    final lines = <String>['${group.title} · split on Mull', ''];
    final transfers = simplify(group.balances);
    if (transfers.isEmpty) {
      lines.add('All settled up.');
    } else {
      for (final t in transfers) {
        final from = group.memberById(t.from);
        final to = group.memberById(t.to);
        if (from == null || to == null) continue;
        lines.add('${shortName(from)} → ${shortName(to)}: ${inr(t.amount)}');
      }
      final upi = group.you?.upiId ?? profile.upiId;
      if (upi != null && transfers.any((t) => t.to == group.you?.id)) {
        lines
          ..add('')
          ..add('Pay me at $upi');
      }
    }
    lines
      ..add('')
      ..add('Total spent: ${inr(group.total)}');
    return lines.join('\n');
  }

  // ------------------------------------------------------------------ admin

  Future<void> resetAll() async {
    profile = Profile(theme: profile.theme);
    groups.clear();
    pendingGroupDeletes.clear();
    _commit();
    await flush();
  }

  /// Signing out. Everything that belonged to the account goes, including
  /// groups the server never saw and the profile — the next person to sign in
  /// on this phone would otherwise inherit your name, and your UPI ID would go
  /// out in *their* reminders. Only the theme is the phone's own.
  Future<void> forgetAccount() => resetAll();

  /// Mirrors the design mockups. Handy for demos, screenshots and the tour.
  ///
  /// Deliberately not three tidy groups of equal shape. Between them they
  /// cover every state a screen has to draw: a claim waiting on you, a
  /// schedule about to come round, a seat belonging to somebody who is not on
  /// Mull, expenses that a later settlement already cleared, and a ledger that
  /// is square and still worth keeping.
  void loadSample() {
    groups.clear();
    profile
      ..name = profile.name.isEmpty ? 'Bharat' : profile.name
      ..onboarded = true
      ..upiId ??= 'bharat@okhdfcbank';

    final today = dayOf(now());
    DateTime ago(int days) => today.subtract(Duration(days: days));

    // One account id per person, reused wherever they turn up.
    //
    // These used to be a fresh `newId()` in every group, which made the sample
    // three different Sahils as far as the app was concerned: he showed up
    // three times on the home screen, owing in one row and owed in another,
    // which is the exact thing person-level netting exists to stop. Demo data
    // that cannot exercise the feature is demo data that hides it.
    final accounts = <String, String>{};
    String account(String name) => accounts.putIfAbsent(name, newId);

    // ---- Goa trip: four people, one of them not on Mull, and a claim.
    //
    // The numbers are worked so the group lands exactly where the mockups put
    // it: you ₹2,400 up, Sahil owing ₹800 and Kabir ₹1,600, which is the two
    // payments the settle-up screen offers.
    final goa = Group(name: 'Goa trip', icon: 'beach');
    final you = Member(name: profile.name, isYou: true, upiId: profile.upiId, role: MemberRole.admin);
    final sahil = Member(name: 'Sahil Mehra', upiId: 'sahil@okaxis', userId: account('Sahil Mehra'));
    final ananya = Member(name: 'Ananya Rao', upiId: 'ananya@ybl', userId: account('Ananya Rao'));
    // No userId and no VPA: a placeholder seat, settled in person.
    final kabir = Member(name: 'Kabir');
    goa.members.addAll([you, sahil, ananya, kabir]);
    final goaIds = goa.members.map((m) => m.id).toList();

    // The villa deposit and the three payments that cleared it. Everything up
    // to here is history, and the ledger dims it.
    final deposit = Expense(
      description: 'Deposit for the villa',
      amount: 5300,
      payerId: you.id,
      shares: splitEqually(5300, goaIds),
      date: ago(50),
    );
    goa.expenses.add(deposit);
    for (final payer in [sahil, ananya, kabir]) {
      goa.settlements.add(
        Settlement(
          fromId: payer.id,
          toId: you.id,
          amount: deposit.shares[payer.id]!,
          status: SettlementStatus.confirmed,
          date: ago(48),
          confirmedAt: ago(48),
        ),
      );
    }

    goa.expenses.addAll([
      Expense(
        description: 'Flights',
        amount: 24000,
        payerId: ananya.id,
        shares: splitEqually(24000, goaIds),
        date: ago(7),
      ),
      Expense(
        description: 'Beach shack lunch',
        amount: 1800,
        payerId: sahil.id,
        // Kabir sat this one out, which is why the ledger says three ways.
        shares: splitEqually(1800, [you.id, sahil.id, ananya.id]),
        date: ago(7),
      ),
      Expense(
        description: 'Scooter rentals',
        amount: 4800,
        payerId: ananya.id,
        method: SplitMethod.exact,
        shares: {you.id: 1200, sahil.id: 1200, ananya.id: 1200, kabir.id: 1200},
        date: ago(5),
      ),
      Expense(
        description: 'Dinner at Gunpowder',
        amount: 3200,
        payerId: you.id,
        shares: splitEqually(3200, goaIds),
        date: ago(3),
      ),
    ]);

    // Ananya fronted the flights, so most of the trip has already been paid
    // back to her.
    for (final (payer, amount) in [(you, 7800), (sahil, 6000), (kabir, 6400)]) {
      goa.settlements.add(
        Settlement(
          fromId: payer.id,
          toId: ananya.id,
          amount: amount,
          status: SettlementStatus.confirmed,
          date: ago(4),
          confirmedAt: ago(4),
        ),
      );
    }

    // Sahil says he has sent what is left of his share. Nothing moves until
    // you say it landed.
    goa.settlements.add(
      Settlement(
        fromId: sahil.id,
        toId: you.id,
        amount: 800,
        utr: '429117338201',
        date: ago(1),
      ),
    );

    // ---- Flat: the standing costs, one of them nearly due.
    final flat = Group(name: 'Flat', icon: 'home');
    final youFlat = Member(name: profile.name, isYou: true, upiId: profile.upiId, role: MemberRole.admin);
    final bhavya = Member(name: 'Bhavya Nair', upiId: 'bhavya@okicici', userId: account('Bhavya Nair'));
    final sahilFlat = Member(name: 'Sahil Mehra', upiId: 'sahil@okaxis', userId: account('Sahil Mehra'));
    final dev = Member(name: 'Dev Rao', upiId: 'dev@ybl', userId: account('Dev Rao'));
    flat.members.addAll([youFlat, bhavya, sahilFlat, dev]);
    final flatIds = flat.members.map((m) => m.id).toList();

    final maintenance = Recurring(
      description: 'Flat maintenance',
      amount: 4200,
      payerId: bhavya.id,
      shares: splitEqually(4200, flatIds),
      frequency: Frequency.monthly,
      nextDue: today.add(const Duration(days: 6)),
      lastAddedOn: ago(24),
    );
    final houseHelp = Recurring(
      description: 'House help',
      amount: 3000,
      payerId: youFlat.id,
      shares: splitEqually(3000, flatIds),
      frequency: Frequency.monthly,
      // Due today, so the home screen has something to open.
      nextDue: today,
      lastAddedOn: ago(30),
    );
    flat.recurring.addAll([maintenance, houseHelp]);

    flat.expenses.addAll([
      Expense(
        description: 'Flat maintenance',
        amount: 4200,
        payerId: bhavya.id,
        shares: splitEqually(4200, flatIds),
        recurringId: maintenance.id,
        date: ago(24),
      ),
      Expense(
        description: 'House help',
        amount: 3000,
        payerId: youFlat.id,
        shares: splitEqually(3000, flatIds),
        recurringId: houseHelp.id,
        date: ago(30),
      ),
      Expense(
        description: 'Electricity',
        amount: 5800,
        payerId: dev.id,
        shares: splitEqually(5800, flatIds),
        date: ago(12),
      ),
      Expense(
        description: 'Rent',
        amount: 24000,
        payerId: sahilFlat.id,
        shares: splitEqually(24000, flatIds),
        date: ago(18),
      ),
    ]);

    // ---- Sunday football: square, and still worth keeping.
    final football = Group(name: 'Sunday football', icon: 'football');
    final youBall = Member(name: profile.name, isYou: true, upiId: profile.upiId, role: MemberRole.admin);
    final sahilBall = Member(name: 'Sahil Mehra', upiId: 'sahil@okaxis', userId: account('Sahil Mehra'));
    final devBall = Member(name: 'Dev Rao', upiId: 'dev@ybl', userId: account('Dev Rao'));
    football.members.addAll([youBall, sahilBall, devBall]);
    final ballIds = football.members.map((m) => m.id).toList();
    football.expenses.add(
      Expense(
        description: 'Turf',
        amount: 2400,
        payerId: youBall.id,
        shares: splitEqually(2400, ballIds),
        date: ago(6),
      ),
    );
    for (final payer in [sahilBall, devBall]) {
      football.settlements.add(
        Settlement(
          fromId: payer.id,
          toId: youBall.id,
          amount: 800,
          status: SettlementStatus.confirmed,
          date: ago(5),
          confirmedAt: ago(5),
        ),
      );
    }

    // ---- And one person, with no group around it.
    final ritu = directWith(name: 'Ritu Nair', userId: account('Ritu Nair'), upiId: 'ritu@okicici');
    final youRitu = ritu.you!;
    final herSeat = ritu.counterpart!;
    final cab = Expense(
      description: 'Cab to the airport',
      amount: 900,
      payerId: youRitu.id,
      shares: splitEqually(900, [youRitu.id, herSeat.id]),
      date: ago(11),
    );
    ritu.expenses.add(cab);
    ritu.settlements.add(
      Settlement(
        fromId: herSeat.id,
        toId: youRitu.id,
        amount: 450,
        status: SettlementStatus.confirmed,
        date: ago(10),
        confirmedAt: ago(10),
      ),
    );

    groups.insertAll(0, [football, goa, flat]);
    _commit();
  }
}

/// Something worth telling specific people about.
///
/// Composed here, where the context is — which group, who did it, what it was
/// for — rather than assembled from parts on the way in. The sentence travels
/// with the notice, so a phone running an older build can still show one about
/// a thing it has no template for.
enum NoticeKind {
  expenseAdded,
  expenseChanged,
  expenseRemoved,
  settlementClaimed,
  settlementConfirmed,
  settlementDisputed,
  settlementRemoved,
  nettedOff,
  reminder,
  addedToGroup,
}

extension NoticeKindWire on NoticeKind {
  /// The enum label Postgres uses. Snake case there, camel here.
  String get wire => switch (this) {
    NoticeKind.expenseAdded => 'expense_added',
    NoticeKind.expenseChanged => 'expense_changed',
    NoticeKind.expenseRemoved => 'expense_removed',
    NoticeKind.settlementClaimed => 'settlement_claimed',
    NoticeKind.settlementConfirmed => 'settlement_confirmed',
    NoticeKind.settlementDisputed => 'settlement_disputed',
    NoticeKind.settlementRemoved => 'settlement_removed',
    NoticeKind.nettedOff => 'netted_off',
    NoticeKind.reminder => 'reminder',
    NoticeKind.addedToGroup => 'added_to_group',
  };

  static NoticeKind read(String? value) => switch (value) {
    'expense_added' => NoticeKind.expenseAdded,
    'expense_changed' => NoticeKind.expenseChanged,
    'expense_removed' => NoticeKind.expenseRemoved,
    'settlement_claimed' => NoticeKind.settlementClaimed,
    'settlement_confirmed' => NoticeKind.settlementConfirmed,
    'settlement_disputed' => NoticeKind.settlementDisputed,
    'settlement_removed' => NoticeKind.settlementRemoved,
    'netted_off' => NoticeKind.nettedOff,
    'reminder' => NoticeKind.reminder,
    _ => NoticeKind.addedToGroup,
  };
}

class Notice {
  const Notice({
    required this.to,
    required this.kind,
    required this.title,
    this.body = '',
    this.groupId,
    this.amount,
  });

  /// Account ids, not member ids. A placeholder seat has nobody behind it and
  /// is simply not on this list.
  final List<String> to;

  final NoticeKind kind;
  final String title;
  final String body;
  final String? groupId;
  final int? amount;
}

/// One person and everything they owe you, netted across every ledger.
/// Where you stand with one person, across every ledger you share.
///
/// Signed, and that is the whole point. Mull used to have an `Owing`, which
/// could only ever describe money coming towards you — so the half of the app
/// that mattered when you were the one who owed simply had no object to be
/// built out of, and was never built.
class Standing {
  Standing({
    required this.member,
    required this.amount,
    required this.groups,
    required this.seats,
    List<DateTime>? nudges,
    this.byNameOnly = false,
  }) : nudges = nudges ?? [];

  /// Matched across ledgers by name alone — no account, no email. A guess,
  /// and fine for showing; see [MullStore.canSettleAcross] for what it is not
  /// fine for.
  final bool byNameOnly;

  /// One of their seats, for a name and a UPI ID. Which one is arbitrary —
  /// they are the same person, which is the premise of this class.
  final Member member;

  /// Positive means they owe you; negative means you owe them.
  final int amount;

  /// The ledgers that actually contribute something. A group you are square
  /// in is not part of the story.
  final List<Group> groups;

  /// Their member id in each group, so a nudge can stamp every seat without
  /// matching on a name that might have been changed.
  final Map<String, String> seats;

  /// Every time you have chased them, across all of those ledgers.
  final List<DateTime> nudges;

  bool get theyOweYou => amount > 0;
  bool get youOwe => amount < 0;
  bool get isSquare => amount == 0;

  /// The amount with no sign on it, for a screen that says the direction in
  /// words instead.
  int get magnitude => amount.abs();

  DateTime? get lastNudgedAt => nudges.isEmpty ? null : nudges.last;
}

/// Makes the store reachable from any widget and rebuilds dependents on change.
class StoreScope extends InheritedNotifier<MullStore> {
  const StoreScope({super.key, required MullStore store, required super.child}) : super(notifier: store);

  static MullStore of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<StoreScope>()!.notifier!;

  /// Access without subscribing to rebuilds (for callbacks).
  static MullStore read(BuildContext context) => context.getInheritedWidgetOfExactType<StoreScope>()!.notifier!;
}

extension StoreContext on BuildContext {
  MullStore get store => StoreScope.of(this);
  MullStore get readStore => StoreScope.read(this);
}
