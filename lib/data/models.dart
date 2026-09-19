import 'dart:math';

import 'package:flutter/material.dart' show ThemeMode;

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

enum ItemKind { need, want }

class WishItem {
  WishItem({
    String? id,
    required this.name,
    required this.price,
    int? originalPrice,
    required this.kind,
    this.url,
    DateTime? createdAt,
    this.order = 0,
    this.needCheckedCycle,
    this.outOfReachSince,
  }) : id = id ?? newId(),
       originalPrice = originalPrice ?? price,
       createdAt = createdAt ?? DateTime.now();

  final String id;
  String name;
  int price;

  /// Price when first added — lets "In reach" say how much waiting saved.
  int originalPrice;
  ItemKind kind;
  String? url;
  final DateTime createdAt;
  double order;

  /// Cycle key in which the user last confirmed this is truly a need.
  String? needCheckedCycle;

  /// Set when a want falls below the reach line; cleared once acknowledged.
  DateTime? outOfReachSince;

  String? get domain {
    final u = url;
    if (u == null) return null;
    final host = Uri.tryParse(u)?.host;
    if (host == null || host.isEmpty) return null;
    return host.replaceFirst(RegExp(r'^(www\d?|m)\.'), '');
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'price': price,
    'originalPrice': originalPrice,
    'kind': kind.name,
    'url': url,
    'createdAt': createdAt.toIso8601String(),
    'order': order,
    'needCheckedCycle': needCheckedCycle,
    'outOfReachSince': outOfReachSince?.toIso8601String(),
  };

  factory WishItem.fromJson(Map<String, dynamic> j) => WishItem(
    id: j['id'] as String,
    name: j['name'] as String,
    price: j['price'] as int,
    originalPrice: j['originalPrice'] as int?,
    kind: ItemKind.values.byName(j['kind'] as String),
    url: j['url'] as String?,
    createdAt: _date(j['createdAt']),
    order: (j['order'] as num?)?.toDouble() ?? 0,
    needCheckedCycle: j['needCheckedCycle'] as String?,
    outOfReachSince: _date(j['outOfReachSince']),
  );
}

class Spend {
  Spend({String? id, required this.name, required this.amount, DateTime? date, this.item})
    : id = id ?? newId(),
      date = date ?? DateTime.now();

  final String id;
  String name;
  int amount;
  DateTime date;

  /// Snapshot of the wishlist item this purchase came from, so it can be put back.
  final Map<String, dynamic>? item;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'amount': amount,
    'date': date.toIso8601String(),
    'item': item,
  };

  factory Spend.fromJson(Map<String, dynamic> j) => Spend(
    id: j['id'] as String,
    name: j['name'] as String,
    amount: j['amount'] as int,
    date: _date(j['date']),
    item: (j['item'] as Map?)?.cast<String, dynamic>(),
  );
}

class ListEntry {
  ListEntry({String? id, required this.name, required this.price, this.done = false}) : id = id ?? newId();

  final String id;
  String name;
  int price;
  bool done;

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'price': price, 'done': done};

  factory ListEntry.fromJson(Map<String, dynamic> j) => ListEntry(
    id: j['id'] as String,
    name: j['name'] as String,
    price: j['price'] as int,
    done: j['done'] as bool? ?? false,
  );
}

class NamedList {
  NamedList({String? id, required this.name, this.budget, List<ListEntry>? entries, DateTime? createdAt})
    : id = id ?? newId(),
      entries = entries ?? [],
      createdAt = createdAt ?? DateTime.now();

  final String id;
  String name;
  int? budget;
  final List<ListEntry> entries;
  final DateTime createdAt;

  int get doneCount => entries.where((e) => e.done).length;
  int get total => entries.fold(0, (s, e) => s + e.price);

  /// Index of the first entry that no longer fits the list budget, or null.
  int? get reachBreak {
    final b = budget;
    if (b == null) return null;
    var running = 0;
    for (var i = 0; i < entries.length; i++) {
      running += entries[i].price;
      if (running > b) return i;
    }
    return null;
  }

  int get inBudgetTotal {
    final cut = reachBreak ?? entries.length;
    return entries.take(cut).fold(0, (s, e) => s + e.price);
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'budget': budget,
    'entries': entries.map((e) => e.toJson()).toList(),
    'createdAt': createdAt.toIso8601String(),
  };

  factory NamedList.fromJson(Map<String, dynamic> j) => NamedList(
    id: j['id'] as String,
    name: j['name'] as String,
    budget: j['budget'] as int?,
    entries: (j['entries'] as List).map((e) => ListEntry.fromJson((e as Map).cast())).toList(),
    createdAt: _date(j['createdAt']),
  );
}

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
  }) : id = id ?? newId();

  final String id;
  String name;
  final bool isYou;

  /// How an unclaimed seat finds its owner. You add "Ritu" tonight; if she ever
  /// signs up on this address or number, the seat becomes hers and the history
  /// she was already part of comes with it. Either will do — login is by email
  /// today, but the match is kept open to both.
  String? email;

  /// E.164.
  String? phone;

  /// Null while the seat is still a placeholder — nobody has claimed it.
  String? userId;

  /// Whether there is a real person behind this seat who could answer.
  bool get isLinked => userId != null;

  /// Their UPI address, so settling up is one tap instead of a screenshot and
  /// a retyped amount.
  String? upiId;

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
  };

  factory Member.fromJson(Map<String, dynamic> j) => Member(
    id: j['id'] as String,
    name: j['name'] as String,
    isYou: j['isYou'] as bool? ?? false,
    upiId: j['upiId'] as String?,
    email: j['email'] as String?,
    phone: j['phone'] as String?,
    userId: j['userId'] as String?,
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
    this.repeatsMonthly = false,
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

  /// Rent, wifi and the maid are the same number every month. This only records
  /// the intent — Mull offers to add next month's when the time comes rather
  /// than creating expenses behind anyone's back.
  bool repeatsMonthly;
  DateTime date;

  Map<String, dynamic> toJson() => {
    'id': id,
    'description': description,
    'amount': amount,
    'payerId': payerId,
    'shares': shares,
    'method': method.name,
    'repeatsMonthly': repeatsMonthly,
    'date': date.toIso8601String(),
  };

  factory Expense.fromJson(Map<String, dynamic> j) => Expense(
    id: j['id'] as String,
    description: j['description'] as String,
    amount: j['amount'] as int,
    payerId: j['payerId'] as String,
    shares: (j['shares'] as Map).map((k, v) => MapEntry(k as String, (v as num).toInt())),
    method: SplitMethod.values.byName(j['method'] as String? ?? 'equal'),
    repeatsMonthly: j['repeatsMonthly'] as bool? ?? false,
    date: _date(j['date']),
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

class Group {
  Group({
    String? id,
    required this.name,
    List<Member>? members,
    List<Expense>? expenses,
    List<Settlement>? settlements,
    DateTime? createdAt,
    this.syncedAt,
  }) : id = id ?? newId(),
       members = members ?? [],
       expenses = expenses ?? [],
       settlements = settlements ?? [],
       createdAt = createdAt ?? DateTime.now();

  final String id;
  String name;
  final List<Member> members;
  final List<Expense> expenses;
  final List<Settlement> settlements;
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

  int get total => expenses.fold(0, (s, e) => s + e.amount);

  Member? memberById(String id) => members.where((m) => m.id == id).firstOrNull;
  Member? get you => members.where((m) => m.isYou).firstOrNull;

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

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'members': members.map((m) => m.toJson()).toList(),
    'expenses': expenses.map((e) => e.toJson()).toList(),
    'settlements': settlements.map((s) => s.toJson()).toList(),
    'createdAt': createdAt.toIso8601String(),
    'syncedAt': syncedAt?.toIso8601String(),
  };

  /// Groups saved before expenses existed carried a `target` and a pledge per
  /// member. There is no honest way to turn "said they'd put in ₹6,000" into a
  /// ledger entry — nobody recorded who actually paid — so the people carry
  /// over and the numbers do not.
  factory Group.fromJson(Map<String, dynamic> j) => Group(
    id: j['id'] as String,
    name: j['name'] as String,
    members: (j['members'] as List).map((m) => Member.fromJson((m as Map).cast())).toList(),
    expenses: (j['expenses'] as List? ?? []).map((e) => Expense.fromJson((e as Map).cast())).toList(),
    settlements: (j['settlements'] as List? ?? []).map((s) => Settlement.fromJson((s as Map).cast())).toList(),
    createdAt: _date(j['createdAt']),
    syncedAt: j['syncedAt'] == null ? null : DateTime.tryParse(j['syncedAt'] as String),
  );
}

class Profile {
  Profile({
    this.name = '',
    this.monthlyBudget = 0,
    this.resetDay = 1,
    this.theme = ThemeMode.system,
    this.onboarded = false,
    this.upiId,
  });

  String name;
  int monthlyBudget;
  int resetDay;
  ThemeMode theme;
  bool onboarded;

  /// Your own UPI address — goes into the summaries you send people so they can
  /// pay you back without asking for it every time.
  String? upiId;

  String get initial => name.trim().isEmpty ? '·' : name.trim()[0].toUpperCase();

  Map<String, dynamic> toJson() => {
    'name': name,
    'monthlyBudget': monthlyBudget,
    'resetDay': resetDay,
    'theme': theme.name,
    'onboarded': onboarded,
    'upiId': upiId,
  };

  factory Profile.fromJson(Map<String, dynamic> j) => Profile(
    name: j['name'] as String? ?? '',
    monthlyBudget: j['monthlyBudget'] as int? ?? 0,
    resetDay: j['resetDay'] as int? ?? 1,
    theme: ThemeMode.values.byName(j['theme'] as String? ?? 'system'),
    onboarded: j['onboarded'] as bool? ?? false,
    upiId: j['upiId'] as String?,
  );
}
