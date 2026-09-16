import 'dart:math';

import 'package:flutter/material.dart' show ThemeMode;

final _rng = Random();
String newId() =>
    '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}${_rng.nextInt(1 << 20).toRadixString(36)}';

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

enum Pledge { none, declared, settled }

class Member {
  Member({String? id, required this.name, this.isYou = false, this.amount = 0, this.status = Pledge.none})
    : id = id ?? newId();

  final String id;
  String name;
  final bool isYou;
  int amount;
  Pledge status;

  String get initials {
    final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) {
      final p = parts.first;
      return (p.length >= 2 ? p.substring(0, 2) : p).toUpperCase();
    }
    return (parts.first[0] + parts.last[0]).toUpperCase();
  }

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'isYou': isYou, 'amount': amount, 'status': status.name};

  factory Member.fromJson(Map<String, dynamic> j) => Member(
    id: j['id'] as String,
    name: j['name'] as String,
    isYou: j['isYou'] as bool? ?? false,
    amount: j['amount'] as int? ?? 0,
    status: Pledge.values.byName(j['status'] as String? ?? 'none'),
  );
}

class Group {
  Group({String? id, required this.name, required this.target, List<Member>? members, DateTime? createdAt})
    : id = id ?? newId(),
      members = members ?? [],
      createdAt = createdAt ?? DateTime.now();

  final String id;
  String name;
  int target;
  final List<Member> members;
  final DateTime createdAt;

  int get declared => members.where((m) => m.status != Pledge.none).fold(0, (s, m) => s + m.amount);
  int get undeclared => max(0, target - declared);
  List<Member> get yetToSay => members.where((m) => m.status == Pledge.none).toList();
  double get progress => target <= 0 ? 0 : (declared / target).clamp(0, 1).toDouble();

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'target': target,
    'members': members.map((m) => m.toJson()).toList(),
    'createdAt': createdAt.toIso8601String(),
  };

  factory Group.fromJson(Map<String, dynamic> j) => Group(
    id: j['id'] as String,
    name: j['name'] as String,
    target: j['target'] as int,
    members: (j['members'] as List).map((m) => Member.fromJson((m as Map).cast())).toList(),
    createdAt: _date(j['createdAt']),
  );
}

class Profile {
  Profile({
    this.name = '',
    this.monthlyBudget = 0,
    this.resetDay = 1,
    this.theme = ThemeMode.system,
    this.onboarded = false,
  });

  String name;
  int monthlyBudget;
  int resetDay;
  ThemeMode theme;
  bool onboarded;

  String get initial => name.trim().isEmpty ? '·' : name.trim()[0].toUpperCase();

  Map<String, dynamic> toJson() => {
    'name': name,
    'monthlyBudget': monthlyBudget,
    'resetDay': resetDay,
    'theme': theme.name,
    'onboarded': onboarded,
  };

  factory Profile.fromJson(Map<String, dynamic> j) => Profile(
    name: j['name'] as String? ?? '',
    monthlyBudget: j['monthlyBudget'] as int? ?? 0,
    resetDay: j['resetDay'] as int? ?? 1,
    theme: ThemeMode.values.byName(j['theme'] as String? ?? 'system'),
    onboarded: j['onboarded'] as bool? ?? false,
  );
}
