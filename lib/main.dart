import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show AuthState;

import 'data/remote/backend.dart';
import 'data/remote/groups_sync.dart';
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
  final sync = GroupsSync(store)
    ..attachTo(store)
    ..start();

  runApp(MullApp(store: store, sync: sync));
}

class MullApp extends StatelessWidget {
  const MullApp({super.key, required this.store, this.sync});

  final MullStore store;
  final GroupsSync? sync;

  @override
  Widget build(BuildContext context) {
    return StoreScope(
      store: store,
      child: ListenableBuilder(
        listenable: store,
        builder: (context, _) => MaterialApp(
          title: 'Mull',
          debugShowCheckedModeBanner: false,
          themeMode: store.profile.theme,
          theme: buildTheme(MullColors.light),
          darkTheme: buildTheme(MullColors.dark),
          builder: (context, child) {
            final mq = MediaQuery.of(context);
            final dark = Theme.of(context).brightness == Brightness.dark;
            return AnnotatedRegion<SystemUiOverlayStyle>(
              value: dark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
              child: MediaQuery(
                // Respect Dynamic Type, within what the layout can hold.
                data: mq.copyWith(textScaler: mq.textScaler.clamp(minScaleFactor: .9, maxScaleFactor: 1.25)),
                child: child!,
              ),
            );
          },
          home: const _Root(),
        ),
      ),
    );
  }
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
      });
    }
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
