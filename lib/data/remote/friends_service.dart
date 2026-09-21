/// Friends: the people you actually split things with.
///
/// The point of a friendship is that it carries facts about a person that only
/// that person should be entering. Before this, adding someone to a group meant
/// typing their name, their email and their UPI ID — and a VPA typed by the
/// payer is a payment to whoever owns that handle. A typo pays a stranger, it
/// succeeds, and nobody can undo it.
///
/// Once two people are friends, the name and the VPA come off the other
/// account and follow them when they change bank.
library;

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'auth_service.dart';
import 'backend.dart';

/// Which way a pending request is pointing, from your side of it.
enum FriendState {
  /// They asked; you have not answered.
  incoming,

  /// You asked; they have not answered. Also covers a request sent to an
  /// address with no account yet, which waits until they sign up.
  outgoing,

  friends,
}

class Friend {
  const Friend({
    required this.friendshipId,
    required this.state,
    this.userId,
    this.email,
    this.name = '',
    this.upiId,
  });

  final String friendshipId;
  final FriendState state;

  /// Null while the request is still addressed to an email nobody has claimed.
  final String? userId;
  final String? email;

  /// From their profile, never typed by you.
  final String name;
  final String? upiId;

  bool get hasAccount => userId != null;

  String get label => name.trim().isNotEmpty ? name.trim() : (email ?? 'Someone');

  String get initials {
    final source = label.trim();
    if (source.isEmpty) return '·';
    final parts = source.split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.length == 1) return parts.first[0].toUpperCase();
    return (parts.first[0] + parts.last[0]).toUpperCase();
  }
}

class FriendsResult {
  const FriendsResult.ok() : error = null;
  const FriendsResult.failed(this.error);

  final String? error;
  bool get isOk => error == null;
}

class FriendsService {
  /// Everyone you are connected to, in either direction and at any stage.
  ///
  /// A friendship does not know which side you are on: you might be the
  /// requester on one row and the addressee on the next. friend_list() works
  /// that out server-side and returns the other person as `other_*`.
  static Future<List<Friend>> list() async {
    final me = Backend.user?.id;
    if (me == null) return const [];
    try {
      // Through friend_list() rather than an embed of profiles: an email is
      // only for the two people in a friendship, and a UPI ID only once it is
      // accepted, and that is a per-row decision no column grant can make.
      final rows = await Backend.client.rpc('friend_list');

      final friends = <Friend>[];
      for (final row in rows as List) {
        final map = row as Map<String, dynamic>;
        final iAsked = map['requester_id'] == me;
        final accepted = map['status'] == 'accepted';

        friends.add(
          Friend(
            friendshipId: map['friendship_id'] as String,
            state: accepted ? FriendState.friends : (iAsked ? FriendState.outgoing : FriendState.incoming),
            userId: map['other_id'] as String?,
            // An unclaimed request has no profile to read, so the address it
            // was sent to is all there is to show.
            email: (map['other_email'] as String?) ?? map['addressee_email'] as String?,
            name: (map['other_name'] as String?) ?? '',
            upiId: map['other_upi_id'] as String?,
          ),
        );
      }

      friends.sort((a, b) {
        // Anything waiting on you comes first — it is the only row with
        // something to do.
        int rank(Friend f) => switch (f.state) {
          FriendState.incoming => 0,
          FriendState.friends => 1,
          FriendState.outgoing => 2,
        };
        final byState = rank(a).compareTo(rank(b));
        return byState != 0 ? byState : a.label.toLowerCase().compareTo(b.label.toLowerCase());
      });
      return friends;
    } catch (e) {
      debugPrint('mull: friends list failed ($e)');
      return const [];
    }
  }

  /// Sends a request to an address, whether or not anyone is behind it.
  ///
  /// Deliberately identical either way. The reply never says whether that
  /// address has a Mull account, because a call that answered would let anyone
  /// test a list of addresses to find out who is on the app.
  static Future<FriendsResult> request(String email) async {
    final me = Backend.user?.id;
    if (me == null) return const FriendsResult.failed('Sign in first.');
    final address = email.trim().toLowerCase();
    if (!_looksLikeEmail(address)) {
      return const FriendsResult.failed("That doesn't look like an email address.");
    }
    if (address == Backend.user?.email?.toLowerCase()) {
      return const FriendsResult.failed('That is your own address.');
    }

    try {
      // The server resolves the address, because the client is not allowed to.
      // A lookup that returned a row for a real address and nothing for a made
      // up one would answer "is this person on Mull" for any address anyone
      // cared to try. The RPC answers 'sent' either way.
      final outcome = await Backend.client.rpc(
        'send_friend_request',
        params: {'target_email': address},
      );
      if (outcome == 'already') return const FriendsResult.failed("You're already connected.");
      return const FriendsResult.ok();
    } catch (e) {
      debugPrint('mull: friend request failed ($e)');
      return const FriendsResult.failed("Couldn't send that. Try again.");
    }
  }

  /// Accepting goes through the server too: a request sent before you had an
  /// account names an email rather than a user, and attaching it to you is the
  /// one identity change the guard trigger allows — but only from here.
  ///
  /// Accepting is also what lets a seat waiting on your address become yours:
  /// `claim_invitations()` only claims into a group where someone you have
  /// accepted already sits, so it is asked again straight away rather than on
  /// the next launch.
  static Future<FriendsResult> accept(String friendshipId) async {
    try {
      await Backend.client.rpc('accept_friend_request', params: {'friendship': friendshipId});
      await AuthService.claimSeats();
      return const FriendsResult.ok();
    } catch (e) {
      debugPrint('mull: accept failed ($e)');
      return const FriendsResult.failed("Couldn't accept that. Try again.");
    }
  }

  /// Declining, cancelling and unfriending are the same row going away.
  static Future<FriendsResult> remove(String friendshipId) async {
    try {
      await Backend.client.from('friendships').delete().eq('id', friendshipId);
      return const FriendsResult.ok();
    } catch (e) {
      debugPrint('mull: remove friend failed ($e)');
      return const FriendsResult.failed("Couldn't do that. Try again.");
    }
  }

  /// Stops someone reaching you: no friend requests, reminders or notices
  /// from them. Ledgers you already share stay, because they are other
  /// people's records too. They are not told.
  static Future<FriendsResult> block(String userId) async {
    try {
      await Backend.client.rpc('block_user', params: {'target': userId});
      return const FriendsResult.ok();
    } catch (e) {
      debugPrint('mull: block failed ($e)');
      return const FriendsResult.failed("Couldn't block them. Try again.");
    }
  }

  static Future<FriendsResult> unblock(String userId) async {
    try {
      await Backend.client.rpc('unblock_user', params: {'target': userId});
      return const FriendsResult.ok();
    } catch (e) {
      debugPrint('mull: unblock failed ($e)');
      return const FriendsResult.failed("Couldn't unblock them. Try again.");
    }
  }

  /// Everyone you have blocked, newest first.
  static Future<List<({String userId, String name})>> blocked() async {
    try {
      final rows = await Backend.client.rpc('my_blocks');
      return [
        for (final row in rows as List)
          (userId: (row as Map)['user_id'] as String, name: row['name'] as String? ?? 'Someone'),
      ];
    } catch (e) {
      debugPrint('mull: my_blocks failed ($e)');
      return const [];
    }
  }

  /// Sends a report to whoever runs Mull. [reason] is one of `spam`,
  /// `harassment`, `impersonation` or `other`.
  static Future<FriendsResult> report(
    String userId, {
    required String reason,
    String note = '',
    bool alsoBlock = false,
  }) async {
    try {
      await Backend.client.rpc(
        'report_user',
        params: {'target': userId, 'reason': reason, 'note': note.trim(), 'also_block': alsoBlock},
      );
      return const FriendsResult.ok();
    } on PostgrestException catch (e) {
      debugPrint('mull: report failed ($e)');
      return FriendsResult.failed(
        e.code == '54000' ? "That's a lot of reports today. Email us instead." : "Couldn't send that. Try again.",
      );
    } catch (e) {
      debugPrint('mull: report failed ($e)');
      return const FriendsResult.failed("Couldn't send that. Try again.");
    }
  }

  static final _email = RegExp(r'^[^@\s]+@[^@\s.]+\.[^@\s]{2,}$');
  static bool _looksLikeEmail(String value) => _email.hasMatch(value);
}
