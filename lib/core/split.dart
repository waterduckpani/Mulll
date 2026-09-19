/// Splitting a bill, and working out who ends up owing whom.
///
/// Everything here is whole rupees. Paise would be more precise and less
/// useful: nobody settles 33.33 over UPI, and a split that does not add back up
/// to the bill is the fastest way to lose an argument.
library;

import 'dart:math';

/// One person paying another to clear what they owe.
class Transfer {
  const Transfer({required this.from, required this.to, required this.amount});

  final String from;
  final String to;
  final int amount;

  @override
  String toString() => '$from → $to: $amount';
}

/// Spreads [amount] across [ids] as evenly as rupees allow.
///
/// The leftover goes to the people at the front rather than being dropped, so
/// ₹100 between three is 34/33/33 and still totals ₹100.
Map<String, int> splitEqually(int amount, List<String> ids) {
  if (ids.isEmpty) return {};
  final base = amount ~/ ids.length;
  final leftover = amount - base * ids.length;
  return {
    for (final (i, id) in ids.indexed) id: base + (i < leftover ? 1 : 0),
  };
}

/// Splits by weight — shares ("Dev eats two portions") or percentages.
///
/// Largest-remainder: everyone gets their floor, then the odd rupees go to
/// whoever was rounded down hardest. Ties break on order so the same input
/// always gives the same answer.
Map<String, int> splitByWeight(int amount, Map<String, num> weights) {
  final ids = weights.keys.toList();
  if (ids.isEmpty) return {};
  final total = weights.values.fold<double>(0, (s, w) => s + w.toDouble());
  if (total <= 0) return splitEqually(amount, ids);

  final out = <String, int>{};
  final remainders = <(String, double)>[];
  var assigned = 0;
  for (final id in ids) {
    final exact = amount * weights[id]!.toDouble() / total;
    final floor = exact.floor();
    out[id] = floor;
    assigned += floor;
    remainders.add((id, exact - floor));
  }

  remainders.sort((a, b) => b.$2.compareTo(a.$2));
  for (var i = 0; i < amount - assigned; i++) {
    final id = remainders[i % remainders.length].$1;
    out[id] = out[id]! + 1;
  }
  return out;
}

/// The fewest payments that clear every balance.
///
/// Positive balance means the person is owed; negative means they owe. Repeatedly
/// matching the biggest debtor to the biggest creditor settles a group of n in
/// at most n−1 payments, which is the difference between three UPI transfers
/// after a trip and twelve.
List<Transfer> simplify(Map<String, int> balances) {
  final debtors = <(String, int)>[];
  final creditors = <(String, int)>[];
  balances.forEach((id, value) {
    if (value < 0) {
      debtors.add((id, -value));
    } else if (value > 0) {
      creditors.add((id, value));
    }
  });

  // Biggest first, then by id, so the same ledger always simplifies the same way.
  int bySize((String, int) a, (String, int) b) =>
      b.$2 != a.$2 ? b.$2.compareTo(a.$2) : a.$1.compareTo(b.$1);
  debtors.sort(bySize);
  creditors.sort(bySize);

  final out = <Transfer>[];
  var i = 0;
  var j = 0;
  var owed = debtors.isEmpty ? 0 : debtors.first.$2;
  var due = creditors.isEmpty ? 0 : creditors.first.$2;

  while (i < debtors.length && j < creditors.length) {
    final amount = min(owed, due);
    if (amount > 0) out.add(Transfer(from: debtors[i].$1, to: creditors[j].$1, amount: amount));
    owed -= amount;
    due -= amount;
    if (owed == 0) {
      i++;
      if (i < debtors.length) owed = debtors[i].$2;
    }
    if (due == 0) {
      j++;
      if (j < creditors.length) due = creditors[j].$2;
    }
  }
  return out;
}
