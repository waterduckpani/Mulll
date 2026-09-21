import 'package:flutter_test/flutter_test.dart';
import 'package:mull/core/split.dart';
import 'package:mull/data/models.dart';
import 'package:mull/screens/groups/split_editor.dart';

void main() {
  final you = Member(name: 'You', isYou: true);
  final dev = Member(name: 'Dev');
  final raj = Member(name: 'Raj');
  final group = Group(name: 'Flat', members: [you, dev, raj]);

  test('a 2:1 split reopens as 2:1, and saves unchanged', () {
    final saved = splitByWeight(3000, {you.id: 2, dev.id: 1});
    final model = SplitModel(group: group, method: SplitMethod.shares, shares: saved, amount: 3000);

    expect(model.weights[you.id]!.text, '2');
    expect(model.weights[dev.id]!.text, '1');
    expect(model.weights[raj.id]!.text, '');
    expect(model.shares, saved, reason: 'this used to come back as 1,500 each');
  });

  test('a three-way percent split reopens adding up to 100', () {
    final saved = splitEqually(1000, [you.id, dev.id, raj.id]);
    final model = SplitModel(group: group, method: SplitMethod.percent, shares: saved, amount: 1000);

    final total = [you, dev, raj].fold(0, (s, m) => s + int.parse(model.weights[m.id]!.text));
    expect(total, 100);
    expect(model.shares, saved);
  });

  test('changing a field re-derives the split', () {
    final saved = splitByWeight(3000, {you.id: 2, dev.id: 1});
    final model = SplitModel(group: group, method: SplitMethod.shares, shares: saved, amount: 3000);
    model.weights[dev.id]!.text = '2';

    expect(model.shares, {you.id: 1500, dev.id: 1500});
  });

  test('changing the amount re-derives the split', () {
    final saved = {you.id: 2000, dev.id: 1000};
    final model = SplitModel(group: group, method: SplitMethod.exact, shares: saved, amount: 3000)
      ..amount = 3300;

    expect(model.shares, isEmpty, reason: 'exact amounts that no longer add up are not a split');
  });
}
