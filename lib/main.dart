import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show AuthState;

import 'data/remote/auth_service.dart';
import 'data/remote/backend.dart';
import 'data/remote/error_reporter.dart';
import 'data/remote/groups_sync.dart';
import 'data/remote/live_channel.dart';
import 'data/remote/push_service.dart';
import 'data/notices.dart';
import 'data/store.dart';
import 'screens/onboarding_flow.dart';
import 'screens/app_shell.dart';
import 'screens/not_configured_screen.dart';
import 'ui/tokens.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);

  // The local store opens first and never waits on the network. A build with
  // no project wired up, or a phone with no signal, is a working Mull.
  final store = await MullStore.load();
  // `flutter run --dart-define=MULL_SAMPLE=true` starts with the mockup data.
  if (const bool.fromEnvironment('MULL_SAMPLE') && store.groups.isEmpty) store.loadSample();

  await Backend.init();
  ErrorReporter.install();
  LiveChannel.instance.start();
  PushService.start();
  final sync = GroupsSync(store)
    ..attachTo(store)
    ..start();
  final notices = NoticesInbox()
    ..attachTo(store)
    ..start();

  runApp(MullApp(store: store, sync: sync, notices: notices));
}

class MullApp extends StatelessWidget {
  const MullApp({super.key, required this.store, this.sync, this.notices});

  final MullStore store;
  final GroupsSync? sync;
  final NoticesInbox? notices;

  @override
  Widget build(BuildContext context) {
    final app = StoreScope(
      store: store,
      child: _ThemeFollower(
        store: store,
        builder: (context, mode) => MaterialApp(
          title: 'Mull',
          debugShowCheckedModeBanner: false,
          themeMode: mode,
          theme: _lightTheme,
          darkTheme: _darkTheme,
          builder: (context, child) {
            final mq = MediaQuery.of(context);
            final dark = Theme.of(context).brightness == Brightness.dark;
            return AnnotatedRegion<SystemUiOverlayStyle>(
              value: dark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
              child: MediaQuery(
                // Respect Dynamic Type, within what the layout can hold. The
                // ceiling was 1.25, which quietly ignored the larger text sizes
                // the people who most need them turn on.
                data: mq.copyWith(textScaler: mq.textScaler.clamp(minScaleFactor: .9, maxScaleFactor: 1.5)),
                child: child!,
              ),
            );
          },
          home: const _Root(),
        ),
      ),
    );

    // Outside StoreScope rather than inside it: the inbox has to survive the
    // theme rebuilding, and nothing in it depends on the ledger.
    final inbox = notices;
    return inbox == null ? app : NoticesScope(inbox: inbox, child: app);
  }
}

/// Built once. They are the same every time, and building them — twice, on
/// every change to the ledger — was the costliest thing a small edit did.
final _lightTheme = buildTheme(MullColors.light);
final _darkTheme = buildTheme(MullColors.dark);

/// Rebuilds the app around it when the theme setting changes, and only then.
///
/// It used to rebuild on every change to the store, which is every edit and
/// every row a sync acknowledges. Everything below that needs the ledger
/// listens to it through [StoreScope] already.
class _ThemeFollower extends StatefulWidget {
  const _ThemeFollower({required this.store, required this.builder});

  final MullStore store;
  final Widget Function(BuildContext context, ThemeMode mode) builder;

  @override
  State<_ThemeFollower> createState() => _ThemeFollowerState();
}

class _ThemeFollowerState extends State<_ThemeFollower> {
  late ThemeMode _mode = widget.store.profile.theme;

  @override
  void initState() {
    super.initState();
    widget.store.addListener(_follow);
  }

  @override
  void didUpdateWidget(_ThemeFollower old) {
    super.didUpdateWidget(old);
    if (old.store != widget.store) {
      old.store.removeListener(_follow);
      widget.store.addListener(_follow);
      _follow();
    }
  }

  void _follow() {
    final mode = widget.store.profile.theme;
    if (mode != _mode) setState(() => _mode = mode);
  }

  @override
  void dispose() {
    widget.store.removeListener(_follow);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _mode);
}

/// Sign in, then onboarding, then the app.
///
/// The gate is deliberate: groups are the point of Mull and they need an
/// account, so an install that has never signed in has nothing to show that is
/// worth showing. Once there *is* a session it is restored from disk at launch,
/// so a phone with no signal opens straight into the app — the gate only stops
/// someone who has never connected at all.
class _Root extends StatefulWidget {
  const _Root();

  @override
  State<_Root> createState() => _RootState();
}

class _RootState extends State<_Root> {
  StreamSubscription<AuthState>? _auth;

  /// Only ever true in a build with no Supabase keys, where there is no door to
  /// stand at. Not a way past the gate in a real build.
  bool _skippedGate = false;

  @override
  void initState() {
    super.initState();
    if (Backend.isAvailable) {
      // Sign-in and sign-out both land here, which is what lets the sign-in
      // screen finish without navigating and the profile sheet sign you out
      // straight back to the door.
      _auth = Backend.client.auth.onAuthStateChange.listen((_) {
        if (mounted) setState(() {});
        unawaited(_adoptAccount());
      });
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_adoptAccount()));
  }

  /// Finishes onboarding for someone the account already knows.
  ///
  /// The gate asks two questions — is there a session, and has this install
  /// been set up — and only the first of them is about the person. A restored
  /// session sitting next to an empty `mull.json` is a real state: a reinstall
  /// keeps the keychain, and "start over" clears the file but not the session.
  /// Without this, both of those open on "what should we call you?" for
  /// somebody who answered that months ago.
  Future<void> _adoptAccount() async {
    if (!mounted || !Backend.isSignedIn) return;
    final store = StoreScope.read(context);
    if (store.profile.onboarded) return;
    final account = await AuthService.fetchProfile();
    if (!mounted || account == null || account.name.trim().isEmpty) return;
    store.adoptAccount(name: account.name, upiId: account.upiId);
  }

  @override
  void dispose() {
    _auth?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Widget screen;
    if (!BackendConfig.isConfigured && !_skippedGate) {
      screen = NotConfiguredScreen(
        key: const ValueKey('unconfigured'),
        onContinue: () => setState(() => _skippedGate = true),
      );
    } else if ((BackendConfig.isConfigured && !Backend.isSignedIn) ||
        !context.store.profile.onboarded) {
      // One flow covers both, because they are one flow: welcome, sign in, then
      // the three things Mull needs to know about you. It works out for itself
      // where to start, so a sign-out drops a returning user at the code step
      // rather than back at "here is what Mull is".
      screen = const OnboardingFlow(key: ValueKey('onboarding'));
    } else {
      screen = const AppShell(key: ValueKey('shell'));
    }

    return AnimatedSwitcher(duration: const Duration(milliseconds: 500), child: screen);
  }
}
