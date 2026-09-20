/// Who paid, and how the bill is divided.
///
/// Lifted out of the expense sheet because a standing expense asks exactly the
/// same question — rent is split the same way whether you are recording this
/// month's or describing every month's. Two copies of split maths is two places
/// for the rounding to disagree.
library;

import 'package:flutter/material.dart';

import '../../core/money.dart';
import '../../core/split.dart';
import '../../data/models.dart';
import '../../data/store.dart';
import '../../ui/icons.dart';
import '../../ui/tokens.dart';
import '../../ui/widgets.dart';

/// The editable state behind [SplitFields].
///
/// A [ChangeNotifier] rather than widget state, because the sheet around it
/// needs to know whether the split currently resolves — that is what enables
/// the save button — and passing that back up through callbacks meant every
/// keystroke rebuilding the sheet from the outside in.
class SplitModel extends ChangeNotifier {
  SplitModel({
    required this.group,
    String? payerId,
    SplitMethod method = SplitMethod.equal,
    Map<String, int>? shares,
    int amount = 0,
  }) : payerId = payerId ?? group.you?.id ?? group.members.first.id,
       _method = method,
       _amount = amount,
       included = shares == null
           ? group.members.map((m) => m.id).toSet()
           : shares.keys.toSet() {
    for (final m in group.members) {
      final share = shares?[m.id];
      weights[m.id] = TextEditingController(
        text: switch (method) {
          SplitMethod.exact => share?.toString() ?? '',
          SplitMethod.shares => share == null ? '' : '1',
          SplitMethod.percent => share == null || amount <= 0
              ? ''
              : (share * 100 / amount).round().toString(),
          SplitMethod.equal => '',
        },
      )..addListener(notifyListeners);
    }
  }

  final Group group;
  String payerId;

  /// Who the bill is divided between — the whole group unless someone sat out.
  Set<String> included;

  /// Raw per-person input for the methods that need one: rupees for [exact],
  /// a count for [shares], a percentage for [percent].
  final weights = <String, TextEditingController>{};

  SplitMethod _method;
  SplitMethod get method => _method;

  /// Changing method carries the *same* split across, rather than leaving two
  /// disagreeing descriptions of it behind.
  ///
  /// Who is in a split is said two different ways: a tick in Equally, a number
  /// in the other three. They used to drift apart — tick somebody out, switch
  /// to Exact, and the amount still sitting in their field put them quietly
  /// back in, which is the precise opposite of what the tick had just said.
  set method(SplitMethod value) {
    if (_method == value) return;
    final wasEqual = _method == SplitMethod.equal;
    _method = value;

    if (wasEqual) {
      // Leaving Equally: anyone ticked out has no business keeping a number.
      for (final m in group.members) {
        if (!included.contains(m.id)) weights[m.id]!.text = '';
      }
    } else if (value == SplitMethod.equal) {
      // Arriving at Equally: the ticks should say what the numbers said.
      final withValue = {
        for (final m in group.members)
          if ((_weightOf(m.id) ?? 0) > 0) m.id,
      };
      included = withValue.isEmpty ? group.members.map((m) => m.id).toSet() : withValue;
    }
    notifyListeners();
  }

  int _amount;
  int get amount => _amount;
  set amount(int value) {
    if (_amount == value) return;
    _amount = value;
    notifyListeners();
  }

  void setPayer(String id) {
    if (payerId == id) return;
    payerId = id;
    notifyListeners();
  }

  void toggle(String id) {
    if (!included.remove(id)) included.add(id);
    notifyListeners();
  }

  double? _weightOf(String id) {
    final text = weights[id]!.text.trim();
    if (text.isEmpty) return null;
    return double.tryParse(text);
  }

  /// The split as it currently stands, or an empty map if it does not resolve.
  Map<String, int> get shares {
    if (_amount <= 0) return const {};

    switch (_method) {
      case SplitMethod.equal:
        final ids = group.members.map((m) => m.id).where(included.contains).toList();
        return ids.isEmpty ? const {} : splitEqually(_amount, ids);

      case SplitMethod.exact:
        final out = <String, int>{};
        for (final m in group.members) {
          final value = _weightOf(m.id);
          if (value != null && value > 0) out[m.id] = value.round();
        }
        // Exact means exact: a split that does not add up to the bill is not a
        // split, so it stays invalid until the numbers agree.
        return out.values.fold(0, (s, v) => s + v) == _amount ? out : const {};

      case SplitMethod.percent:
        final w = <String, num>{};
        for (final m in group.members) {
          final value = _weightOf(m.id);
          if (value != null && value > 0) w[m.id] = value;
        }
        if (w.isEmpty) return const {};
        // Percentages have to be percentages.
        //
        // These went through the same weighting as shares, which normalises —
        // so 30 and 30 quietly became half each and the line underneath said
        // "Split by percentage" with a straight face. Nobody typing 30 means
        // 50. A percent split that does not come to 100 is a mistake being
        // made, and the only useful thing to do with it is say so.
        return _percentTotal(w) == 100 ? splitByWeight(_amount, w) : const {};

      case SplitMethod.shares:
        final w = <String, num>{};
        for (final m in group.members) {
          final value = _weightOf(m.id);
          if (value != null && value > 0) w[m.id] = value;
        }
        return w.isEmpty ? const {} : splitByWeight(_amount, w);
    }
  }

  /// Rounded to a whole percent, so 33.33 three times counts as 100 rather
  /// than failing on a third of a rupee nobody can type.
  static int _percentTotal(Map<String, num> weights) =>
      weights.values.fold<double>(0, (s, w) => s + w.toDouble()).round();

  /// What the percent fields currently add up to.
  int get percentEntered {
    final w = <String, num>{};
    for (final m in group.members) {
      final value = _weightOf(m.id);
      if (value != null && value > 0) w[m.id] = value;
    }
    return _percentTotal(w);
  }

  bool get isValid => shares.isNotEmpty;

  /// The line under the split that says whether it currently works.
  String get status {
    if (_amount <= 0) return 'Put the amount in first.';
    if (shares.isNotEmpty) {
      return switch (_method) {
        SplitMethod.equal => included.isEmpty
            ? 'Nobody is in this split.'
            : '${inr(_amount ~/ included.length)} each, give or take a rupee.',
        SplitMethod.exact => 'Adds up to ${inr(_amount)}.',
        SplitMethod.shares => 'Split by shares.',
        SplitMethod.percent => 'Split by percentage.',
      };
    }
    if (_method == SplitMethod.exact) {
      var assigned = 0;
      for (final m in group.members) {
        final v = _weightOf(m.id);
        if (v != null && v > 0) assigned += v.round();
      }
      final left = _amount - assigned;
      return left > 0 ? '${inr(left)} still to assign.' : '${inr(-left)} over the total.';
    }
    if (_method == SplitMethod.equal) return 'Nobody is in this split.';
    if (_method == SplitMethod.percent) {
      final entered = percentEntered;
      if (entered == 0) return 'Give at least one person a percentage.';
      return entered < 100
          ? '${100 - entered}% still to go.'
          : '${entered - 100}% over.';
    }
    return 'Give at least one person a number.';
  }

  @override
  void dispose() {
    for (final c in weights.values) {
      c.dispose();
    }
    super.dispose();
  }
}

/// "Who paid" chips, the method switch and a row per person.
class SplitFields extends StatelessWidget {
  const SplitFields({super.key, required this.model, this.payerLabel = 'Who paid'});

  final SplitModel model;
  final String payerLabel;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final store = context.store;
    final group = model.group;

    return ListenableBuilder(
      listenable: model,
      builder: (context, _) {
        final shares = model.shares;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Eyebrow(payerLabel, size: 10.5, tracking: .18),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final m in group.members)
                  NameChip(
                    store.shortName(m),
                    selected: m.id == model.payerId,
                    onTap: () => model.setPayer(m.id),
                  ),
              ],
            ),
            const SizedBox(height: 26),
            const Eyebrow('Split', size: 10.5, tracking: .18),
            const SizedBox(height: 12),
            Segmented(
              labels: const ['Equally', 'Exact', 'Shares', '%'],
              index: model.method.index,
              onChanged: (i) => model.method = SplitMethod.values[i],
            ),
            const SizedBox(height: 16),
            for (final m in group.members)
              _SplitRow(
                key: ValueKey(m.id),
                name: store.displayName(m),
                method: model.method,
                included: model.included.contains(m.id),
                controller: model.weights[m.id]!,
                share: shares[m.id],
                onToggle: () => model.toggle(m.id),
              ),
            const SizedBox(height: 14),
            Text(model.status, style: ranade(12, color: c.ink3)),
          ],
        );
      },
    );
  }
}

/// One person's line in the split editor.
class _SplitRow extends StatelessWidget {
  const _SplitRow({
    super.key,
    required this.name,
    required this.method,
    required this.included,
    required this.controller,
    required this.share,
    required this.onToggle,
  });

  final String name;
  final SplitMethod method;
  final bool included;
  final TextEditingController controller;
  final int? share;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final equal = method == SplitMethod.equal;
    final on = !equal || included;

    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Pressable(
        onTap: equal ? onToggle : null,
        scale: equal ? .99 : 1,
        haptic: equal,
        child: SizedBox(
          height: 52,
          child: Row(
            children: [
              if (equal)
                Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: Checkbox24(on: included),
                ),
              Expanded(
                child: Text(
                  name,
                  style: ranade(15.5, color: on ? c.ink : c.ink3),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (!equal)
                SizedBox(
                  width: 82,
                  child: TextField(
                    controller: controller,
                    textAlign: TextAlign.right,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    style: excon(17, color: c.ink),
                    keyboardAppearance: c.isDark ? Brightness.dark : Brightness.light,
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: method == SplitMethod.percent
                          ? '0%'
                          : (method == SplitMethod.shares ? '0' : '₹0'),
                      hintStyle: excon(17, color: c.ink3.withValues(alpha: .6)),
                      border: UnderlineInputBorder(borderSide: BorderSide(color: c.inputLine)),
                      enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: c.inputLine)),
                      focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: c.ink2)),
                      contentPadding: const EdgeInsets.only(bottom: 6),
                    ),
                  ),
                ),
              SizedBox(
                width: 92,
                child: Text(
                  share == null ? '·' : inr(share!),
                  textAlign: TextAlign.right,
                  style: excon(17, color: share == null ? c.ink3 : c.ink),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The tick used wherever something is in or out.
///
/// A filled circle with no outline, the same mark the selection rows use: the
/// design has no borders anywhere, so an empty one is a faint disc rather than
/// a ring drawn in a line.
class Checkbox24 extends StatelessWidget {
  const Checkbox24({super.key, required this.on});

  final bool on;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return AnimatedContainer(
      duration: motion(context, const Duration(milliseconds: 180)),
      width: 26,
      height: 26,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: on ? c.ink : c.ink.withValues(alpha: .1),
        shape: BoxShape.circle,
      ),
      child: on ? MullIcon(MullGlyph.check, size: 13, color: c.screen, strokeWidth: 2.6) : null,
    );
  }
}

/// A labelled checkbox row — "Add it without asking".
class CheckRow extends StatelessWidget {
  const CheckRow({super.key, required this.on, required this.label, required this.onTap, this.help});

  final bool on;
  final String label;
  final String? help;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Pressable(
      onTap: onTap,
      scale: .99,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Checkbox24(on: on),
              const SizedBox(width: 12),
              Expanded(
                child: Text(label, style: ranade(15, color: on ? c.ink : c.ink2)),
              ),
            ],
          ),
          if (help != null && on)
            Padding(
              padding: const EdgeInsets.only(top: 8, left: 34),
              child: Text(help!, style: ranade(11.5, height: 1.6, color: c.ink3)),
            ),
        ],
      ),
    );
  }
}
