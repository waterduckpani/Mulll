/// A build with no Supabase keys compiled in.
///
/// Running with no server is a supported way to develop Mull and is how the
/// widget tests drive it, so this says so plainly and lets you through to a
/// local-only app rather than locking an empty door.
library;

import 'package:flutter/material.dart';

import '../ui/tokens.dart';
import '../ui/widgets.dart';

/// Shown instead of the gate in a build with no Supabase keys compiled in.
///
/// A build with no server is a supported way to run Mull — it is how the app
/// is developed and how the widget tests drive it — so it says so plainly and
/// lets you through to a local-only app rather than locking an empty door.
class NotConfiguredScreen extends StatelessWidget {
  const NotConfiguredScreen({super.key, required this.onContinue});

  final VoidCallback onContinue;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Scaffold(
      backgroundColor: c.screen,
      body: Stack(
        children: [
          const Positioned.fill(
            child: Backdrop(glow: GlowSpec(size: 440, top: -160, left: -150, right: null)),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(30, 24, 30, 30),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Eyebrow('Local build', size: 11, tracking: .18),
                  const SizedBox(height: 16),
                  Text('No server behind this build.', style: MullType.statement(c.ink, size: 34)),
                  const SizedBox(height: 16),
                  Text(
                    'Mull was built without Supabase keys, so there is nothing to '
                    'sign in to. Everything works on this phone, and groups will '
                    'not sync anywhere.',
                    style: MullType.body(c.ink3),
                  ),
                  const SizedBox(height: 34),
                  PillButton('Continue on this phone', onTap: onContinue),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
