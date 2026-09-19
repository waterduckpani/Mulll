/// Signing in, by a six-digit code sent to an email address.
///
/// A code rather than a magic link: a link has to leave the app, come back
/// through a custom URL scheme and land on the right screen, and every step of
/// that is somewhere a login can get lost. A code is typed where you already
/// are. Supabase sends one as long as the confirmation template contains
/// `{{ .Token }}`.
library;

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'backend.dart';

enum AuthStep { enterEmail, enterCode, signedIn }

class AuthResult {
  const AuthResult.ok() : error = null;
  const AuthResult.failed(this.error);

  final String? error;
  bool get isOk => error == null;
}

class AuthService {
  /// Sends a fresh code. Also used to resend.
  static Future<AuthResult> sendCode(String email) async {
    final address = email.trim().toLowerCase();
    if (!_looksLikeEmail(address)) {
      return const AuthResult.failed("That doesn't look like an email address.");
    }
    if (!Backend.isAvailable) return const AuthResult.failed(_noBackend);

    try {
      await Backend.client.auth.signInWithOtp(email: address, shouldCreateUser: true);
      return const AuthResult.ok();
    } on AuthException catch (e) {
      return AuthResult.failed(_friendly(e));
    } catch (e) {
      debugPrint('mull: sendCode failed ($e)');
      return const AuthResult.failed(_offline);
    }
  }

  /// Exchanges the code for a session, then claims any seat that was waiting.
  static Future<AuthResult> verify({required String email, required String code}) async {
    if (!Backend.isAvailable) return const AuthResult.failed(_noBackend);
    final digits = code.replaceAll(RegExp(r'\D'), '');
    if (digits.length < 6) return const AuthResult.failed('The code is six digits.');

    final address = email.trim().toLowerCase();
    try {
      // Supabase sends a first-time address the "Confirm signup" template and a
      // returning one "Magic Link", and the two mint different token types. The
      // user has no idea which they got, so try the common one and fall back
      // rather than telling them a perfectly good code is wrong.
      try {
        await Backend.client.auth.verifyOTP(email: address, token: digits, type: OtpType.email);
      } on AuthException {
        await Backend.client.auth.verifyOTP(email: address, token: digits, type: OtpType.signup);
      }
      // Seats are claimed by GroupsSync, not here. A successful verify makes a
      // session appear, which wakes the sync's auth listener, which claims and
      // *then* pulls. Claiming here as well would race that pull rather than
      // precede it — the seat would land after the data it should have been in.
      return const AuthResult.ok();
    } on AuthException catch (e) {
      return AuthResult.failed(_friendly(e));
    } catch (e) {
      debugPrint('mull: verify failed ($e)');
      return const AuthResult.failed(_offline);
    }
  }

  /// Takes ownership of everything that was waiting on this address: group
  /// seats, and friend requests sent before there was an account to send them
  /// to.
  ///
  /// This is what lets someone add you to a flat before you have heard of
  /// Mull: the seat sits there holding your share, and signing up collects it.
  static Future<({int seats, int friends})> claimSeats() async {
    if (!Backend.isAvailable) return (seats: 0, friends: 0);
    try {
      final claimed = await Backend.client.rpc('claim_invitations');
      final map = claimed as Map<String, dynamic>?;
      return (
        seats: (map?['seats'] as num?)?.toInt() ?? 0,
        friends: (map?['friends'] as num?)?.toInt() ?? 0,
      );
    } catch (e) {
      debugPrint('mull: claim_invitations failed ($e)');
      return (seats: 0, friends: 0);
    }
  }

  static Future<void> signOut() async {
    if (!Backend.isAvailable) return;
    try {
      await Backend.client.auth.signOut();
    } catch (e) {
      debugPrint('mull: signOut failed ($e)');
    }
  }

  /// Keeps the profile row in step with what the user has told the app.
  static Future<void> saveProfile({String? name, String? upiId}) async {
    final id = Backend.user?.id;
    if (id == null) return;
    try {
      await Backend.client.from('profiles').update({
        if (name != null) 'name': name.trim(),
        if (upiId != null) 'upi_id': upiId.trim().isEmpty ? null : upiId.trim(),
      }).eq('id', id);
    } catch (e) {
      debugPrint('mull: saveProfile failed ($e)');
    }
  }

  static const _noBackend = 'Mull is not connected to a server in this build.';
  static const _offline = "Couldn't reach Mull. Check your connection and try again.";

  static final _email = RegExp(r'^[^@\s]+@[^@\s.]+\.[^@\s]{2,}$');

  static bool _looksLikeEmail(String value) => _email.hasMatch(value);

  /// Supabase's messages are written for developers.
  static String _friendly(AuthException e) {
    final message = e.message.toLowerCase();
    if (message.contains('expired')) return 'That code has expired. Send a new one.';
    if (message.contains('invalid')) return "That code didn't match. Try again.";
    if (message.contains('rate') || message.contains('too many')) {
      return 'Too many tries. Give it a minute.';
    }
    return e.message;
  }
}
