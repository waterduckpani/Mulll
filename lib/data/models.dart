import 'dart:math';

import 'package:flutter/material.dart' show ThemeMode;

import '../core/dates.dart';

final _rng = Random();

/// A UUID v4.
///
/// Ids are generated on the phone, before anything has been near a server —
/// that is what lets a group be created offline and pushed later without
/// anything being renumbered. Postgres wants a real uuid, so the shape has to
/// be right from the start rather than translated at the boundary.
String newId() {
  final bytes = List<int>.generate(16, (_) => _rng.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40; // version 4
  bytes[8] = (bytes[8] & 0x3f) | 0x80; // variant 1
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}'
      '-${hex.substring(16, 20)}-${hex.substring(20)}';
}

DateTime? _date(Object? v) => v == null ? null : DateTime.parse(v as String);

/// How an expense was divided.
///
/// [equal] is the overwhelming default. The rest exist because real bills are
/// not even: one person had the dessert, two share a room, rent is by room size.
enum SplitMethod { equal, exact, shares, percent }

class Member {
  Member({
    String? id,
    required this.name,
    this.isYou = false,
    this.upiId,
    this.email,
    this.phone,
    this.userId,
    this.nudgedAt,
  }) : id = id ?? newId();

  final String id;
  String name;
  final bool isYou;

  /// How an unclaimed seat finds its owner. You add "Ritu" tonight; if she ever
  /// signs up on this address or number, the seat becomes hers and the history
  /// she was already part of comes with it. Either will do — login is by email
  /// today, but the match is kept open to both.
  String? email;

  /// E.164. Also what a nudge is sent to, so it is worth having even for
  /// someone who will never install Mull.
  String? phone;

  /// Null while the seat is still a placeholder — nobody has claimed it.
  String? userId;

  /// Whether there is a real person behind this seat who could answer.
  bool get isLinked => userId != null;

  /// Their UPI address, so settling up is one tap instead of a screenshot and
  /// a retyped amount.
  String? upiId;

  /// When you last chased them. Kept on this phone only: it exists to stop
  /// *you* nagging twice in an hour, not to tell them off.
  DateTime? nudgedAt;

  String get initials {
    final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) {
      final p = parts.first;
      return (p.length >= 2 ? p.substring(0, 2) : p).toUpperCase();
    }
    return (parts.first[0] + parts.last[0]).toUpperCase();
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'isYou': isYou,
    'upiId': upiId,
    'email': email,
    'phone': phone,
    'userId': userId,
    'nudgedAt': nudgedAt?.toIso8601String(),
  };

  factory Member.fromJson(Map<String, dynamic> j) => Member(
    id: j['id'] as String,
    name: j['name'] as String,
    isYou: j['isYou'] as bool? ?? false,
    upiId: j['upiId'] as String?,
    email: j['email'] as String?,
    phone: j['phone'] as String?,
    userId: j['userId'] as String?,
    nudgedAt: _date(j['nudgedAt']),
  );
}

/// Something one person paid for on behalf of some of the group.
class Expense {
  Expense({
    String? id,
    required this.description,
    required this.amount,
    required this.payerId,
    required this.shares,
    this.method = SplitMethod.equal,
    this.recurringId,
    this.note,
    DateTime? date,
  }) : id = id ?? newId(),
       date = date ?? DateTime.now();

  final String id;
  String description;
  int amount;

  /// Who actually put the money down.
  String payerId;

  /// The resolved rupee share per member id. Always adds back up to [amount] —
  /// the split maths happens once, when the expense is saved, so nothing has to
  /// be re-derived (or re-rounded) every time a balance is read.
  Map<String, int> shares;

  /// Kept for editing: the resolved shares alone cannot say how they were made.
  SplitMethod method;

  /// The schedule this came off, if it came off one.
  ///
  /// An id rather than a flag, because "has this period already been added?"
  /// has to be answerable exactly. The old version matched on the description,
  /// which said yes to any expense someone happened to name "Rent".
  String? recurringId;

  /// Whatever needed saying — "includes Dev's half of the deposit".
  String? note;

  DateTime date;

  bool get isRecurring => recurringId != null;

  Map<String, dynamic> toJson() => {
    'id': id,
    'description': description,
    'amount': amount,
    'payerId': payerId,
    'shares': shares,
    'method': method.name,
    'recurringId': recurringId,
    'note': note,
    'date': date.toIso8601String(),
  };

  factory Expense.fromJson(Map<String, dynamic> j) => Expense(
    id: j['id'] as String,
    description: j['description'] as String,
    amount: j['amount'] as int,
    payerId: j['payerId'] as String,
    shares: (j['shares'] as Map).map((k, v) => MapEntry(k as String, (v as num).toInt())),
    method: SplitMethod.values.byName(j['method'] as String? ?? 'equal'),
    recurringId: j['recurringId'] as String?,
    note: j['note'] as String?,
    date: _date(j['date']),
  );
}

/// How often a standing expense comes round.
enum Frequency { weekly, fortnightly, monthly, quarterly, yearly }

extension FrequencyLabel on Frequency {
  String get label => switch (this) {
    Frequency.weekly => 'Every week',
    Frequency.fortnightly => 'Every 2 weeks',
    Frequency.monthly => 'Every month',
    Frequency.quarterly => 'Every 3 months',
    Frequency.yearly => 'Every year',
  };

  String get shortLabel => switch (this) {
    Frequency.weekly => 'weekly',
    Frequency.fortnightly => 'fortnightly',
    Frequency.monthly => 'monthly',
    Frequency.quarterly => 'quarterly',
    Frequency.yearly => 'yearly',
  };

  /// The next occurrence after [from].
  DateTime next(DateTime from) => switch (this) {
    Frequency.weekly => from.add(const Duration(days: 7)),
    Frequency.fortnightly => from.add(const Duration(days: 14)),
    Frequency.monthly => addMonths(from, 1),
    Frequency.quarterly => addMonths(from, 3),
    Frequency.yearly => addMonths(from, 12),
  };
}

/// A standing expense: rent, wifi, the maid, the Netflix everyone chips in for.
///
/// The schedule is a separate thing from the expenses it produces, and that
/// separation is the whole design. Rent changes, people move out, and the month
/// somebody was away is a month the split was different — so each occurrence is
/// a real expense that can be edited or deleted on its own, and the schedule
/// only ever says "this is due again".
///
/// Nothing is created behind anyone's back unless [autoAdd] is switched on, and
/// even then Mull says so afterwards rather than silently.
class Recurring {
  Recurring({
    String? id,
    required this.description,
    required this.amount,
    required this.payerId,
    required this.shares,
    this.method = SplitMethod.equal,
    this.frequency = Frequency.monthly,
    required this.nextDue,
    this.endsOn,
    this.paused = false,
    this.autoAdd = false,
    this.lastAddedOn,
    DateTime? createdAt,
  }) : id = id ?? newId(),
       createdAt = createdAt ?? DateTime.now();

  final String id;
  String description;
  int amount;
  String payerId;
  Map<String, int> shares;
  SplitMethod method;
  Frequency frequency;

  /// Local midnight of the day the next occurrence is owed.
  DateTime nextDue;

  /// The lease ends in June. Null means it runs until someone stops it.
  DateTime? endsOn;

  /// "We're between flatmates" — keeps the schedule without it piling up.
  bool paused;

  /// Add the occurrence without asking. Off by default: an expense that appears
  /// on its own is one nobody checked.
  bool autoAdd;

  DateTime? lastAddedOn;
  final DateTime createdAt;

  bool get hasEnded => endsOn != null && nextDue.isAfter(endsOn!);

  bool get isActive => !paused && !hasEnded;

  /// Whether this period is owed as of [now].
  bool isDue(DateTime now) => isActive && !nextDue.isAfter(dayOf(now));

  /// Moves the schedule on one period, skipping any it has fallen behind by.
  ///
  /// A phone that was off for three months should not produce three months of
  /// back-rent the moment it wakes up — it should be due once, now. Catching up
  /// silently is how a scheduler turns a holiday into a ₹90,000 surprise.
  void advance(DateTime now) {
    final today = dayOf(now);
    var next = frequency.next(nextDue);
    var guard = 0;
    while (next.isBefore(today) && guard++ < 600) {
      next = frequency.next(next);
    }
    nextDue = next;
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'description': description,
    'amount': amount,
    'payerId': payerId,
    'shares': shares,
    'method': method.name,
    'frequency': frequency.name,
    'nextDue': nextDue.toIso8601String(),
    'endsOn': endsOn?.toIso8601String(),
    'paused': paused,
    'autoAdd': autoAdd,
    'lastAddedOn': lastAddedOn?.toIso8601String(),
    'createdAt': createdAt.toIso8601String(),
  };

  factory Recurring.fromJson(Map<String, dynamic> j) => Recurring(
    id: j['id'] as String,
    description: j['description'] as String,
    amount: j['amount'] as int,
    payerId: j['payerId'] as String,
    shares: (j['shares'] as Map).map((k, v) => MapEntry(k as String, (v as num).toInt())),
    method: SplitMethod.values.byName(j['method'] as String? ?? 'equal'),
    frequency: Frequency.values.byName(j['frequency'] as String? ?? 'monthly'),
    nextDue: _date(j['nextDue'])!,
    endsOn: _date(j['endsOn']),
    paused: j['paused'] as bool? ?? false,
    autoAdd: j['autoAdd'] as bool? ?? false,
    lastAddedOn: _date(j['lastAddedOn']),
    createdAt: _date(j['createdAt']),
  );
}

/// Where a claimed payment has got to.
///
/// [pending] is a claim, not a fact — the payer says they sent it and the
/// person owed has not said it landed. A single unverified tap is what makes
/// other split apps rot: one side marks it settled, the other never sees the
/// money, and the balance is quietly wrong forever.
enum SettlementStatus { pending, confirmed, disputed }

/// Money one person says they sent another.
class Settlement {
  Settlement({
    String? id,
    required this.fromId,
    required this.toId,
    required this.amount,
    this.status = SettlementStatus.pending,
    this.utr,
    DateTime? date,
    this.confirmedAt,
  }) : id = id ?? newId(),
       date = date ?? DateTime.now();

  final String id;
  final String fromId;
  final String toId;
  final int amount;
  SettlementStatus status;

  /// The UPI reference off the payer's receipt, so "I already sent it" has
  /// something behind it.
  String? utr;

  /// When it was claimed.
  final DateTime date;
  DateTime? confirmedAt;

  /// Only a confirmed payment moves a balance.
  bool get clearsDebt => status == SettlementStatus.confirmed;

  Map<String, dynamic> toJson() => {
    'id': id,
    'fromId': fromId,
    'toId': toId,
    'amount': amount,
    'status': status.name,
    'utr': utr,
    'date': date.toIso8601String(),
    'confirmedAt': confirmedAt?.toIso8601String(),
  };

  factory Settlement.fromJson(Map<String, dynamic> j) => Settlement(
    id: j['id'] as String,
    fromId: j['fromId'] as String,
    toId: j['toId'] as String,
    amount: j['amount'] as int,
    // Settlements written before confirmation existed were facts, not claims.
    status: SettlementStatus.values.byName(j['status'] as String? ?? 'confirmed'),
    utr: j['utr'] as String?,
    date: _date(j['date']),
    confirmedAt: _date(j['confirmedAt']),
  );
}

/// A shared ledger, and how it is presented.
///
/// [direct] is the same machinery with two seats and no name of its own — what
/// you owe one person, outside any trip or flat. It is a group underneath
/// because a two-person ledger and a ten-person ledger are the same arithmetic,
/// the same settlement loop and the same rows on the server; making it a
/// separate concept would mean writing all of that twice and syncing it twice.
enum GroupKind { group, direct }

class Group {
  Group({
    String? id,
    required this.name,
    this.kind = GroupKind.group,
    List<Member>? members,
    List<Expense>? expenses,
    List<Settlement>? settlements,
    List<Recurring>? recurring,
    DateTime? createdAt,
    this.syncedAt,
  }) : id = id ?? newId(),
       members = members ?? [],
       expenses = expenses ?? [],
       settlements = settlements ?? [],
       recurring = recurring ?? [],
       createdAt = createdAt ?? DateTime.now();

  final String id;
  String name;
  final GroupKind kind;
  final List<Member> members;
  final List<Expense> expenses;
  final List<Settlement> settlements;
  final List<Recurring> recurring;
  final DateTime createdAt;

  /// When the server last accepted this group. Null means it has never been
  /// acknowledged — either the app is signed out, or a push failed.
  ///
  /// This exists so a pull can tell "the server deleted this" apart from "the
  /// server has never heard of this". Without the distinction a single failed
  /// push means the next pull quietly deletes work the person can see on their
  /// screen, which is how a small server-side bug turns into lost data.
  DateTime? syncedAt;

  bool get hasReachedServer => syncedAt != null;

  bool get isDirect => kind == GroupKind.direct;

  int get total => expenses.fold(0, (s, e) => s + e.amount);

  Member? memberById(String id) => members.where((m) => m.id == id).firstOrNull;
  Member? get you => members.where((m) => m.isYou).firstOrNull;

  /// The other seat in a direct ledger. Null in a real group.
  Member? get counterpart =>
      isDirect ? members.where((m) => !m.isYou).firstOrNull : null;

  /// What this ledger is called on screen. A direct ledger is a person.
  String get title => isDirect ? (counterpart?.name ?? name) : name;

  /// What each person is up or down by, netted across every expense and
  /// settlement. Positive means the group owes them; negative means they owe it.
  ///
  /// Paying puts you in credit, your share of a bill puts you in debt, and
  /// settling up moves the two back towards each other. The values always sum
  /// to zero — if they ever do not, the ledger has lost money somewhere.
  Map<String, int> get balances {
    final net = {for (final m in members) m.id: 0};
    for (final e in expenses) {
      net.update(e.payerId, (v) => v + e.amount, ifAbsent: () => e.amount);
      e.shares.forEach((id, share) => net.update(id, (v) => v - share, ifAbsent: () => -share));
    }
    for (final s in settlements) {
      // A claim is not a payment. Until the person owed says it landed, the
      // debt stands — otherwise one tap could clear a balance nobody honoured.
      if (!s.clearsDebt) continue;
      net.update(s.fromId, (v) => v + s.amount, ifAbsent: () => s.amount);
      net.update(s.toId, (v) => v - s.amount, ifAbsent: () => -s.amount);
    }
    // Someone removed from the group can still appear in old expenses; their
    // balance is real history, but it is not a row anyone can act on.
    net.removeWhere((id, value) => memberById(id) == null && value == 0);
    return net;
  }

  /// Your own position, or 0 in a group you are somehow not part of.
  int get yourBalance => balances[you?.id] ?? 0;

  bool get isSettled => balances.values.every((v) => v == 0);

  /// Claims waiting on someone to say the money arrived.
  List<Settlement> get pendingSettlements =>
      settlements.where((s) => s.status == SettlementStatus.pending).toList();

  /// Claims waiting specifically on *you* — the only ones you can act on.
  List<Settlement> get awaitingYourConfirmation {
    final me = you?.id;
    return me == null ? const [] : pendingSettlements.where((s) => s.toId == me).toList();
  }

  Recurring? recurringById(String id) => recurring.where((r) => r.id == id).firstOrNull;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'kind': kind.name,
    'members': members.map((m) => m.toJson()).toList(),
    'expenses': expenses.map((e) => e.toJson()).toList(),
    'settlements': settlements.map((s) => s.toJson()).toList(),
    'recurring': recurring.map((r) => r.toJson()).toList(),
    'createdAt': createdAt.toIso8601String(),
    'syncedAt': syncedAt?.toIso8601String(),
  };

  factory Group.fromJson(Map<String, dynamic> j) => Group(
    id: j['id'] as String,
    name: j['name'] as String,
    kind: GroupKind.values.byName(j['kind'] as String? ?? 'group'),
    members: (j['members'] as List).map((m) => Member.fromJson((m as Map).cast())).toList(),
    expenses: (j['expenses'] as List? ?? []).map((e) => Expense.fromJson((e as Map).cast())).toList(),
    settlements: (j['settlements'] as List? ?? []).map((s) => Settlement.fromJson((s as Map).cast())).toList(),
    recurring: (j['recurring'] as List? ?? []).map((r) => Recurring.fromJson((r as Map).cast())).toList(),
    createdAt: _date(j['createdAt']),
    syncedAt: _date(j['syncedAt']),
  );
}

class Profile {
  Profile({
    this.name = '',
    // Dark is the primary theme: every screen in the design is dark, and the
    // paper theme is an option rather than half of a pair.
    this.theme = ThemeMode.dark,
    this.onboarded = false,
    this.upiId,
    this.phone,
  });

  String name;
  ThemeMode theme;
  bool onboarded;

  /// Your own UPI address — goes into the summaries you send people so they can
  /// pay you back without asking for it every time.
  String? upiId;

  /// E.164, optional. Only used so someone can find you by number.
  String? phone;

  String get initial => name.trim().isEmpty ? '·' : name.trim()[0].toUpperCase();

  Map<String, dynamic> toJson() => {
    'name': name,
    'theme': theme.name,
    'onboarded': onboarded,
    'upiId': upiId,
    'phone': phone,
  };

  factory Profile.fromJson(Map<String, dynamic> j) => Profile(
    name: j['name'] as String? ?? '',
    theme: ThemeMode.values.byName(j['theme'] as String? ?? 'dark'),
    onboarded: j['onboarded'] as bool? ?? false,
    upiId: j['upiId'] as String?,
    phone: j['phone'] as String?,
  );
}
