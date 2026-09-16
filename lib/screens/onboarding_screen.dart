import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/money.dart';
import '../data/store.dart';
import '../ui/tokens.dart';
import '../ui/widgets.dart';

/// Three calm steps: what Mull is, your name, your monthly budget.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _pages = PageController();
  final _name = TextEditingController();
  final _budget = AmountController();
  final _nameFocus = FocusNode();
  final _budgetFocus = FocusNode();
  int _step = 0;

  @override
  void initState() {
    super.initState();
    _name.addListener(() => setState(() {}));
    _budget.addListener(() => setState(() {}));
    _budgetFocus.addListener(() {
      if (!_budgetFocus.hasFocus) _budget.tidy();
    });
  }

  @override
  void dispose() {
    _pages.dispose();
    _name.dispose();
    _budget.dispose();
    _nameFocus.dispose();
    _budgetFocus.dispose();
    super.dispose();
  }

  void _go(int step) {
    HapticFeedback.lightImpact();
    setState(() => _step = step);
    _pages.animateToPage(step, duration: const Duration(milliseconds: 520), curve: Curves.easeInOutCubic);
    Future.delayed(const Duration(milliseconds: 420), () {
      if (!mounted) return;
      if (step == 1) _nameFocus.requestFocus();
      if (step == 2) _budgetFocus.requestFocus();
    });
  }

  void _finish() {
    final budget = _budget.amount;
    if (budget == null) return;
    HapticFeedback.heavyImpact();
    context.readStore.completeOnboarding(name: _name.text, budget: budget);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final bottom = MediaQuery.paddingOf(context).bottom;
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;

    final (cta, onTap) = switch (_step) {
      0 => ('Get started', () => _go(1)),
      1 => ('Continue', _name.text.trim().isEmpty ? null : () => _go(2)),
      _ => ('Start mulling', _budget.amount == null ? null : _finish),
    };

    return Scaffold(
      backgroundColor: c.screen,
      resizeToAvoidBottomInset: false,
      body: Stack(
        children: [
          const Positioned.fill(
            child: Backdrop(
              blobs: [
                BlobSpec(360, 62, top: -40, left: -90),
                BlobSpec(300, 70, bottom: 100, right: -110),
              ],
            ),
          ),
          SafeArea(
            bottom: false,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
                  child: SizedBox(
                    height: 44,
                    child: Row(
                      children: [
                        AnimatedOpacity(
                          opacity: _step == 0 ? 0 : 1,
                          duration: const Duration(milliseconds: 300),
                          child: Text(
                            'mull',
                            style: TextStyle(
                              fontFamily: 'Chillax',
                              fontSize: 20,
                              fontWeight: FontWeight.w600,
                              color: c.ink,
                            ),
                          ),
                        ),
                        const Spacer(),
                        for (var i = 0; i < 3; i++)
                          AnimatedContainer(
                            duration: const Duration(milliseconds: 300),
                            margin: const EdgeInsets.only(left: 6),
                            width: i == _step ? 18 : 6,
                            height: 6,
                            decoration: BoxDecoration(
                              color: i == _step ? c.ink : c.line,
                              borderRadius: BorderRadius.circular(3),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                Expanded(
                  child: PageView(
                    controller: _pages,
                    physics: const NeverScrollableScrollPhysics(),
                    children: [
                      _Step(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              'mull',
                              style: TextStyle(
                                fontFamily: 'Chillax',
                                fontSize: 64,
                                fontWeight: FontWeight.w600,
                                letterSpacing: -1,
                                color: c.ink,
                                height: 1,
                              ),
                            ),
                            const SizedBox(height: 28),
                            Text(
                              'Buy what fits.\nWait on what doesn\'t.',
                              style: excon(35, tracking: -.02, height: 1.24, color: c.ink),
                            ),
                            const SizedBox(height: 22),
                            ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 300),
                              child: Text(
                                'A wishlist that knows your budget. Needs come first, wants wait their turn, and groups keep track of who is putting in what.',
                                style: ranade(14, height: 1.7, color: c.ink3),
                              ),
                            ),
                          ],
                        ),
                      ),
                      _Step(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Eyebrow('1 of 2'),
                            const SizedBox(height: 14),
                            Text(
                              'What should we call you?',
                              style: excon(35, tracking: -.02, height: 1.24, color: c.ink),
                            ),
                            const SizedBox(height: 34),
                            BigField(
                              controller: _name,
                              focusNode: _nameFocus,
                              hint: 'Your name',
                              capitalization: TextCapitalization.words,
                              textInputAction: TextInputAction.next,
                              onSubmitted: (_) => _name.text.trim().isEmpty ? null : _go(2),
                            ),
                          ],
                        ),
                      ),
                      _Step(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Eyebrow('2 of 2'),
                            const SizedBox(height: 14),
                            Text(
                              'What can you spend each month?',
                              style: excon(35, tracking: -.02, height: 1.24, color: c.ink),
                            ),
                            const SizedBox(height: 34),
                            BigField(
                              controller: _budget,
                              focusNode: _budgetFocus,
                              numeric: true,
                              size: 48,
                              hint: '₹0',
                              trailing: _budget.amount != null && _budget.text != inr(_budget.amount!)
                                  ? Text(inr(_budget.amount!), style: excon(13, color: c.ink2))
                                  : null,
                              onSubmitted: (_) => _finish(),
                              help: const Text('After rent, bills and savings. Roughly is fine — change it any time.'),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                AnimatedPadding(
                  duration: const Duration(milliseconds: 120),
                  padding: EdgeInsets.fromLTRB(22, 8, 22, keyboard > 0 ? keyboard + 12 : bottom + 20),
                  child: PillButton(cta, onTap: onTap),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    physics: const ClampingScrollPhysics(),
    padding: const EdgeInsets.symmetric(horizontal: 30),
    child: ConstrainedBox(
      constraints: BoxConstraints(minHeight: MediaQuery.sizeOf(context).height * .55),
      child: child,
    ),
  );
}
