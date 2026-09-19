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

/// How long to leave between nudges to the same person.
///
/// A reminder is a favour to both sides right up until it is the second one
/// today, at which point it is nagging and gets read as rude. Mull will not
/// send one for you inside this window.
const kNudgeCooldown = Duration(hours: 20);

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

  /// Local edit first, network afterwards — the UI should never wait on a
  /// round trip to feel like it worked.
  void _commitGroup(Group group) {
    _commit();
    onGroupChanged?.call(group);
  }

  /// Replaces the shared ledger with what the server sent.
  ///
  /// [keepLocalSchedules] is for a project that has not had the recurring
  /// migration applied: the server cannot carry schedules, so an answer with
  /// none means "this server does not do schedules", not "they were deleted".
  /// Once the tables are there the server is the authority and this is false,
  /// or deleting a schedule on one phone would have it resurrected by the next
  /// pull on another.
  void replaceGroups(List<Group> incoming, {bool keepLocalSchedules = false}) {
    // Anything the server has never acknowledged survives a pull.
    //
    // The server is the authority on groups it knows about, so a group missing
    // from its answer has genuinely been deleted and should go. But a group it
    // has never seen is a different thing entirely: the push has not landed
    // yet, or failed. Treating those two cases the same means one failed push
    // silently deletes work that is on screen in front of someone — which is
    // exactly what a bad trigger did here once already.
    final unsynced = [
      for (final g in groups)
        if (!g.hasReachedServer && !incoming.any((i) => i.id == g.id)) g,
    ];

    // When you last chased someone is this phone's business and has no column
    // anywhere, so it has to survive a pull or every refresh re-arms the nudge.
    final held = {for (final g in groups) g.id: g};
    for (final group in incoming) {
      final previous = held[group.id];
      if (previous == null) continue;
      if (keepLocalSchedules && group.recurring.isEmpty) {
        group.recurring.addAll(previous.recurring);
      }
      for (final member in group.members) {
        member.nudgedAt ??= previous.memberById(member.id)?.nudgedAt;
      }
    }

    groups
      ..clear()
      ..addAll(incoming)
      ..addAll(unsynced);
    _commit();
  }

  /// Notes that the server has taken a copy. Local-only: re-pushing here would
  /// loop, since a push is what got us here.
  void markGroupSynced(Group group) {
    group.syncedAt = now();
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
  }) {
    final group = Group(
      name: name.trim(),
      kind: kind,
      members: [
        Member(name: profile.name.isEmpty ? 'You' : profile.name, isYou: true, upiId: profile.upiId),
        ...friends,
        for (final n in others)
          if (n.trim().isNotEmpty) Member(name: n.trim()),
      ],
    );
    groups.add(group);
    _commitGroup(group);
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
        Member(name: profile.name.isEmpty ? 'You' : profile.name, isYou: true, upiId: profile.upiId),
        Member(name: name.trim(), userId: userId, email: email, phone: phone, upiId: upiId),
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

  /// Biggest open amount first; anything settled sinks to the bottom.
  ///
  /// Not newest-first, and not by last activity. The home screen is a list of
  /// things to deal with, and the ₹6,250 you owe on the flat is more of a thing
  /// to deal with than the trip that ended square — even if somebody confirmed
  /// a payment on the trip an hour ago. Settled ledgers stay visible, because
  /// they are still who you split with, but they stop competing for the top.
  List<Group> _ordered(Iterable<Group> of) => [...of]..sort((a, b) {
    final byAmount = b.yourBalance.abs().compareTo(a.yourBalance.abs());
    if (byAmount != 0) return byAmount;
    return b.createdAt.compareTo(a.createdAt);
  });

  void updateGroup(Group group) => _commitGroup(group);

  void deleteGroup(Group group) {
    groups.removeWhere((g) => g.id == group.id);
    _commit();
    onGroupDeleted?.call(group.id);
  }

  void restoreGroup(Group group) {
    if (groups.any((g) => g.id == group.id)) return;
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
    return member;
  }

  /// Refuses to remove anyone the ledger still depends on — deleting a person
  /// who paid for dinner would silently rewrite what everyone else owes.
  bool canRemoveMember(Group group, Member member) {
    if (member.isYou || group.isDirect) return false;
    final involved = group.expenses.any((e) => e.payerId == member.id || e.shares.containsKey(member.id));
    final settled = group.settlements.any((s) => s.fromId == member.id || s.toId == member.id);
    final scheduled = group.recurring.any((r) => r.payerId == member.id || r.shares.containsKey(member.id));
    return !involved && !settled && !scheduled;
  }

  bool removeMember(Group group, Member member) {
    if (!canRemoveMember(group, member)) return false;
    group.members.removeWhere((m) => m.id == member.id);
    _commitGroup(group);
    return true;
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
    return expense;
  }

  void updateExpense(Group group, Expense expense) => _commitGroup(group);

  void removeExpense(Group group, Expense expense) {
    group.expenses.removeWhere((e) => e.id == expense.id);
    _commitGroup(group);
  }

  void restoreExpense(Group group, Expense expense) {
    if (group.expenses.any((e) => e.id == expense.id)) return;
    group.expenses.add(expense);
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
    final expense = addExpense(
      group,
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
    return settlement;
  }

  void confirmSettlement(Group group, Settlement settlement) {
    settlement
      ..status = SettlementStatus.confirmed
      ..confirmedAt = now();
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
  }

  void removeSettlement(Group group, Settlement settlement) {
    group.settlements.removeWhere((s) => s.id == settlement.id);
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

    (Group, Transfer)? byAmountOnly;
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
        if (amountMatches) byAmountOnly ??= (group, transfer);
      }
    }
    return byAmountOnly;
  }

  /// Every claim across every group that is waiting on you.
  List<(Group, Settlement)> get confirmationsForYou => [
    for (final g in groups)
      for (final s in g.awaitingYourConfirmation) (g, s),
  ];

  // --------------------------------------------------------------- reminders

  /// Everyone who owes you, across everything, biggest first.
  ///
  /// Netted per person rather than per group: chasing the same friend three
  /// times because you went to three dinners together is how a reminder
  /// feature makes people close the app.
  List<Owing> get owedToYou {
    final byPerson = <String, Owing>{};
    for (final group in groups) {
      final me = group.you?.id;
      if (me == null) continue;
      for (final t in simplify(group.balances)) {
        if (t.to != me) continue;
        final debtor = group.memberById(t.from);
        if (debtor == null) continue;
        final key = debtor.userId ?? debtor.email ?? debtor.name.trim().toLowerCase();
        final held = byPerson[key];
        byPerson[key] = Owing(
          member: debtor,
          amount: (held?.amount ?? 0) + t.amount,
          groups: [...?held?.groups, group],
          lastNudgedAt: held?.lastNudgedAt ?? debtor.nudgedAt,
        );
      }
    }
    return byPerson.values.toList()..sort((a, b) => b.amount.compareTo(a.amount));
  }

  bool canNudge(Owing owing) {
    final last = owing.lastNudgedAt;
    return last == null || now().difference(last) > kNudgeCooldown;
  }

  /// The message a nudge sends. Short, and it ends with the way to pay.
  ///
  /// Written to be forwarded and read by someone who may not have Mull, which
  /// is why it names the amount and the reason in plain words rather than
  /// linking to a screen only you can see.
  String nudgeMessage(Owing owing) {
    final where = owing.groups.length == 1
        ? ' for ${owing.groups.first.title}'
        : ' across ${owing.groups.length} groups';
    final upi = profile.upiId;
    return [
      'Hey ${shortName(owing.member)}, ${inr(owing.amount)}$where when you get a chance.',
      if (upi != null) 'My UPI is $upi.',
      'No rush.',
    ].join(' ');
  }

  void markNudged(Owing owing) {
    final at = now();
    for (final group in owing.groups) {
      final seat = group.memberById(owing.member.id) ??
          group.members.where((m) => !m.isYou && m.name == owing.member.name).firstOrNull;
      seat?.nudgedAt = at;
    }
    owing.member.nudgedAt = at;
    _commit();
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
    final events = <(DateTime, Object)>[
      for (final e in group.expenses) (e.date, e),
      for (final s in group.settlements)
        if (s.clearsDebt) (s.date, s),
    ]..sort((a, b) => a.$1.compareTo(b.$1));

    final net = <String, int>{};
    final seen = <String>[];
    final settled = <String>{};

    for (final (_, event) in events) {
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
  int get totalYouOwe => groups.fold(0, (s, g) => s + (g.yourBalance < 0 ? -g.yourBalance : 0));
  int get totalOwedToYou => groups.fold(0, (s, g) => s + (g.yourBalance > 0 ? g.yourBalance : 0));

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
    profile = Profile();
    groups.clear();
    _commit();
    await flush();
  }

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

    // ---- Goa trip: four people, one of them not on Mull, and a claim.
    //
    // The numbers are worked so the group lands exactly where the mockups put
    // it: you ₹2,400 up, Sahil owing ₹800 and Kabir ₹1,600, which is the two
    // payments the settle-up screen offers.
    final goa = Group(name: 'Goa trip');
    final you = Member(name: profile.name, isYou: true, upiId: profile.upiId);
    final sahil = Member(name: 'Sahil Mehra', upiId: 'sahil@okaxis', userId: newId());
    final ananya = Member(name: 'Ananya Rao', upiId: 'ananya@ybl', userId: newId());
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
    final flat = Group(name: 'Flat');
    final youFlat = Member(name: profile.name, isYou: true, upiId: profile.upiId);
    final bhavya = Member(name: 'Bhavya Nair', upiId: 'bhavya@okicici', userId: newId());
    final sahilFlat = Member(name: 'Sahil Mehra', upiId: 'sahil@okaxis', userId: newId());
    final dev = Member(name: 'Dev Rao', upiId: 'dev@ybl', userId: newId());
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
    final football = Group(name: 'Sunday football');
    final youBall = Member(name: profile.name, isYou: true, upiId: profile.upiId);
    final sahilBall = Member(name: 'Sahil Mehra', upiId: 'sahil@okaxis', userId: newId());
    final devBall = Member(name: 'Dev Rao', upiId: 'dev@ybl', userId: newId());
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
    final ritu = directWith(name: 'Ritu Nair', userId: newId(), upiId: 'ritu@okicici');
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

/// One person and everything they owe you, netted across every ledger.
class Owing {
  const Owing({
    required this.member,
    required this.amount,
    required this.groups,
    this.lastNudgedAt,
  });

  final Member member;
  final int amount;
  final List<Group> groups;
  final DateTime? lastNudgedAt;
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
