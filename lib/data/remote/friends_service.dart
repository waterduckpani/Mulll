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
  /// The two profile embeds are both needed because a friendship does not know
  /// which side you are on: you might be the requester on one row and the
  /// addressee on the next, and the person you want to see is always the other
  /// one.
  static Future<List<Friend>> list() async {
    final me = Backend.user?.id;
    if (me == null) return const [];
    try {
      final rows = await Backend.client.from('friendships').select('''
            id, requester_id, addressee_id, addressee_email, status,
            requester:requester_id ( id, name, upi_id, email ),
            addressee:addressee_id ( id, name, upi_id, email )
          ''');

      final friends = <Friend>[];
      for (final row in rows as List) {
        final map = row as Map<String, dynamic>;
        final iAsked = map['requester_id'] == me;
        final other = (iAsked ? map['addressee'] : map['requester']) as Map<String, dynamic>?;
        final accepted = map['status'] == 'accepted';

        friends.add(
          Friend(
            friendshipId: map['id'] as String,
            state: accepted ? FriendState.friends : (iAsked ? FriendState.outgoing : FriendState.incoming),
            userId: other?['id'] as String?,
            // An unclaimed request has no profile to read, so the address it
            // was sent to is all there is to show.
            email: (other?['email'] as String?) ?? map['addressee_email'] as String?,
            name: (other?['name'] as String?) ?? '',
            upiId: other?['upi_id'] as String?,
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

  static final _email = RegExp(r'^[^@\s]+@[^@\s.]+\.[^@\s]{2,}$');
  static bool _looksLikeEmail(String value) => _email.hasMatch(value);
}
