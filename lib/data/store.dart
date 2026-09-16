import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../core/cycle.dart';
import 'models.dart';

/// How long a want must sit out of reach before crossing the line
/// earns an "In reach now" moment (short stints are silently cleared).
const kReachMomentMinWait = Duration(hours: 12);

class ReachLayout {
  const ReachLayout(this.pool, this.inReach, this.outOfReach);

  /// Money available to this segment.
  final int pool;
  final List<WishItem> inReach;

  /// Items past the "budget stops here" line, with how far short the budget falls.
  final List<(WishItem, int)> outOfReach;

  int get count => inReach.length + outOfReach.length;
}

/// Single source of truth. Local-first: everything is persisted to one JSON file.
class MullStore extends ChangeNotifier {
  MullStore._(this._file);

  final File? _file;
  Timer? _saveTimer;

  Profile profile = Profile();
  final List<WishItem> items = [];
  final List<Spend> spends = [];
  final List<NamedList> lists = [];
  final List<Group> groups = [];

  /// Per-cycle budget overrides ("just this month").
  final Map<String, int> budgetOverrides = {};

  /// Injectable for tests.
  DateTime Function() clock = DateTime.now;
  DateTime now() => clock();

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

  void _fromJson(Map<String, dynamic> j) {
    profile = Profile.fromJson((j['profile'] as Map).cast());
    items
      ..clear()
      ..addAll((j['items'] as List? ?? []).map((e) => WishItem.fromJson((e as Map).cast())));
    spends
      ..clear()
      ..addAll((j['spends'] as List? ?? []).map((e) => Spend.fromJson((e as Map).cast())));
    lists
      ..clear()
      ..addAll((j['lists'] as List? ?? []).map((e) => NamedList.fromJson((e as Map).cast())));
    groups
      ..clear()
      ..addAll((j['groups'] as List? ?? []).map((e) => Group.fromJson((e as Map).cast())));
    budgetOverrides
      ..clear()
      ..addAll((j['budgetOverrides'] as Map? ?? {}).cast<String, int>());
  }

  Map<String, dynamic> toJson() => {
    'version': 1,
    'profile': profile.toJson(),
    'items': items.map((e) => e.toJson()).toList(),
    'spends': spends.map((e) => e.toJson()).toList(),
    'lists': lists.map((e) => e.toJson()).toList(),
    'groups': groups.map((e) => e.toJson()).toList(),
    'budgetOverrides': budgetOverrides,
  };

  void _commit() {
    _trackReach();
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

  /// Re-evaluates time-based state (a new cycle, need checks) — call on resume.
  void refresh() => _commit();

  // ------------------------------------------------------------------ budget

  Cycle get cycle => Cycle.of(now(), profile.resetDay);
  int get budget => budgetOverrides[cycle.key] ?? profile.monthlyBudget;
  bool get budgetOverridden => budgetOverrides.containsKey(cycle.key);

  List<Spend> get cycleSpends {
    final c = cycle;
    return spends.where((s) => c.contains(s.date)).toList()..sort((a, b) => b.date.compareTo(a.date));
  }

  int get spent => cycleSpends.fold(0, (s, e) => s + e.amount);

  List<WishItem> _ofKind(ItemKind k) =>
      items.where((i) => i.kind == k).toList()..sort((a, b) => a.order.compareTo(b.order));

  List<WishItem> get needs => _ofKind(ItemKind.need);
  List<WishItem> get wants => _ofKind(ItemKind.want);
  int get needsTotal => needs.fold(0, (s, e) => s + e.price);

  /// Budget − spent − reserved needs. What the big number on the home screen shows.
  int get free => budget - spent - needsTotal;

  ReachLayout reach(ItemKind kind) {
    final list = _ofKind(kind);
    final pool = kind == ItemKind.need ? budget - spent : free;
    final inReach = <WishItem>[];
    final out = <(WishItem, int)>[];
    var running = 0;
    for (final item in list) {
      running += item.price;
      if (out.isEmpty && running <= pool) {
        inReach.add(item);
      } else {
        out.add((item, running - max(pool, 0)));
      }
    }
    return ReachLayout(pool, inReach, out);
  }

  /// Home "Up next": needs first, then wants the budget already covers.
  List<WishItem> get upNext => [...needs, ...reach(ItemKind.want).inReach];

  int get coveredCount => reach(ItemKind.need).inReach.length + reach(ItemKind.want).inReach.length;

  void setBudget(int amount, {bool justThisCycle = false}) {
    if (justThisCycle) {
      budgetOverrides[cycle.key] = amount;
    } else {
      budgetOverrides.remove(cycle.key);
      profile.monthlyBudget = amount;
    }
    _commit();
  }

  void setResetDay(int day) {
    profile.resetDay = day.clamp(1, 28);
    _commit();
  }

  void completeOnboarding({required String name, required int budget}) {
    profile
      ..name = name.trim()
      ..monthlyBudget = budget
      ..onboarded = true;
    _commit();
  }

  void updateProfile(void Function(Profile p) edit) {
    edit(profile);
    _commit();
  }

  // --------------------------------------------------------------- wishlist

  WishItem addItem({required String name, required int price, required ItemKind kind, String? url}) {
    final siblings = _ofKind(kind);
    final item = WishItem(
      name: name.trim(),
      price: price,
      kind: kind,
      url: url,
      order: siblings.isEmpty ? 0 : siblings.last.order + 1,
    );
    items.add(item);
    _commit();
    return item;
  }

  void updateItem(WishItem item) => _commit();

  void setKind(WishItem item, ItemKind kind) {
    if (item.kind == kind) return;
    final siblings = _ofKind(kind);
    item
      ..kind = kind
      ..order = siblings.isEmpty ? 0 : siblings.last.order + 1
      ..outOfReachSince = null;
    if (kind == ItemKind.need) item.needCheckedCycle = cycle.key;
    _commit();
  }

  void moveToTop(WishItem item) {
    final siblings = _ofKind(item.kind);
    item.order = siblings.isEmpty ? 0 : siblings.first.order - 1;
    _commit();
  }

  void confirmNeed(WishItem item) {
    item
      ..kind = ItemKind.need
      ..needCheckedCycle = cycle.key;
    _commit();
  }

  /// Needs that haven't been re-confirmed this cycle.
  List<WishItem> get needsToRecheck => needs.where((i) => i.needCheckedCycle != cycle.key).toList();

  WishItem removeItem(WishItem item) {
    items.removeWhere((i) => i.id == item.id);
    _commit();
    return item;
  }

  void restoreItem(WishItem item) {
    if (items.any((i) => i.id == item.id)) return;
    items.add(item);
    _commit();
  }

  Spend buyItem(WishItem item) {
    items.removeWhere((i) => i.id == item.id);
    final spend = Spend(name: item.name, amount: item.price, item: item.toJson());
    spends.add(spend);
    _commit();
    return spend;
  }

  /// Removes a spend; if it came from the wishlist, the item goes back.
  void removeSpend(Spend spend, {bool restoreItem = true}) {
    spends.removeWhere((s) => s.id == spend.id);
    final snapshot = spend.item;
    if (restoreItem && snapshot != null && !items.any((i) => i.id == snapshot['id'])) {
      items.add(WishItem.fromJson(snapshot)..outOfReachSince = null);
    }
    _commit();
  }

  Spend logSpend(String name, int amount, {DateTime? date}) {
    final spend = Spend(name: name.trim(), amount: amount, date: date);
    spends.add(spend);
    _commit();
    return spend;
  }

  void restoreSpend(Spend spend) {
    if (spends.any((s) => s.id == spend.id)) return;
    spends.add(spend);
    _commit();
  }

  // ------------------------------------------------------------ reach moments

  void _trackReach() {
    final layout = reach(ItemKind.want);
    final t = now();
    for (final item in layout.inReach) {
      final since = item.outOfReachSince;
      if (since != null && t.difference(since) < kReachMomentMinWait) item.outOfReachSince = null;
    }
    for (final (item, _) in layout.outOfReach) {
      item.outOfReachSince ??= t;
    }
  }

  /// Wants that waited below the line and have just crossed it.
  List<WishItem> get pendingInReach => reach(ItemKind.want).inReach.where((i) => i.outOfReachSince != null).toList();

  void keepWaiting(WishItem item) {
    item.outOfReachSince = null;
    _commit();
  }

  // ------------------------------------------------------------------ lists

  NamedList addList(String name, int? budget) {
    final list = NamedList(name: name.trim(), budget: budget);
    lists.add(list);
    _commit();
    return list;
  }

  void updateList(NamedList list) => _commit();

  void deleteList(NamedList list) {
    lists.removeWhere((l) => l.id == list.id);
    _commit();
  }

  void restoreList(NamedList list) {
    if (lists.any((l) => l.id == list.id)) return;
    lists.add(list);
    _commit();
  }

  void addEntry(NamedList list, String name, int price) {
    list.entries.add(ListEntry(name: name.trim(), price: price));
    _commit();
  }

  void toggleEntry(ListEntry entry) {
    entry.done = !entry.done;
    _commit();
  }

  void removeEntry(NamedList list, ListEntry entry) {
    list.entries.removeWhere((e) => e.id == entry.id);
    _commit();
  }

  void restoreEntry(NamedList list, ListEntry entry, int index) {
    if (list.entries.any((e) => e.id == entry.id)) return;
    list.entries.insert(index.clamp(0, list.entries.length), entry);
    _commit();
  }

  void reorderEntry(NamedList list, int from, int to) {
    final e = list.entries.removeAt(from);
    list.entries.insert(to > from ? to - 1 : to, e);
    _commit();
  }

  // ----------------------------------------------------------------- groups

  Group addGroup(String name, int target, List<String> others) {
    final group = Group(
      name: name.trim(),
      target: target,
      members: [
        Member(name: profile.name.isEmpty ? 'You' : profile.name, isYou: true),
        for (final n in others)
          if (n.trim().isNotEmpty) Member(name: n.trim()),
      ],
    );
    groups.add(group);
    _commit();
    return group;
  }

  void updateGroup(Group group) => _commit();

  void deleteGroup(Group group) {
    groups.removeWhere((g) => g.id == group.id);
    _commit();
  }

  void addMember(Group group, String name) {
    if (name.trim().isEmpty) return;
    group.members.add(Member(name: name.trim()));
    _commit();
  }

  void removeMember(Group group, Member member) {
    if (member.isYou) return;
    group.members.removeWhere((m) => m.id == member.id);
    _commit();
  }

  void setPledge(Member member, int amount, Pledge status) {
    member
      ..amount = status == Pledge.none ? 0 : amount
      ..status = status;
    _commit();
  }

  String displayName(Member m) => m.isYou ? '${profile.name.isEmpty ? 'You' : profile.name} (you)' : m.name;

  // ------------------------------------------------------------------ admin

  Future<void> resetAll() async {
    profile = Profile();
    items.clear();
    spends.clear();
    lists.clear();
    groups.clear();
    budgetOverrides.clear();
    _commit();
    await flush();
  }

  /// Mirrors the design mockups — handy for demos and screenshots.
  void loadSample() {
    final t = now();
    final c = cycle;
    DateTime ago(int days) => t.subtract(Duration(days: days));
    profile
      ..name = profile.name.isEmpty ? 'Ananya' : profile.name
      ..monthlyBudget = 40000
      ..onboarded = true;
    budgetOverrides.clear();
    items
      ..clear()
      ..addAll([
        WishItem(
          name: 'Laptop charger',
          price: 2400,
          kind: ItemKind.need,
          url: 'https://www.anker.in',
          order: 0,
          needCheckedCycle: c.key,
          createdAt: ago(6),
        ),
        WishItem(
          name: 'Running shoes',
          price: 6800,
          kind: ItemKind.need,
          url: 'https://www.decathlon.in',
          order: 1,
          needCheckedCycle: c.key,
          createdAt: ago(9),
        ),
        WishItem(
          name: 'Mechanical keyboard',
          price: 12900,
          originalPrice: 16000,
          kind: ItemKind.want,
          url: 'https://www.keychron.in',
          order: 0,
          createdAt: ago(38),
          outOfReachSince: ago(38),
        ),
        WishItem(
          name: 'Filter coffee kit',
          price: 1850,
          kind: ItemKind.want,
          url: 'https://bluetokaicoffee.com',
          order: 1,
          createdAt: ago(12),
        ),
        WishItem(
          name: 'Linen shirt',
          price: 3400,
          kind: ItemKind.want,
          url: 'https://www.nicobar.com',
          order: 2,
          createdAt: ago(4),
        ),
        WishItem(
          name: 'Headphones',
          price: 24990,
          kind: ItemKind.want,
          url: 'https://www.sony.co.in',
          order: 3,
          createdAt: ago(20),
        ),
        WishItem(
          name: 'Standing desk',
          price: 37800,
          kind: ItemKind.want,
          url: 'https://www.featherlite.in',
          order: 4,
          createdAt: ago(27),
        ),
      ]);
    final spendDay = c.contains(ago(3)) ? ago(3) : t;
    spends
      ..clear()
      ..addAll([
        Spend(name: 'Groceries', amount: 3800, date: spendDay),
        Spend(name: 'Movie night', amount: 2400, date: t),
      ]);
    groups
      ..clear()
      ..addAll([
        Group(
          name: 'Goa flights',
          target: 24000,
          members: [
            Member(name: profile.name, isYou: true, amount: 6000, status: Pledge.settled),
            Member(name: 'Sahil Mehta', amount: 6000, status: Pledge.settled),
            Member(name: 'Kabir Verma', amount: 6000, status: Pledge.declared),
            Member(name: 'Divya Tandon'),
            Member(name: 'Nikhil'),
          ],
        ),
        Group(
          name: 'Flat essentials',
          target: 12000,
          members: [
            Member(name: profile.name, isYou: true, amount: 3000, status: Pledge.declared),
            Member(name: 'Dev Thakur', amount: 2400, status: Pledge.settled),
            Member(name: 'Neha Menon', amount: 2000, status: Pledge.declared),
          ],
        ),
      ]);
    lists
      ..clear()
      ..add(
        NamedList(
          name: 'Goa trip',
          budget: 12000,
          entries: [
            ListEntry(name: 'Sunscreen', price: 650, done: true),
            ListEntry(name: 'Beach towel', price: 900, done: true),
            ListEntry(name: 'Sunglasses', price: 1800, done: true),
            ListEntry(name: 'Flip-flops', price: 700, done: true),
            ListEntry(name: 'Swim shorts', price: 1600),
            ListEntry(name: 'Dry bag', price: 1200),
            ListEntry(name: 'Snorkel set', price: 5400),
          ],
        ),
      );
    notifyListeners();
    _saveTimer = Timer(const Duration(milliseconds: 250), flush);
  }
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
