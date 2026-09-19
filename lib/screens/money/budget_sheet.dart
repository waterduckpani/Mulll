import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/cycle.dart';
import '../../core/money.dart';
import '../../data/store.dart';
import '../../ui/icons.dart';
import '../../ui/sheet.dart';
import '../../ui/tokens.dart';
import '../../ui/widgets.dart';

Future<void> showBudgetSheet(BuildContext context) =>
    showMullSheet(context, height: 640, builder: (_) => const BudgetSheet());

class BudgetSheet extends StatefulWidget {
  const BudgetSheet({super.key});

  @override
  State<BudgetSheet> createState() => _BudgetSheetState();
}

enum _Scope { always, thisMonth }

class _BudgetSheetState extends State<BudgetSheet> {
  late final MullStore _store = context.readStore;
  late final _amount = AmountController(_store.budget);
  late _Scope _scope = _store.budgetOverridden ? _Scope.thisMonth : _Scope.always;
  late int _resetDay = _store.profile.resetDay;
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _amount.addListener(() => setState(() {}));
    _focus.addListener(() {
      if (!_focus.hasFocus) _amount.tidy();
    });
  }

  @override
  void dispose() {
    _amount.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _save() {
    final a = _amount.amount;
    if (a == null) return;
    if (_resetDay != _store.profile.resetDay) _store.setResetDay(_resetDay);
    _store.setBudget(a, justThisCycle: _scope == _Scope.thisMonth);
    HapticFeedback.mediumImpact();
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final keyboardUp = MediaQuery.viewInsetsOf(context).bottom > 0;
    final a = _amount.amount;
    final committed = _store.spent + _store.needsTotal;
    final month = _store.cycle.label;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SheetHeader('Monthly budget'),
        Expanded(
          child: SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(30, 20, 30, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                BigField(
                  controller: _amount,
                  focusNode: _focus,
                  numeric: true,
                  size: 56,
                  hint: '₹0',
                  help: Text(
                    a == null
                        ? 'What you can put towards things each month — after rent, bills and savings.'
                        : a < committed
                        ? 'That is ${inr(committed - a)} less than what is already spent and set aside for needs.'
                        : 'Leaves ${inr(a - committed)} for wants after spending and needs.',
                  ),
                ),
                const SizedBox(height: 26),
                ChoicePair<_Scope>(
                  height: 56,
                  options: [(_Scope.always, 'Every month'), (_Scope.thisMonth, 'Just $month')],
                  value: _scope,
                  onChanged: (s) => setState(() => _scope = s),
                ),
                const SizedBox(height: 26),
                Container(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  decoration: BoxDecoration(
                    border: Border(
                      top: BorderSide(color: c.line),
                      bottom: BorderSide(color: c.line),
                    ),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Month starts on the ${ordinal(_resetDay)}', style: ranade(15, color: c.ink)),
                            const SizedBox(height: 3),
                            Text('Match it to payday', style: ranade(11.5, color: c.ink3)),
                          ],
                        ),
                      ),
                      _Step(
                        glyph: MullGlyph.chevronLeft,
                        label: 'Earlier',
                        onTap: _resetDay > 1 ? () => setState(() => _resetDay--) : null,
                      ),
                      SizedBox(
                        width: 36,
                        child: Text(
                          '$_resetDay',
                          textAlign: TextAlign.center,
                          style: excon(19, color: c.ink),
                        ),
                      ),
                      _Step(
                        glyph: MullGlyph.chevronRight,
                        label: 'Later',
                        onTap: _resetDay < 28 ? () => setState(() => _resetDay++) : null,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(26, 8, 26, keyboardUp ? 4 : 34),
          child: PillButton('Save budget', onTap: a == null ? null : _save),
        ),
      ],
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({required this.glyph, required this.label, this.onTap});

  final MullGlyph glyph;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Opacity(
      opacity: onTap == null ? .3 : 1,
      child: CircleButton(
        semanticLabel: label,
        onTap: onTap,
        child: MullIcon(glyph, size: 18, color: c.ink, strokeWidth: 1.7),
      ),
    );
  }
}
