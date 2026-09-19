import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../core/cycle.dart';
import '../core/money.dart';
import '../core/split.dart';
import '../core/upi_receipt.dart';
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
  void replaceGroups(List<Group> incoming) {
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
    groups
      ..clear()
      ..addAll(incoming)
      ..addAll(unsynced);
    _commit();
  }

  /// Notes that the server has taken a copy. Local-only: re-pushing here would
  /// loop, since a push is what got us here.
  void markGroupSynced(Group group) {
    group.syncedAt = DateTime.now();
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
  //
  // The budget is a ruler, not a ledger. Nothing here claims money has left
  // anyone's account — it answers one question: what can this month cover?
  //
  //   room           the budget, minus what was actually bought
  //   needsReserved  the needs queue, set aside first
  //   leftForWants   what is left over for everything else
  //
  // Only buying moves `spent`. Putting something on the wishlist never does,
  // because wanting a thing costs nothing.

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

  /// The budget, minus what has actually been bought this cycle.
  int get room => budget - spent;

  /// Needs come first in the queue, so they are set aside before wants. Capped
  /// at what is actually there: needs that outgrow the budget cannot reserve
  /// money that doesn't exist, they just run off the end of the ruler.
  int get needsReserved => needsTotal.clamp(0, max(room, 0));

  /// The headline number. Negative when the needs alone outgrow the budget.
  int get leftForWants => room - needsTotal;

  /// A typical month's room for wants, ignoring what has already gone this
  /// cycle — the rate at which the wishlist actually clears, month over month.
  int get monthlyWantRoom => budget - needsTotal;

  ReachLayout reach(ItemKind kind) {
    final list = _ofKind(kind);
    final pool = kind == ItemKind.need ? room : leftForWants;
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

  int get coveredCount => reach(ItemKind.need).inReach.length + reach(ItemKind.want).inReach.length;

  /// Roughly how many cycles until [item] comes into reach, counting
  /// everything queued ahead of it — the wishlist clears top-down, so an item
  /// waits for its turn as much as for its price.
  ///
  /// Null when the honest answer is "we don't know": needs already outgrow the
  /// budget, or it is far enough out that a month count would be a fiction.
  int? monthsToReach(WishItem item) {
    if (item.kind == ItemKind.need) return null;
    final rate = monthlyWantRoom;
    if (rate <= 0) return null;
    var cumulative = 0;
    for (final want in wants) {
      cumulative += want.price;
      if (want.id == item.id) break;
    }
    final months = (cumulative / rate).ceil();
    return months > 24 ? null : months.clamp(1, 24);
  }

  /// The cycle [item] should come within reach in.
  DateTime? reachDate(WishItem item) {
    final months = monthsToReach(item);
    if (months == null) return null;
    final start = cycle.start;
    return DateTime(start.year, start.month + months, start.day);
  }

  /// How far past this month's line buying [item] would land, or 0 if it fits.
  ///
  /// Measured against what is left right now rather than the item's place in
  /// the queue: buying is something you do to one item today, so the honest
  /// comparison is its price against the money still on the table.
  ///
  /// This is the *only* warning the buy flow needs. If two wants are both in
  /// reach, that already means the budget covers them together — so buying one
  /// can never push the other out. Spending what you planned to spend is not
  /// an event. Spending past the line is.
  int overBudgetBy(WishItem item) => max(0, item.price - max(room, 0));

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

  /// [friends] are people with a Mull account, seated with `userId` attached so
  /// their name and UPI ID come from their own profile. [others] are bare names
  /// — placeholders for people who are not on Mull, which still need to work:
  /// you should be able to split tonight's dinner without everyone at the table
  /// installing something first.
  Group addGroup(String name, List<String> others, {List<Member> friends = const []}) {
    final group = Group(
      name: name.trim(),
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
    if (member.isYou) return false;
    final involved = group.expenses.any((e) => e.payerId == member.id || e.shares.containsKey(member.id));
    final settled = group.settlements.any((s) => s.fromId == member.id || s.toId == member.id);
    return !involved && !settled;
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

  // ---------------------------------------------------------------- expenses

  Expense addExpense(
    Group group, {
    required String description,
    required int amount,
    required String payerId,
    required Map<String, int> shares,
    SplitMethod method = SplitMethod.equal,
    bool repeatsMonthly = false,
    DateTime? date,
  }) {
    final expense = Expense(
      description: description.trim(),
      amount: amount,
      payerId: payerId,
      shares: Map.of(shares),
      method: method,
      repeatsMonthly: repeatsMonthly,
      date: date,
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

  /// Next month's copy of a repeating expense, ready to be reviewed.
  ///
  /// Deliberately a suggestion rather than a scheduler: rent changes, people
  /// move out, and an expense that appears on its own is one nobody checked.
  Expense repeatExpense(Group group, Expense source) {
    final next = DateTime(source.date.year, source.date.month + 1, source.date.day);
    return addExpense(
      group,
      description: source.description,
      amount: source.amount,
      payerId: source.payerId,
      shares: Map.of(source.shares),
      method: source.method,
      repeatsMonthly: true,
      date: next,
    );
  }

  /// Repeating expenses whose next month has come round and not been added.
  List<Expense> dueRepeats(Group group) {
    final t = now();
    return group.expenses.where((e) {
      if (!e.repeatsMonthly) return false;
      final due = DateTime(e.date.year, e.date.month + 1, e.date.day);
      if (due.isAfter(t)) return false;
      // Already carried forward if a later copy of the same thing exists.
      return !group.expenses.any((other) => other.description == e.description && other.date.isAfter(e.date));
    }).toList();
  }

  /// Everything that happened in the group, newest first.
  List<Object> activity(Group group) =>
      [...group.expenses, ...group.settlements]..sort((a, b) {
        final da = a is Expense ? a.date : (a as Settlement).date;
        final db = b is Expense ? b.date : (b as Settlement).date;
        return db.compareTo(da);
      });

  /// Your position across every group at once, for the groups list header.
  int get groupsNet => groups.fold(0, (s, g) => s + g.yourBalance);

  String displayName(Member m) => m.isYou ? 'You' : m.name;

  String shortName(Member m) => m.isYou ? 'You' : m.name.split(' ').first;

  /// The group's state as a message you can paste into WhatsApp.
  ///
  /// Plain text on purpose: the people who need to read it may not have Mull,
  /// and an unreadable summary is the same as no summary.
  String groupSummary(Group group) {
    final lines = <String>['${group.name} · split on Mull', ''];
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
    // userId set means the seat has been claimed by a real account, which is
    // what lets a settlement wait on them to confirm.
    final you = Member(name: profile.name, isYou: true, upiId: 'ananya@okhdfc', userId: 'u-you');
    final sahil = Member(name: 'Sahil Mehta', upiId: 'sahil@okaxis', userId: 'u-sahil');
    final kabir = Member(name: 'Kabir Verma', upiId: 'kabirv@ybl', userId: 'u-kabir');
    final divya = Member(name: 'Divya Tandon');
    final dev = Member(name: 'Dev Thakur', upiId: 'devthakur@okicici', userId: 'u-dev');
    final neha = Member(name: 'Neha Menon');

    groups
      ..clear()
      ..addAll([
        Group(
          name: 'Goa trip',
          members: [you, sahil, kabir, divya],
          expenses: [
            Expense(
              description: 'Flights',
              amount: 24000,
              payerId: you.id,
              shares: splitEqually(24000, [you.id, sahil.id, kabir.id, divya.id]),
              date: ago(9),
            ),
            Expense(
              description: 'Airbnb',
              amount: 18000,
              payerId: sahil.id,
              shares: splitEqually(18000, [you.id, sahil.id, kabir.id, divya.id]),
              date: ago(8),
            ),
            // The dinner nobody splits evenly: Divya skipped it.
            Expense(
              description: 'Dinner at Thalassa',
              amount: 5400,
              payerId: kabir.id,
              shares: splitEqually(5400, [you.id, sahil.id, kabir.id]),
              date: ago(6),
            ),
          ],
          settlements: [
            Settlement(
              fromId: divya.id,
              toId: you.id,
              amount: 5000,
              status: SettlementStatus.confirmed,
              date: ago(2),
              confirmedAt: ago(2),
            ),
            // Kabir says he has sent his share. Until you say it landed, he
            // still owes it — this is the claim waiting on you.
            Settlement(fromId: kabir.id, toId: you.id, amount: 7500, utr: '447126558301', date: ago(1)),
          ],
        ),
        Group(
          name: 'Flat',
          members: [you, dev, neha],
          expenses: [
            Expense(
              description: 'Wifi',
              amount: 1800,
              payerId: dev.id,
              shares: splitEqually(1800, [you.id, dev.id, neha.id]),
              date: ago(4),
            ),
            Expense(
              description: 'Groceries',
              amount: 3200,
              payerId: you.id,
              shares: splitEqually(3200, [you.id, dev.id, neha.id]),
              date: ago(1),
            ),
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
