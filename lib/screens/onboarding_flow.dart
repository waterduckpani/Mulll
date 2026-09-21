/// Everything between opening Mull for the first time and using it.
///
/// One flow rather than a login wall followed by a setup wizard. Someone who
/// has just downloaded an app has no reason to hand over an email address yet:
/// they get told what this is first, and the address is asked for as the
/// second step of something they have already decided to do.
///
/// Welcome, email, code, name, UPI, then a way in.
///
/// The same flow is the way back for someone who has signed out. They have a
/// name already, so it opens on the email step and the root swaps it away the
/// moment the session comes back.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/links.dart';
import '../core/upi.dart';
import '../data/remote/auth_service.dart';
import '../data/remote/backend.dart';
import '../data/store.dart';
import '../ui/icons.dart';
import '../ui/page.dart';
import '../ui/tokens.dart';
import '../ui/widgets.dart';

enum _Step { welcome, email, code, name, upi, ready }

/// The steps that carry a number. Welcome and the last screen sit outside the
/// count: one is a statement, the other is already past the finish line.
const _counted = [_Step.email, _Step.code, _Step.name, _Step.upi];

/// How long to make someone wait before asking for another code. Long enough
/// that a slow inbox gets a chance, short enough not to feel punished.
const _resendCooldown = Duration(seconds: 30);

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

  final _emailFocus = FocusNode();
  final _codeFocus = FocusNode();
  final _nameFocus = FocusNode();
  final _upiFocus = FocusNode();

  late _Step _step;
  bool _busy = false;
  String? _error;

  /// Counts down after a code is sent, so "send another" is not an invitation
  /// to hammer the mailer.
  Timer? _resendTimer;
  int _resendIn = 0;

  /// Someone signing back in after a sign-out. They keep their name, so the
  /// flow is only the two sign-in steps and the root takes over after.
  late final bool _returning = context.readStore.profile.onboarded;

  /// A build with no Supabase keys has no account to make, so there is nothing
  /// to ask for an email address about. Without this the two sign-in steps are
  /// a door with no building behind it: "Mull is not connected to a server in
  /// this build" and no way past it, which is how local development and the
  /// screenshot tour both used to dead-end.
  bool get _localOnly => !BackendConfig.isConfigured;

  /// App Review's address: its code is a password from the review notes, not
  /// six digits from an email. See [AuthService.reviewEmail].
  bool get _review => AuthService.isReview(_email.text);

  @override
  void initState() {
    super.initState();
    _step = _returning ? (_localOnly ? _Step.name : _Step.email) : _Step.welcome;
    for (final c in [_email, _code, _name, _upi]) {
      c.addListener(() => setState(() {}));
    }
    // Six digits means the answer is complete. Making someone reach for a
    // button after that is a step with nothing in it.
    _code.addListener(_autoVerify);
  }

  @override
  void dispose() {
    _resendTimer?.cancel();
    for (final c in [_email, _code, _name, _upi]) {
      c.dispose();
    }
    for (final f in [_emailFocus, _codeFocus, _nameFocus, _upiFocus]) {
      f.dispose();
    }
    super.dispose();
  }

  void _autoVerify() {
    if (_step != _Step.code || _busy || _review) return;
    if (_code.text.replaceAll(RegExp(r'\D'), '').length == 6) _verify();
  }

  void _goTo(_Step step, {FocusNode? focus}) {
    HapticFeedback.lightImpact();
    setState(() {
      _step = step;
      _error = null;
    });
    if (focus == null) {
      FocusScope.of(context).unfocus();
      return;
    }
    // After the switch animation, or the field takes focus while off-screen and
    // the keyboard arrives before the text it belongs to.
    Future.delayed(const Duration(milliseconds: 340), () {
      if (mounted && _step == step) focus.requestFocus();
    });
  }

  void _startCooldown() {
    _resendTimer?.cancel();
    setState(() => _resendIn = _resendCooldown.inSeconds);
    _resendTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return t.cancel();
      setState(() => _resendIn--);
      if (_resendIn <= 0) t.cancel();
    });
  }

  Future<void> _sendCode({bool resend = false}) async {
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
    if (!result.isOk) return;
    if (!_review) _startCooldown();
    if (resend) {
      HapticFeedback.lightImpact();
      _code.clear();
    } else {
      _goTo(_Step.code, focus: _codeFocus);
    }
  }

  Future<void> _verify() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final result = await AuthService.verify(email: _email.text, code: _code.text);
    if (!mounted) return;
    if (!result.isOk) {
      HapticFeedback.heavyImpact();
      setState(() {
        _busy = false;
        _error = result.error;
        _code.clear();
      });
      _codeFocus.requestFocus();
      return;
    }
    HapticFeedback.mediumImpact();
    // This install already knew them, so the root replaces the whole flow with
    // the app the moment the session lands. Nothing more to do here.
    if (_returning) {
      setState(() => _busy = false);
      return;
    }

    // This install did not — but the account might have. A reinstall, a second
    // phone or a "start over" all arrive here looking exactly like a new
    // signup, and the only thing that can tell the difference is the profile
    // row. Stay busy across the round trip: a button that flicks back to
    // "Continue" and then vanishes reads as a glitch.
    final account = await AuthService.fetchProfile();
    if (!mounted) return;
    if (account != null && account.name.trim().isNotEmpty) {
      context.readStore.adoptAccount(name: account.name, upiId: account.upiId);
      return; // the root takes over; leaving _busy set keeps the button steady
    }

    setState(() => _busy = false);
    _goTo(_Step.name, focus: _nameFocus);
  }

  /// Name and UPI are saved together at the end rather than one screen at a
  /// time: a half-finished profile that stops existing when the app is killed
  /// is worse than no profile at all.
  ///
  /// What it deliberately does *not* do is mark onboarding finished. The root
  /// swaps this whole flow for the app the moment that flag flips, so setting
  /// it here made the last screen unreachable: it was built, and replaced in
  /// the same frame. [_done] is what ends the flow.
  void _finish() {
    final store = context.readStore;
    final upi = _upi.text.trim();
    final name = _name.text.trim();
    store.updateProfile((p) {
      p.name = name;
      if (upi.isNotEmpty) p.upiId = upi;
    });
    unawaited(AuthService.saveProfile(name: name, upiId: upi));
    HapticFeedback.heavyImpact();
    _goTo(_Step.ready);
  }

  Future<void> _inviteFriends() async {
    HapticFeedback.lightImpact();
    final name = _name.text.trim();
    await shareOnWhatsApp(
      '${name.isEmpty ? 'I' : name} started using Mull to keep track of who paid '
      'for what. Get it and we can split things properly: https://mull.oblunestudio.com',
    );
  }

  /// Leaves onboarding for good. Flipping `onboarded` is what the root is
  /// watching, so this is the line that hands over to the app.
  void _done() {
    HapticFeedback.mediumImpact();
    context.readStore.completeOnboarding(name: _name.text);
  }

  // ------------------------------------------------------------------ steps

  /// The steps this run will actually show, so "2 of 4" is not a lie in a
  /// build that skips the first two.
  List<_Step> get _numbered => _localOnly ? const [_Step.name, _Step.upi] : _counted;

  ({String? eyebrow, String title, String body}) get _copy {
    final steps = _numbered;
    final n = steps.indexOf(_step) + 1;
    final of = steps.length;
    return switch (_step) {
      _Step.welcome => (eyebrow: null, title: '', body: ''),
      _Step.email => (
        eyebrow: '$n of $of',
        title: _returning ? 'Welcome back.' : "What's your email?",
        body: _returning
            ? 'Same address as before. We will send a six-digit code, so there '
                  'is still no password to remember.'
            : 'We send a six-digit code, so there is no password to remember. '
                  'This is also the address friends use to add you to a group. '
                  'Continuing means you agree to the terms and privacy policy.',
      ),
      _Step.code when _review => (
        eyebrow: '$n of $of',
        title: 'Enter the review code.',
        body: 'This address is for App Review. The code is in the review notes.',
      ),
      _Step.code => (
        eyebrow: '$n of $of',
        title: 'Check your email.',
        body:
            'A six-digit code is on its way to ${_email.text.trim()}. '
            'It can take a few seconds.',
      ),
      _Step.name => (
        eyebrow: '$n of $of',
        title: 'What should we call you?',
        body: 'This is the name people see next to your share of a bill.',
      ),
      _Step.upi => (
        eyebrow: '$n of $of',
        title: 'Your UPI ID?',
        body:
            'So people can pay you back in one tap instead of asking for it '
            'every time. Skip it if you do not know it offhand.',
      ),
      _Step.ready => (
        eyebrow: "You're in",
        title: 'Better with people in it.',
        body:
            'Mull works best when the people you actually split with are on '
            'it too. Invite a couple now, or get on with it and do this later.',
      ),
    };
  }

  Widget? get _field => switch (_step) {
    _Step.email => BigField(
      controller: _email,
      focusNode: _emailFocus,
      size: 24,
      hint: 'you@email.com',
      keyboardType: TextInputType.emailAddress,
      textInputAction: TextInputAction.go,
      onSubmitted: (_) => _canAdvance && !_busy ? _sendCode() : null,
    ),
    _Step.code => BigField(
      controller: _code,
      focusNode: _codeFocus,
      numeric: !_review,
      size: _review ? 24 : 34,
      hint: _review ? 'Review code' : '000000',
      onSubmitted: (_) => _canAdvance && !_busy ? _verify() : null,
    ),
    _Step.name => BigField(
      controller: _name,
      focusNode: _nameFocus,
      hint: 'Your name',
      size: 28,
      capitalization: TextCapitalization.words,
      textInputAction: TextInputAction.next,
      onSubmitted: (_) => _canAdvance ? _goTo(_Step.upi, focus: _upiFocus) : null,
    ),
    _Step.upi => BigField(
      controller: _upi,
      focusNode: _upiFocus,
      size: 24,
      hint: 'name@bank',
      textInputAction: TextInputAction.done,
      help: _upiLooksRight ? null : const Text("That doesn't look like a UPI ID. They usually read name@bank."),
      onSubmitted: (_) => _upiLooksRight ? _finish() : null,
    ),
    _ => null,
  };

  bool get _canAdvance => switch (_step) {
    _Step.welcome || _Step.ready => true,
    _Step.email => _email.text.trim().isNotEmpty,
    _Step.code => _review ? _code.text.trim().length >= 8 : _code.text.replaceAll(RegExp(r'\D'), '').length >= 6,
    _Step.name => _name.text.trim().isNotEmpty,
    // Deliberately skippable: a UPI ID is not something everyone has to hand,
    // and blocking setup on it would lose people over a string they can paste
    // in thirty seconds from the profile screen.
    // Skippable, but not wrong: people pay you at whatever is typed here, and
    // a handle with a typo either fails in their UPI app or pays a stranger.
    _Step.upi => _upiLooksRight,
  };

  bool get _upiLooksRight {
    final typed = _upi.text.trim();
    return typed.isEmpty || isUpiId(typed);
  }

  (String, VoidCallback?) get _cta => switch (_step) {
    _Step.welcome => (
      'Get started',
      () => _localOnly
          ? _goTo(_Step.name, focus: _nameFocus)
          : _goTo(_Step.email, focus: _emailFocus),
    ),
    _Step.email => (_busy ? 'Sending' : 'Send me a code', _busy ? null : _sendCode),
    _Step.code => (_busy ? 'Checking' : 'Continue', _busy ? null : _verify),
    _Step.name => ('Continue', () => _goTo(_Step.upi, focus: _upiFocus)),
    _Step.upi => (_upi.text.trim().isEmpty ? 'Skip for now' : 'Continue', _finish),
    _Step.ready => ('Invite friends', _inviteFriends),
  };

  /// Back is only offered where going back is harmless. Once the code has been
  /// accepted there is a session, and stepping back into "enter your email"
  /// would be a door that no longer leads anywhere.
  VoidCallback? get _back => switch (_step) {
    _Step.email => _returning ? null : () => _goTo(_Step.welcome),
    _Step.name => _localOnly && !_returning ? () => _goTo(_Step.welcome) : null,
    _Step.code => () => _goTo(_Step.email, focus: _emailFocus),
    _Step.upi => () => _goTo(_Step.name, focus: _nameFocus),
    _ => null,
  };

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    final copy = _copy;
    final (label, action) = _cta;
    final onWelcome = _step == _Step.welcome;
    final busy = _busy;

    final body = onWelcome
        ? _Welcome(
            key: const ValueKey('welcome'),
            onSignIn: _localOnly ? null : () => _goTo(_Step.email, focus: _emailFocus),
          )
        : Column(
            key: ValueKey(_step),
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // The step count lives in the top bar, the way it does in the
              // create flow. Only the last screen, which is not a step, keeps
              // an eyebrow of its own.
              if (_step == _Step.ready) ...[
                Eyebrow(copy.eyebrow!, size: 11, tracking: .18),
                const SizedBox(height: 16),
              ],
              Text(copy.title, style: MullType.statement(c.ink, size: 36)),
              const SizedBox(height: 16),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 330),
                child: Text(copy.body, style: MullType.body(c.ink3)),
              ),
              if (_field != null) ...[const SizedBox(height: 34), _field!],
              if (_error != null) ...[
                const SizedBox(height: 18),
                _ErrorNote(_error!),
              ],
              // The notice the law asks for, where the account is made.
              if (_step == _Step.email && !_returning) ...[
                const SizedBox(height: 20),
                Row(
                  children: [
                    _TextLink('Privacy', onTap: () => MullLinks.open(MullLinks.privacy)),
                    const SizedBox(width: 20),
                    _TextLink('Terms', onTap: () => MullLinks.open(MullLinks.terms)),
                  ],
                ),
              ],
              if (_step == _Step.code) ...[
                const SizedBox(height: 20),
                Row(
                  children: [
                    if (!_review) ...[
                      _TextLink(
                        _resendIn > 0 ? 'Send another in ${_resendIn}s' : 'Send another code',
                        onTap: _resendIn > 0 || busy ? null : () => _sendCode(resend: true),
                      ),
                      const SizedBox(width: 20),
                    ],
                    _TextLink(
                      'Use a different email',
                      onTap: busy ? null : () => _goTo(_Step.email, focus: _emailFocus),
                    ),
                  ],
                ),
              ],
              if (_step == _Step.upi) ...[
                const SizedBox(height: 20),
                Text(
                  'It looks like yourname@okhdfcbank. Your UPI app has it under '
                  'your profile.',
                  style: MullType.caption(c.ink3),
                ),
              ],
            ],
          );

    return Scaffold(
      backgroundColor: c.screen,
      resizeToAvoidBottomInset: false,
      body: Stack(
        children: [
          Positioned.fill(
            child: Backdrop(
              glow: GlowSpec(
                size: 460,
                top: -170,
                left: onWelcome ? -150 : null,
                right: onWelcome ? null : -150,
              ),
            ),
          ),
          SafeArea(
            bottom: false,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _TopBar(step: _step, steps: _numbered, onBack: _back),
                Expanded(
                  child: SingleChildScrollView(
                    physics: const BouncingScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(Gutter.text, 0, Gutter.text, 24),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        minHeight: MediaQuery.sizeOf(context).height * .52,
                      ),
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 320),
                        child: body,
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: EdgeInsets.fromLTRB(
                    Gutter.card,
                    8,
                    Gutter.card,
                    keyboard > 0 ? keyboard + 12 : 30,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (keyboard == 0 && !onWelcome && _step != _Step.ready)
                        const Padding(
                          padding: EdgeInsets.only(bottom: 14),
                          child: Footnote('No money ever moves through Mull.'),
                        ),
                      PillButton(label, busy: busy, onTap: _canAdvance ? action : null),
                      if (_step == _Step.ready) ...[
                        const SizedBox(height: 8),
                        SecondaryButton('Take me in', onTap: _done),
                      ],
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
}

/// Wordmark or back button on the left, progress on the right.
class _TopBar extends StatelessWidget {
  const _TopBar({required this.step, required this.steps, required this.onBack});

  final _Step step;
  final List<_Step> steps;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final index = steps.indexOf(step);
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gutter.card, 14, Gutter.card, 0),
      child: SizedBox(
        height: 44,
        child: Row(
          children: [
            if (onBack != null)
              BackButtonCircle(onTap: onBack)
            // The welcome screen sets the wordmark at 60px in the middle of
            // the page. A second one up here reads as a rendering bug.
            else if (step != _Step.welcome)
              Padding(
                padding: const EdgeInsets.only(left: 10),
                child: Text('mull', style: chillax(20, color: c.ink)),
              ),
            const Spacer(),
            if (index >= 0)
              Padding(
                padding: const EdgeInsets.only(right: 10),
                child: Eyebrow('${index + 1} of ${steps.length}', size: 11.5, tracking: .16),
              ),
          ],
        ),
      ),
    );
  }
}

/// The first thing anyone sees.
///
/// Three lines about what Mull does, then three short facts about how, then a
/// way in. Not a carousel: nobody has ever finished one.
class _Welcome extends StatefulWidget {
  const _Welcome({super.key, this.onSignIn});

  /// Null in a build with no server: there is no account to come back to.
  final VoidCallback? onSignIn;

  @override
  State<_Welcome> createState() => _WelcomeState();
}

class _WelcomeState extends State<_Welcome> {
  bool _in = false;

  @override
  void initState() {
    super.initState();
    Future.delayed(const Duration(milliseconds: 120), () {
      if (mounted) setState(() => _in = true);
    });
  }

  Widget _rise(int step, Widget child) {
    final d = motion(context, const Duration(milliseconds: 620));
    return AnimatedSlide(
      offset: _in ? Offset.zero : const Offset(0, .08),
      duration: d * (1 + step * .12),
      curve: Curves.easeOutCubic,
      child: AnimatedOpacity(
        opacity: _in ? 1 : 0,
        duration: d * (1 + step * .18),
        child: child,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;

    Widget point(String title, String body) => Padding(
      padding: const EdgeInsets.only(top: 18),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 5),
            child: MullIcon(MullGlyph.check, size: 13, color: c.ink2, strokeWidth: 2.2),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: ranade(15, color: c.ink)),
                const SizedBox(height: 3),
                Text(body, style: MullType.caption(c.ink3)),
              ],
            ),
          ),
        ],
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _rise(0, Text('mull', style: chillax(60, color: c.ink))),
        const SizedBox(height: 26),
        _rise(
          1,
          Text('Who paid.\nWho owes.\nSorted.', style: MullType.statement(c.ink, size: 38)),
        ),
        const SizedBox(height: 10),
        _rise(
          2,
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              point(
                'The fewest payments',
                'Eleven expenses between four people usually come down to two transfers.',
              ),
              point(
                'Nobody marks their own homework',
                'The payer says they sent it, the person owed confirms it landed.',
              ),
              point('Your money, your UPI', 'Payments go between you. Mull never touches them.'),
            ],
          ),
        ),
        const SizedBox(height: 30),
        if (widget.onSignIn != null)
          _rise(
            3,
            Pressable(
              onTap: widget.onSignIn,
              child: Row(
                children: [
                  Text('Already use Mull?', style: MullType.caption(c.ink3, size: 13)),
                  const SizedBox(width: 8),
                  Text(
                    'Sign in',
                    style: ranade(13, color: c.ink, decoration: TextDecoration.underline),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// Something went wrong, said once, where the eye already is.
class _ErrorNote extends StatelessWidget {
  const _ErrorNote(this.message);

  final String message;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 16),
      decoration: surfaceOf(c, Lift.flat, radius: BorderRadius.circular(20)),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 3),
            child: MullIcon(MullGlyph.close, size: 13, color: c.ink2, strokeWidth: 2),
          ),
          const SizedBox(width: 12),
          Expanded(child: Text(message, style: MullType.body(c.ink))),
        ],
      ),
    );
  }
}

class _TextLink extends StatelessWidget {
  const _TextLink(this.label, {this.onTap});

  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Pressable(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Text(
          label,
          style: ranade(
            13,
            color: onTap == null ? c.ink3 : c.ink2,
            decoration: onTap == null ? null : TextDecoration.underline,
          ),
        ),
      ),
    );
  }
}
