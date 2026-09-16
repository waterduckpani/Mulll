import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'data/store.dart';
import 'screens/onboarding_screen.dart';
import 'screens/shell.dart';
import 'ui/tokens.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  final store = await MullStore.load();
  // `flutter run --dart-define=MULL_SAMPLE=true` starts with the mockup data.
  if (const bool.fromEnvironment('MULL_SAMPLE') && store.items.isEmpty) store.loadSample();
  runApp(MullApp(store: store));
}

class MullApp extends StatelessWidget {
  const MullApp({super.key, required this.store});

  final MullStore store;

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

class _Root extends StatelessWidget {
  const _Root();

  @override
  Widget build(BuildContext context) {
    final onboarded = context.store.profile.onboarded;
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 500),
      child: onboarded ? const Shell(key: ValueKey('shell')) : const OnboardingScreen(key: ValueKey('onboarding')),
    );
  }
}
