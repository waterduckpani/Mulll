/// Mull's connection to Supabase.
///
/// Deliberately optional. The app is local-first and has to keep working with
/// no project configured, no network and no account — the wishlist, the budget
/// and the lists are private to one phone and never leave it. Only groups sync,
/// because only groups are other people.
library;

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Where the project lives. Passed at build time:
///
///   flutter run --dart-define=SUPABASE_URL=https://xxx.supabase.co \
///               --dart-define=SUPABASE_ANON_KEY=eyJhbGciOi...
///
/// The anon key is meant to ship in the client — row-level security is what
/// protects the data, not the secrecy of this string.
class BackendConfig {
  static const url = String.fromEnvironment('SUPABASE_URL');
  static const anonKey = String.fromEnvironment('SUPABASE_ANON_KEY');

  /// False in a build with no project wired up, which is a supported way to
  /// run Mull rather than an error.
  static bool get isConfigured => url.isNotEmpty && anonKey.isNotEmpty;
}

class Backend {
  static bool _ready = false;

  /// True once Supabase is initialised and usable.
  static bool get isAvailable => _ready;

  static SupabaseClient get client => Supabase.instance.client;

  static Session? get session => _ready ? client.auth.currentSession : null;
  static User? get user => _ready ? client.auth.currentUser : null;
  static bool get isSignedIn => session != null;

  /// Brings the connection up, or leaves the app local-only.
  ///
  /// Never throws: a backend that cannot be reached must not stop Mull from
  /// opening. Someone on a train with a dead connection still gets their
  /// wishlist.
  static Future<void> init() async {
    if (_ready || !BackendConfig.isConfigured) return;
    try {
      await Supabase.initialize(
        url: BackendConfig.url,
        // Supabase renamed this key; the dart-define keeps the older, more
        // widely documented name so the dashboard's own label still matches.
        publishableKey: BackendConfig.anonKey,
        authOptions: const FlutterAuthClientOptions(authFlowType: AuthFlowType.pkce),
      );
      _ready = true;
    } catch (e) {
      debugPrint('mull: backend unavailable, staying local ($e)');
    }
  }
}
