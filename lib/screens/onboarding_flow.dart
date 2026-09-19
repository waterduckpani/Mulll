/// Everything between opening Mull for the first time and using it.
///
/// One flow rather than a login wall followed by a setup wizard. Someone who
/// has just downloaded an app has no reason to hand over an email address yet —
/// they get told what this is first, and the address is asked for as the second
/// step of something they have already decided to do.
///
/// Welcome → email → code → name → UPI → budget → friends.
///
/// The flow is also the way back in for someone who has signed out: they have
/// a name and a budget already, so it starts at the email step and the root
/// swaps it away the moment the session comes back.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/upi.dart';
import '../data/remote/auth_service.dart';
import '../data/store.dart';
import '../ui/tokens.dart';
import '../ui/widgets.dart';

enum _Step { welcome, email, code, name, upi, budget, friends }

class OnboardingFlow extends StatefulWidget {
  const OnboardingFlow({super.key});

  @override
  State<OnboardingFlow> createState() => _OnboardingFlowState();
}

class _OnboardingFlowState extends State<OnboardingFlow> {
  final _email = TextEditingController();
  final _code = TextEditingController();
  final _name = TextEditingController();
  final _upi = TextEditingController();
  final _budget = AmountController();

  final _emailFocus = FocusNode();
  final _codeFocus = FocusNode();
  final _nameFocus = FocusNode();
  final _upiFocus = FocusNode();
  final _budgetFocus = FocusNode();

  late _Step _step;
  bool _busy = false;
  String? _error;

  /// Someone signing back in after a sign-out. They keep their name and budget,
  /// so the flow is only the two sign-in steps and the root takes over after.
  late final bool _returning = context.readStore.profile.onboarded;

  @override
  void initState() {
    super.initState();
    _step = _returning ? _Step.email : _Step.welcome;
    for (final c in [_email, _code, _name, _upi, _budget]) {
      c.addListener(() => setState(() {}));
    }
    _budgetFocus.addListener(() {
      if (!_budgetFocus.hasFocus) _budget.tidy();
    });
  }

  @override
  void dispose() {
    for (final c in [_email, _code, _name, _upi, _budget]) {
      c.dispose();
    }
    for (final f in [_emailFocus, _codeFocus, _nameFocus, _upiFocus, _budgetFocus]) {
      f.dispose();
    }
    super.dispose();
  }

  void _goTo(_Step step, {FocusNode? focus}) {
    HapticFeedback.lightImpact();
    setState(() {
      _step = step;
      _error = null;
    });
    if (focus == null) return;
    // After the switch animation, or the field takes focus while off-screen and
    // the keyboard arrives before the text it belongs to.
    Future.delayed(const Duration(milliseconds: 360), () {
      if (mounted && _step == step) focus.requestFocus();
    });
  }

  Future<void> _sendCode() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final result = await AuthService.sendCode(_email.text);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = result.error;
    });
    if (result.isOk) _goTo(_Step.code, focus: _codeFocus);
  }

  Future<void> _verify() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final result = await AuthService.verify(email: _email.text, code: _code.text);
    if (!mounted) return;
    if (!result.isOk) {
      setState(() {
        _busy = false;
        _error = result.error;
        _code.clear();
      });
      return;
    }
    setState(() => _busy = false);
    HapticFeedback.mediumImpact();
    // A returning user is already onboarded, so the root replaces this whole
    // flow with the app as soon as the session lands. Nothing more to do here.
    if (!_returning) _goTo(_Step.name, focus: _nameFocus);
  }

  /// Name, UPI and budget are saved together at the end rather than one screen
  /// at a time: a half-finished profile that stops existing when the app is
  /// killed is worse than no profile at all.
  void _finish() {
    final budget = _budget.amount;
    if (budget == null) return;
    final store = context.readStore;
    final upi = _upi.text.trim();
    store.completeOnboarding(name: _name.text, budget: budget);
    if (upi.isNotEmpty) store.updateProfile((p) => p.upiId = upi);
    unawaited(AuthService.saveProfile(name: _name.text, upiId: upi));
    HapticFeedback.heavyImpact();
    _goTo(_Step.friends);
  }

  Future<void> _inviteFriends() async {
    HapticFeedback.lightImpact();
    final name = _name.text.trim();
    await shareOnWhatsApp(
      '${name.isEmpty ? 'I' : name} started using Mull to keep track of who paid '
      'for what. Get it and we can split things properly: https://mull.oblunestudio.com',
    );
  }

  /// Leaves onboarding. `onboarded` is already true by this point, so the root
  /// shows the app.
  void _done() {
    HapticFeedback.mediumImpact();
    context.readStore.updateProfile((_) {});
  }

  // ------------------------------------------------------------------ steps

  ({String? eyebrow, String title, String body}) get _copy => switch (_step) {
    _Step.welcome => (eyebrow: null, title: '', body: ''),
    _Step.email => (
      eyebrow: 'Step 1 of 5',
      title: 'Where should we reach you?',
      body:
          'We\'ll email you a six-digit code. There is no password to remember, '
          'and this is the address friends use to add you to a group.',
    ),
    _Step.code => (
      eyebrow: 'Step 2 of 5',
      title: 'Check your email.',
      body: 'We sent a six-digit code to ${_email.text.trim()}.',
    ),
    _Step.name => (
      eyebrow: 'Step 3 of 5',
      title: 'What should we call you?',
      body: 'This is the name people see next to your share of a bill.',
    ),
    _Step.upi => (
      eyebrow: 'Step 4 of 5',
      title: 'Your UPI ID?',
      body:
          'So people can pay you back in one tap instead of asking for it every '
          'time. You can add it later if you don\'t know it offhand.',
    ),
    _Step.budget => (
      eyebrow: 'Step 5 of 5',
      title: 'What can you put towards things each month?',
      body:
          'Mull measures everything you want against this. You can change it '
          'whenever it changes.',
    ),
    _Step.friends => (
      eyebrow: 'You\'re set',
      title: 'Better with people in it.',
      body:
          'Mull is most useful when the people you actually split with are on '
          'it too. Invite a couple now, or get on with it and do this later.',
    ),
  };

  Widget? get _field => switch (_step) {
    _Step.email => BigField(
      controller: _email,
      focusNode: _emailFocus,
      size: 22,
      hint: 'you@email.com',
      keyboardType: TextInputType.emailAddress,
      onSubmitted: (_) => _canAdvance ? _sendCode() : null,
    ),
    _Step.code => BigField(
      controller: _code,
      focusNode: _codeFocus,
      numeric: true,
      hint: '000000',
      onSubmitted: (_) => _canAdvance ? _verify() : null,
    ),
    _Step.name => BigField(
      controller: _name,
      focusNode: _nameFocus,
      hint: 'Your name',
      capitalization: TextCapitalization.words,
      textInputAction: TextInputAction.next,
      onSubmitted: (_) => _canAdvance ? _goTo(_Step.upi, focus: _upiFocus) : null,
    ),
    _Step.upi => BigField(
      controller: _upi,
      focusNode: _upiFocus,
      size: 22,
      hint: 'name@bank',
      onSubmitted: (_) => _goTo(_Step.budget, focus: _budgetFocus),
    ),
    _Step.budget => BigField(
      controller: _budget,
      focusNode: _budgetFocus,
      numeric: true,
      hint: '₹0',
      onSubmitted: (_) => _canAdvance ? _finish() : null,
    ),
    _ => null,
  };

  bool get _canAdvance => switch (_step) {
    _Step.welcome || _Step.friends => true,
    _Step.email => _email.text.trim().isNotEmpty,
    _Step.code => _code.text.trim().length >= 6,
    _Step.name => _name.text.trim().isNotEmpty,
    // Deliberately skippable: a UPI ID is not something everyone has to hand,
    // and blocking setup on it would lose people over a string they can paste
    // in thirty seconds from the profile screen.
    _Step.upi => true,
    _Step.budget => _budget.amount != null,
  };

  (String, VoidCallback?) get _cta => switch (_step) {
    _Step.welcome => ('Get started', () => _goTo(_Step.email, focus: _emailFocus)),
    _Step.email => (_busy ? 'Sending…' : 'Send me a code', _busy ? null : _sendCode),
    _Step.code => (_busy ? 'One moment…' : 'Continue', _busy ? null : _verify),
    _Step.name => ('Continue', () => _goTo(_Step.upi, focus: _upiFocus)),
    _Step.upi => (
      _upi.text.trim().isEmpty ? 'Skip for now' : 'Continue',
      () => _goTo(_Step.budget, focus: _budgetFocus),
    ),
    _Step.budget => ('Continue', _finish),
    _Step.friends => ('Invite friends', _inviteFriends),
  };

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    final copy = _copy;
    final (label, action) = _cta;
    final onWelcome = _step == _Step.welcome;

    // The welcome screen is the only one that is a statement rather than a
    // question, so it gets the whole canvas and no progress dots.
    final body = onWelcome
        ? _Welcome(key: const ValueKey('welcome'))
        : Column(
            key: ValueKey(_step),
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (copy.eyebrow != null) ...[
                Eyebrow(copy.eyebrow!),
                const SizedBox(height: 14),
              ],
              Text(copy.title, style: excon(35, tracking: -.02, height: 1.24, color: c.ink)),
              const SizedBox(height: 16),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 330),
                child: Text(copy.body, style: ranade(14, height: 1.7, color: c.ink3)),
              ),
              if (_field != null) ...[const SizedBox(height: 32), _field!],
              if (_error != null) ...[
                const SizedBox(height: 16),
                Text(_error!, style: ranade(13, height: 1.5, color: c.ink)),
              ],
              if (_step == _Step.code) ...[
                const SizedBox(height: 18),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Pressable(
                    onTap: _busy ? null : _sendCode,
                    child: Text(
                      'Send another code',
                      style: ranade(13, color: c.ink3, decoration: TextDecoration.underline),
                    ),
                  ),
                ),
              ],
            ],
          );

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
                _TopBar(step: _step, onBack: _back),
                Expanded(
                  child: SingleChildScrollView(
                    physics: const BouncingScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(minHeight: MediaQuery.sizeOf(context).height * .52),
                      child: AnimatedSwitcher(duration: const Duration(milliseconds: 320), child: body),
                    ),
                  ),
                ),
                Padding(
                  padding: EdgeInsets.fromLTRB(24, 8, 24, keyboard > 0 ? keyboard + 12 : 30),
                  child: Column(
                    children: [
                      PillButton(label, onTap: _canAdvance ? action : null),
                      if (_step == _Step.friends) ...[
                        const SizedBox(height: 8),
                        GhostButton('Maybe later', onTap: _done),
                      ] else if (keyboard == 0 && !onWelcome)
                        Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: Text(
                            'No money ever moves through Mull.',
                            style: ranade(11.5, color: c.ink3),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Back is only offered where going back is harmless. Once the code has been
  /// accepted there is a session, and stepping back into "enter your email"
  /// would be a door that no longer leads anywhere.
  VoidCallback? get _back => switch (_step) {
    _Step.email => _returning ? null : () => _goTo(_Step.welcome),
    _Step.code => () => _goTo(_Step.email, focus: _emailFocus),
    _Step.upi => () => _goTo(_Step.name, focus: _nameFocus),
    _Step.budget => () => _goTo(_Step.upi, focus: _upiFocus),
    _ => null,
  };
}

class _TopBar extends StatelessWidget {
  const _TopBar({required this.step, required this.onBack});

  final _Step step;
  final VoidCallback? onBack;

  /// Which of the five numbered steps this is, or null on welcome and the
  /// friends screen, which sit outside the count.
  int? get _index => switch (step) {
    _Step.email => 0,
    _Step.code => 1,
    _Step.name => 2,
    _Step.upi => 3,
    _Step.budget => 4,
    _ => null,
  };

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final index = _index;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
      child: SizedBox(
        height: 44,
        child: Row(
          children: [
            if (onBack != null)
              Pressable(
                onTap: onBack,
                child: Text(
                  'Back',
                  style: ranade(13, color: c.ink3, decoration: TextDecoration.underline),
                ),
              )
            else
              Text(
                'mull',
                style: TextStyle(
                  fontFamily: 'Chillax',
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                  color: c.ink,
                ),
              ),
            const Spacer(),
            if (index != null)
              for (var i = 0; i < 5; i++)
                AnimatedContainer(
                  duration: const Duration(milliseconds: 300),
                  margin: const EdgeInsets.only(left: 6),
                  width: i == index ? 18 : 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: i == index ? c.ink : c.line,
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
          ],
        ),
      ),
    );
  }
}

class _Welcome extends StatelessWidget {
  const _Welcome({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Column(
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
            'A wishlist that knows your budget. Needs come first, wants wait '
            'their turn, and groups keep track of who is putting in what.',
            style: ranade(14, height: 1.7, color: c.ink3),
          ),
        ),
        const SizedBox(height: 26),
        Text(
          'Takes about a minute to set up.',
          style: ranade(12.5, color: c.ink3),
        ),
      ],
    );
  }
}
