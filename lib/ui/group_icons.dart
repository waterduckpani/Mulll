/// The marks a group can carry, and how to find one.
///
/// A fixed, searchable set rather than an uploaded image or an emoji. An image
/// means a storage bucket, an upload, a crop and a cache, for something that
/// renders at 16 pixels; an emoji renders differently on every OS and puts
/// colour into a design that has none anywhere else. A key draws the same
/// stroke on every phone, in whatever ink the row around it is using.
///
/// Outlined glyphs throughout, because Mull's own icons are 1.6px strokes and
/// a filled shape next to them reads as a different app. These come from the
/// Material set that already ships with Flutter — 64 hand-drawn ones would
/// have been nicer and would also have been 64 CustomPainters.
///
/// Every entry carries the words people would actually type. "Goa" should find
/// the beach, "rent" the house, "chai" the coffee cup — searching an icon set
/// by its designer's name for things is how nobody finds anything.
library;

import 'package:flutter/material.dart';

@immutable
class GroupIcon {
  const GroupIcon(this.key, this.glyph, this.words);

  /// Stored on the group and pushed to Postgres, which checks the shape:
  /// lower case, starts with a letter, no spaces.
  final String key;

  final IconData glyph;

  /// What someone might type to find it. The key itself is always searched,
  /// so it does not need repeating here.
  final List<String> words;
}

/// Deliberately finite. A picker with 900 icons in it is a worse experience
/// than one with sixty: the point is to tell four groups apart at a glance,
/// not to express yourself.
const groupIcons = <GroupIcon>[
  // Living
  GroupIcon('home', Icons.home_outlined, ['flat', 'house', 'rent', 'apartment', 'pg', 'hostel']),
  GroupIcon('bed', Icons.bed_outlined, ['room', 'sleep', 'roommate', 'hostel']),
  GroupIcon('key', Icons.vpn_key_outlined, ['deposit', 'lease', 'landlord', 'rent']),
  GroupIcon('bolt', Icons.bolt_outlined, ['electricity', 'power', 'bill', 'current']),
  GroupIcon('water', Icons.water_drop_outlined, ['bill', 'tanker', 'plumber']),
  GroupIcon('wifi', Icons.wifi, ['internet', 'broadband', 'jio', 'airtel', 'bill']),
  GroupIcon('cleaning', Icons.cleaning_services_outlined, ['maid', 'house help', 'bai', 'cleaning']),
  GroupIcon('gas', Icons.local_fire_department_outlined, ['cylinder', 'stove', 'bill']),
  GroupIcon('tools', Icons.handyman_outlined, ['repairs', 'maintenance', 'fix']),

  // Going places
  GroupIcon('plane', Icons.flight_outlined, ['trip', 'flight', 'holiday', 'travel', 'vacation']),
  GroupIcon('beach', Icons.beach_access_outlined, ['goa', 'holiday', 'trip', 'sea', 'sun']),
  GroupIcon('mountain', Icons.terrain_outlined, ['trek', 'hills', 'manali', 'himalaya', 'hike']),
  GroupIcon('train', Icons.train_outlined, ['rail', 'irctc', 'travel']),
  GroupIcon('car', Icons.directions_car_outlined, ['road trip', 'drive', 'fuel', 'petrol', 'toll']),
  GroupIcon('cab', Icons.local_taxi_outlined, ['uber', 'ola', 'auto', 'taxi', 'ride']),
  GroupIcon('bike', Icons.two_wheeler_outlined, ['scooter', 'activa', 'petrol', 'rental']),
  GroupIcon('bus', Icons.directions_bus_outlined, ['travel', 'volvo', 'commute']),
  GroupIcon('hotel', Icons.hotel_outlined, ['stay', 'airbnb', 'villa', 'resort', 'booking']),
  GroupIcon('tent', Icons.cabin_outlined, ['camping', 'trek', 'outdoors']),
  GroupIcon('map', Icons.map_outlined, ['trip', 'route', 'plan', 'travel']),
  GroupIcon('luggage', Icons.luggage_outlined, ['trip', 'packing', 'travel']),

  // Eating
  GroupIcon('cutlery', Icons.restaurant_outlined, ['dinner', 'lunch', 'food', 'eat', 'restaurant']),
  GroupIcon('coffee', Icons.local_cafe_outlined, ['chai', 'cafe', 'tea', 'starbucks', 'break']),
  GroupIcon('pizza', Icons.local_pizza_outlined, ['takeaway', 'order', 'food', 'dominos']),
  GroupIcon('burger', Icons.lunch_dining_outlined, ['fast food', 'order', 'mcd']),
  GroupIcon('drinks', Icons.local_bar_outlined, ['bar', 'beer', 'night out', 'pub', 'alcohol']),
  GroupIcon('cake', Icons.cake_outlined, ['birthday', 'party', 'celebration']),
  GroupIcon('icecream', Icons.icecream_outlined, ['dessert', 'treat', 'sweet']),
  GroupIcon('groceries', Icons.shopping_basket_outlined, ['sabzi', 'kirana', 'blinkit', 'zepto', 'vegetables']),
  GroupIcon('takeaway', Icons.takeout_dining_outlined, ['swiggy', 'zomato', 'order', 'delivery']),

  // Doing things
  GroupIcon('football', Icons.sports_soccer_outlined, ['turf', 'match', 'sunday', 'game']),
  GroupIcon('cricket', Icons.sports_cricket_outlined, ['match', 'gully', 'game', 'ground']),
  GroupIcon('gym', Icons.fitness_center_outlined, ['workout', 'membership', 'fitness']),
  GroupIcon('badminton', Icons.sports_tennis_outlined, ['court', 'shuttle', 'tennis', 'game']),
  GroupIcon('swim', Icons.pool_outlined, ['pool', 'swimming', 'club']),
  GroupIcon('movie', Icons.local_movies_outlined, ['cinema', 'pvr', 'film', 'tickets']),
  GroupIcon('music', Icons.music_note_outlined, ['concert', 'gig', 'spotify', 'band']),
  GroupIcon('game', Icons.sports_esports_outlined, ['gaming', 'console', 'playstation', 'lan']),
  GroupIcon('camera', Icons.photo_camera_outlined, ['shoot', 'photos', 'trip']),
  GroupIcon('book', Icons.menu_book_outlined, ['study', 'college', 'course', 'notes']),
  GroupIcon('ticket', Icons.confirmation_number_outlined, ['event', 'entry', 'booking', 'pass']),

  // People and occasions
  GroupIcon('people', Icons.people_outline, ['group', 'friends', 'team', 'everyone']),
  GroupIcon('family', Icons.family_restroom_outlined, ['home', 'parents', 'relatives']),
  GroupIcon('party', Icons.celebration_outlined, ['birthday', 'new year', 'festival', 'diwali']),
  GroupIcon('gift', Icons.card_giftcard_outlined, ['present', 'secret santa', 'wedding', 'shagun']),
  GroupIcon('heart', Icons.favorite_border, ['date', 'partner', 'anniversary']),
  GroupIcon('pet', Icons.pets_outlined, ['dog', 'cat', 'vet', 'animal']),
  GroupIcon('baby', Icons.child_friendly_outlined, ['kids', 'creche', 'school']),

  // Money and work
  GroupIcon('work', Icons.work_outline, ['office', 'team', 'colleagues', 'client']),
  GroupIcon('briefcase', Icons.business_center_outlined, ['business', 'startup', 'company']),
  GroupIcon('receipt', Icons.receipt_long_outlined, ['bills', 'expenses', 'invoice']),
  GroupIcon('card', Icons.credit_card_outlined, ['subscription', 'emi', 'payment']),
  GroupIcon('wallet', Icons.account_balance_wallet_outlined, ['kitty', 'fund', 'pool', 'cash']),
  GroupIcon('piggy', Icons.savings_outlined, ['savings', 'fund', 'pot', 'kitty']),
  GroupIcon('school', Icons.school_outlined, ['college', 'hostel', 'class', 'university']),

  // Odds and ends
  GroupIcon('cart', Icons.shopping_cart_outlined, ['shopping', 'amazon', 'order', 'buy']),
  GroupIcon('bag', Icons.shopping_bag_outlined, ['shopping', 'clothes', 'mall']),
  GroupIcon('phone', Icons.smartphone_outlined, ['recharge', 'mobile', 'bill', 'postpaid']),
  GroupIcon('tv', Icons.tv_outlined, ['netflix', 'ott', 'subscription', 'prime', 'hotstar']),
  GroupIcon('plant', Icons.local_florist_outlined, ['garden', 'plants', 'flowers']),
  GroupIcon('health', Icons.medical_services_outlined, ['doctor', 'medicine', 'chemist', 'hospital']),
  GroupIcon('star', Icons.star_border, ['favourite', 'special', 'misc']),
  GroupIcon('sun', Icons.wb_sunny_outlined, ['summer', 'weekend', 'holiday']),
];

final _byKey = {for (final i in groupIcons) i.key: i};

/// The glyph for a stored key, or null for a group that has not picked one and
/// for a key written by a future version of the app.
IconData? groupGlyph(String? key) => key == null ? null : _byKey[key]?.glyph;

/// Matches on the key and on the words, in that order of preference, so typing
/// "home" puts the house first rather than a hostel that happens to mention it.
List<GroupIcon> searchGroupIcons(String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return groupIcons;

  final exact = <GroupIcon>[];
  final starts = <GroupIcon>[];
  final contains = <GroupIcon>[];

  for (final icon in groupIcons) {
    final terms = [icon.key, ...icon.words];
    if (terms.any((t) => t == q)) {
      exact.add(icon);
    } else if (terms.any((t) => t.startsWith(q))) {
      starts.add(icon);
    } else if (terms.any((t) => t.contains(q))) {
      contains.add(icon);
    }
  }
  return [...exact, ...starts, ...contains];
}
