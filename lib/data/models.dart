import 'dart:math';

import 'package:flutter/material.dart' show ThemeMode;

import '../core/dates.dart';
import '../core/split.dart';

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

/// The same uuid for the same [seed], on every phone.
///
/// For rows that more than one phone can decide to create at once. A schedule
/// coming due is the case that matters: every flatmate's phone sees rent fall
/// due on the 1st, and with random ids each one posted its own copy and the
/// rent was charged twice. Derived from the schedule and the day instead, the
/// copies are one row as far as Postgres is concerned and the second upsert
/// simply lands on the first.
///
/// Four 32-bit FNV-1a passes with different offsets make the 128 bits —
/// 32-bit so the arithmetic never leaves a Dart int's positive range. Not
/// cryptographic and it does not need to be: the seeds are ids this app
/// generated, and a collision needs two of them to hash alike.
String stableId(String seed) {
  String fnv(int basis) {
    var h = basis;
    for (final unit in seed.codeUnits) {
      h = ((h ^ unit) * 0x01000193) & 0xFFFFFFFF;
    }
    return h.toRadixString(16).padLeft(8, '0');
  }

  final hex = [0x811c9dc5, 0x050c5d1f, 0x6c62272e, 0x2d358dcc].map(fnv).join().split('');
  hex[12] = '5'; // version 5, "name-based"
  hex[16] = '89ab'[int.parse(hex[16], radix: 16) & 3]; // variant 1
  final h = hex.join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}'
      '-${h.substring(16, 20)}-${h.substring(20)}';
}

DateTime? _date(Object? v) => v == null ? null : DateTime.parse(v as String);

String _day(DateTime? d) => d == null
    ? ''
    : '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-'
          '${d.day.toString().padLeft(2, '0')}';

/// Map entries in a fixed order, so two equal maps print the same.
List<List<Object>> _sorted(Map<String, int> m) =>
    [for (final k in m.keys.toList()..sort()) [k, m[k]!]];

/// How an expense was divided.
///
/// [equal] is the overwhelming default. The rest exist because real bills are
/// not even: one person had the dessert, two share a room, rent is by room size.
enum SplitMethod { equal, exact, shares, percent }

/// What a seat is allowed to decide.
///
/// Two, on purpose. A permissions matrix is the wrong amount of app for four
/// flatmates; what a group actually needs is a name against the decisions —
/// who renamed it, who removed Kabir — and a short answer to "may I do this".
/// Everything about the *ledger* — adding an expense, settling up, confirming
/// a payment — is open to everyone, because that is what being in a group is.
enum MemberRole { admin, member }

class Member {
  Member({
    String? id,
    required this.name,
    this.isYou = false,
    this.upiId,
    this.email,
    this.phone,
    this.userId,
    this.role = MemberRole.member,
    List<DateTime>? nudges,
  }) : id = id ?? newId(),
       nudges = nudges ?? [];

  final String id;
  String name;
  final bool isYou;

  MemberRole role;

  bool get isAdmin => role == MemberRole.admin;

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

  /// When you have chased them, most recent last.
  ///
  /// A list rather than a single date because the allowance is two a day, not
  /// one — and the count is what decides whether the button is live. This copy
  /// is only so the button can say so *before* it is pressed; the limit that
  /// actually holds is counted on the server, where reinstalling the app does
  /// not reset it.
  final List<DateTime> nudges;

  DateTime? get nudgedAt => nudges.isEmpty ? null : nudges.last;

  /// How many of the last day's nudges were yours.
  int nudgesSince(DateTime cutoff) => nudges.where((n) => n.isAfter(cutoff)).length;

  String get initials {
    final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) {
      final p = parts.first;
      return (p.length >= 2 ? p.substring(0, 2) : p).toUpperCase();
    }
    return (parts.first[0] + parts.last[0]).toUpperCase();
  }

  /// See [Group.acked]. A linked seat's VPA is the account's, never the
  /// seat's, so it is not part of what this phone could have changed.
  String get syncPrint => [
    name, email, phone, userId, isLinked ? null : upiId, role.name,
  ].toString();

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'isYou': isYou,
    'upiId': upiId,
    'email': email,
    'phone': phone,
    'userId': userId,
    'role': role.name,
    'nudges': nudges.map((n) => n.toIso8601String()).toList(),
  };

  factory Member.fromJson(Map<String, dynamic> j) => Member(
    id: j['id'] as String,
    name: j['name'] as String,
    isYou: j['isYou'] as bool? ?? false,
    upiId: j['upiId'] as String?,
    email: j['email'] as String?,
    phone: j['phone'] as String?,
    userId: j['userId'] as String?,
    role: MemberRole.values.byName(j['role'] as String? ?? 'member'),
    // A file written before the allowance became two a day has one date under
    // the old name. It still counts, so it is read as a list of one rather
    // than thrown away — otherwise updating the app hands everyone a fresh
    // set of reminders to send.
    nudges: [
      for (final n in (j['nudges'] as List? ?? const [])) DateTime.parse(n as String),
      if (j['nudgedAt'] != null) _date(j['nudgedAt'])!,
    ],
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
    DateTime? createdAt,
  }) : id = id ?? newId(),
       date = date ?? DateTime.now(),
       createdAt = createdAt ?? date ?? DateTime.now();

  final String id;
  String description;
  int amount;

  /// When it was written down, as opposed to [date], the day it happened.
  ///
  /// The server keeps [date] as a day with no time in it, so after a pull an
  /// expense added at 3pm and a payment made at 10am the same morning could
  /// not be told apart by date — and the replay that decides which expenses a
  /// payment already cleared put the expense first. This breaks the tie.
  final DateTime createdAt;

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
    'createdAt': createdAt.toIso8601String(),
  };

  /// What the server holds for this row, in a form two copies can be compared
  /// by. Only fields that sync; see [Group.acked].
  String get syncPrint => [
    description, amount, payerId, _sorted(shares), method.name, recurringId, note, _day(date),
  ].toString();

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
    createdAt: _date(j['createdAt']),
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

  /// See [Group.acked].
  String get syncPrint => [
    description, amount, payerId, _sorted(shares), method.name, frequency.name,
    _day(nextDue), _day(endsOn), paused, autoAdd, _day(lastAddedOn),
  ].toString();

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
    this.offset = false,
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

  /// No money moved: this cancels an equal debt pointing the other way in
  /// another ledger.
  ///
  /// Worth its own flag rather than looking like an ordinary payment. Owing
  /// Ananya 2,000 on the trip while she owes you 3,000 on the flat is settled
  /// by writing 2,000 into both ledgers, and a row saying "You paid Ananya
  /// 2,000" when nothing left your account is the kind of entry that makes
  /// somebody stop trusting the whole ledger.
  final bool offset;

  /// When it was claimed.
  final DateTime date;
  DateTime? confirmedAt;

  /// Only a confirmed payment moves a balance.
  bool get clearsDebt => status == SettlementStatus.confirmed;

  /// See [Group.acked]. The claim time never changes after insert, so only
  /// what can: the status, and what the claimer may still correct.
  String get syncPrint => [
    fromId, toId, amount, status.name, utr, offset, confirmedAt != null,
  ].toString();

  Map<String, dynamic> toJson() => {
    'id': id,
    'fromId': fromId,
    'toId': toId,
    'amount': amount,
    'status': status.name,
    'utr': utr,
    'offset': offset,
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
    offset: j['offset'] as bool? ?? false,
    date: _date(j['date']),
    confirmedAt: _date(j['confirmedAt']),
  );
}

/// A row this phone has deleted that the server may not know about yet.
///
/// Mull pushes a whole group at a time and the push is an upsert, which can
/// only ever say "this row exists". Deleting locally and saying nothing meant
/// the row survived on the server and came back on the next pull — an expense
/// reappearing days later, with everyone's balance silently moving with it.
///
/// A tombstone is the other half of that sentence. It is kept in the file, so
/// a delete made on a plane still reaches the server when the signal comes
/// back, and it is dropped once the server has acted on it.
enum TombstoneKind { expense, settlement, recurring, member }

class Tombstone {
  const Tombstone({required this.id, required this.kind});

  final String id;
  final TombstoneKind kind;

  Map<String, dynamic> toJson() => {'id': id, 'kind': kind.name};

  factory Tombstone.fromJson(Map<String, dynamic> j) => Tombstone(
    id: j['id'] as String,
    kind: TombstoneKind.values.byName(j['kind'] as String),
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
    this.icon,
    List<Member>? members,
    List<Expense>? expenses,
    List<Settlement>? settlements,
    List<Recurring>? recurring,
    List<Tombstone>? tombstones,
    Map<String, String>? acked,
    DateTime? createdAt,
    this.syncedAt,
  }) : id = id ?? newId(),
       members = members ?? [],
       expenses = expenses ?? [],
       settlements = settlements ?? [],
       recurring = recurring ?? [],
       tombstones = tombstones ?? [],
       acked = acked ?? {},
       createdAt = createdAt ?? DateTime.now();

  final String id;
  String name;
  final GroupKind kind;

  /// A key into the app's own icon set — 'plane', 'home', 'cutlery'.
  ///
  /// Not an image and not an emoji. An image means a storage bucket, an upload
  /// and a cache; an emoji renders differently on every OS and puts colour into
  /// a design that has none anywhere else. A key draws the same stroke icon on
  /// every phone, in the ink colour the rest of the screen is using.
  String? icon;

  final List<Member> members;
  final List<Expense> expenses;
  final List<Settlement> settlements;
  final List<Recurring> recurring;

  /// Deletions this phone has made that the server may not have been told
  /// about. Emptied by the sync once it has passed them on.
  final List<Tombstone> tombstones;

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

  /// What the server last had for each row, keyed by [printed]'s keys.
  ///
  /// This is what lets a push send only what changed and a pull keep what has
  /// not been sent yet. Both used to work on the whole group, and both lost
  /// data doing it: a push re-sent every row from this phone's copy, so an
  /// edit someone else made twenty seconds ago was overwritten by whoever
  /// pushed next; and a pull replaced every row with the server's, so an edit
  /// whose push had failed was erased from the phone that made it.
  ///
  /// A row whose print differs from its entry here has been changed on this
  /// phone and not yet accepted. A row with no entry has never been accepted.
  final Map<String, String> acked;

  /// Every syncing row of this group and its current print.
  Map<String, String> get printed => {
    'g': groupPrint,
    for (final m in members) 'm:${m.id}': m.syncPrint,
    for (final e in expenses) 'e:${e.id}': e.syncPrint,
    for (final r in recurring) 'r:${r.id}': r.syncPrint,
    for (final s in settlements) 's:${s.id}': s.syncPrint,
  };

  String get groupPrint => [name, icon].toString();

  /// Changed on this phone and not yet on the server.
  bool isDirty(String key, String print) => acked[key] != print;

  /// Anything at all still waiting to go up — for retrying, and for warning
  /// someone before they sign out and lose it.
  bool get hasPendingChanges =>
      !hasReachedServer ||
      tombstones.isNotEmpty ||
      printed.entries.any((e) => isDirty(e.key, e.value));

  bool get isDirect => kind == GroupKind.direct;

  int get total => expenses.fold(0, (s, e) => s + e.amount);

  Member? memberById(String id) => members.where((m) => m.id == id).firstOrNull;
  Member? get you => members.where((m) => m.isYou).firstOrNull;

  List<Member> get admins => members.where((m) => m.isAdmin).toList();

  /// Whether *you* can rename it, re-badge it, remove people or delete it.
  ///
  /// A direct ledger says yes to both seats: "what I owe Ritu" belongs to the
  /// two of you equally, and one of you holding it hostage is not a hierarchy
  /// the relationship has.
  bool get youAreAdmin => isDirect || (you?.isAdmin ?? false);

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

  /// What two people owe each other in this ledger, and nobody else.
  ///
  /// Positive means [otherId] owes [meId]. This is the debt as it actually
  /// arose — you paid for dinner, they had a share of it — before [simplify]
  /// reroutes anything. The two numbers answer different questions and both
  /// are true: *what do I owe Sahil* is this one, and *who should pay whom to
  /// end this with the fewest transfers* is the other.
  ///
  /// Summed over everyone else in the group this comes back to [yourBalance],
  /// so the two readings can never disagree about the total.
  int pairBalance(String meId, String otherId) {
    var net = 0;
    for (final e in expenses) {
      if (e.payerId == meId) net += e.shares[otherId] ?? 0;
      if (e.payerId == otherId) net -= e.shares[meId] ?? 0;
    }
    for (final s in settlements) {
      // A claim is not a payment here either.
      if (!s.clearsDebt) continue;
      if (s.fromId == otherId && s.toId == meId) net -= s.amount;
      if (s.fromId == meId && s.toId == otherId) net += s.amount;
    }
    return net;
  }

  /// What [other] owes *you* here. Positive means they owe you.
  int pairBalanceWithYou(String otherId) {
    final me = you?.id;
    return me == null ? 0 : pairBalance(me, otherId);
  }

  /// Whether [simplify] is going to name a payment between two people who
  /// never actually transacted — the case that needs saying out loud.
  ///
  /// True when somebody is asked to pay someone they owe nothing to directly.
  /// It is the right answer arithmetically and a surprising one socially, so
  /// the screen that shows it explains itself rather than looking wrong.
  bool get simplifyReroutes {
    for (final t in simplify(balances)) {
      if (pairBalance(t.from, t.to) >= 0) return true;
    }
    return false;
  }

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
    'icon': icon,
    'members': members.map((m) => m.toJson()).toList(),
    'expenses': expenses.map((e) => e.toJson()).toList(),
    'settlements': settlements.map((s) => s.toJson()).toList(),
    'recurring': recurring.map((r) => r.toJson()).toList(),
    'tombstones': tombstones.map((t) => t.toJson()).toList(),
    'acked': acked,
    'createdAt': createdAt.toIso8601String(),
    'syncedAt': syncedAt?.toIso8601String(),
  };

  factory Group.fromJson(Map<String, dynamic> j) => Group(
    id: j['id'] as String,
    name: j['name'] as String,
    kind: GroupKind.values.byName(j['kind'] as String? ?? 'group'),
    icon: j['icon'] as String?,
    members: (j['members'] as List).map((m) => Member.fromJson((m as Map).cast())).toList(),
    expenses: (j['expenses'] as List? ?? []).map((e) => Expense.fromJson((e as Map).cast())).toList(),
    settlements: (j['settlements'] as List? ?? []).map((s) => Settlement.fromJson((s as Map).cast())).toList(),
    recurring: (j['recurring'] as List? ?? []).map((r) => Recurring.fromJson((r as Map).cast())).toList(),
    tombstones: (j['tombstones'] as List? ?? []).map((t) => Tombstone.fromJson((t as Map).cast())).toList(),
    acked: (j['acked'] as Map?)?.cast<String, String>(),
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
