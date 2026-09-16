import 'package:flutter/services.dart';

import 'link_reader.dart';
import 'money.dart';

/// One recognised line of text. Coordinates are normalised 0–1 with (0,0) at
/// the top-left, and [h] is the line's height — our proxy for font size, which
/// is what most of the guessing below leans on.
class OcrLine {
  const OcrLine(this.text, {this.x = 0, this.y = 0, this.w = 1, this.h = .02, this.conf = 1});

  factory OcrLine.fromMap(Map<Object?, Object?> m) => OcrLine(
    m['text'] as String? ?? '',
    x: _d(m['x']),
    y: _d(m['y']),
    w: _d(m['w']),
    h: _d(m['h']),
    conf: _d(m['conf']),
  );

  final String text;
  final double x;
  final double y;
  final double w;
  final double h;
  final double conf;

  static double _d(Object? v) => (v as num?)?.toDouble() ?? 0;
}

/// What we managed to pull out of a screenshot.
class ScreenshotRead {
  const ScreenshotRead({this.name, this.price, this.domain, this.thumb});

  final String? name;
  final int? price;

  /// Read off the Safari address bar when the screenshot happens to include it.
  final String? domain;
  final Uint8List? thumb;

  bool get isEmpty => name == null && price == null;
}

/// Reads a product out of a screenshot.
///
/// [LinkReader] only works on stores that let us fetch their pages — Zara,
/// Massimo Dutti and Amazon all refuse. Pixels can't refuse, so this path works
/// on any store, any app, and a price tag in a shop window. The cost is that
/// everything here is a guess, so every field lands in an editable sheet.
class ScreenshotReader {
  static const _channel = MethodChannel('mull/screenshot');

  /// Opens the system picker. Null if the user backed out.
  static Future<ScreenshotRead?> pick() async {
    final raw = await _channel.invokeMapMethod<String, Object?>('pick');
    if (raw == null) return null;
    final lines = [
      for (final line in (raw['lines'] as List? ?? const []))
        OcrLine.fromMap((line as Map).cast<Object?, Object?>()),
    ];
    return parse(lines, thumb: raw['thumb'] as Uint8List?);
  }

  static ScreenshotRead parse(List<OcrLine> lines, {Uint8List? thumb}) {
    final price = _price(lines);
    return ScreenshotRead(
      name: _name(lines, price?.y),
      price: price?.value,
      domain: _domain(lines),
      thumb: thumb,
    );
  }

  /// Money written the way stores write it: ₹2,999 / Rs. 2,999 / INR 2999.
  static final _marked = RegExp(r'(?:₹|rs\.?|inr)\s*([\d][\d,]*(?:\.\d{1,2})?)', caseSensitive: false);

  /// The same, with the currency trailing: Massimo Dutti writes "13,900.00INR".
  static final _markedAfter = RegExp(
    r'([\d][\d,]*(?:\.\d{1,2})?)\s*(?:₹|rs\.?|inr)\b',
    caseSensitive: false,
  );

  /// A bare number long enough to plausibly be a price.
  static final _bare = RegExp(r'\b([\d][\d,]{2,}(?:\.\d{1,2})?)\b');

  static final _mrp = RegExp(r'\bm\.?r\.?p\.?', caseSensitive: false);

  /// Marketing and metadata that is never the name and never the price.
  static final _junk = RegExp(
    r'(★|☆|\bemi\b|\bcoupon\b|\bcashback\b|\brating|\breview|\bdeliver|\bbought\b)',
    caseSensitive: false,
  );

  /// A discount badge — "40% off", "(30%)". Deliberately capped at two digits:
  /// "100% WOOL REGULAR FIT CHECK SHIRT" is a product name, and half of fashion
  /// names lead with a fibre percentage. Nothing is ever 100% off.
  static final _discount = RegExp(r'\b\d{1,2}\s*%');

  /// Extra traps for prices only — "off" and "save" are left out of [_junk]
  /// because Off-White and Savage are things people actually buy. Any percent
  /// belongs here too: the "100" in "100% WOOL" is otherwise a tempting number.
  static final _priceJunk = RegExp(r'(\boff\b|\bmonth\b|\bsave\b|%)', caseSensitive: false);

  static final _domainPattern = RegExp(
    r'\b((?:[a-z0-9-]+\.)+(?:com|in|net|org|co|shop|store|io))\b',
    caseSensitive: false,
  );

  /// Interface furniture that sits near the product but never describes it.
  static const _chrome = {
    'add to cart', 'add to bag', 'add to basket', 'add to wishlist', 'buy now',
    'sponsored', 'delivery', 'select size', 'size guide', 'reviews', 'ratings',
    'in stock', 'out of stock', 'secure transaction', 'sold by', 'quantity',
    'returns', 'share', 'search', 'cancel', 'done', 'similar items', 'checkout',
    'you may also like', 'more like this', 'view details', 'see all', 'shop now',
    'inclusive of all taxes', 'wishlist', 'notify me', 'find in store',
    'view look', 'view product', 'complete the look', 'size chart',
  };

  /// The biggest, most currency-looking number on the screen.
  static ({int value, double y})? _price(List<OcrLine> lines) {
    int? bestValue;
    var bestY = 0.0;
    var bestScore = 0.0;

    for (final line in lines) {
      if (_junk.hasMatch(line.text) || _priceJunk.hasMatch(line.text)) continue;
      final discounted = _mrp.hasMatch(line.text) ? .5 : 1.0;

      for (final (marked, match) in [
        for (final m in _marked.allMatches(line.text)) (true, m),
        for (final m in _markedAfter.allMatches(line.text)) (true, m),
        for (final m in _bare.allMatches(line.text)) (false, m),
      ]) {
        final value = parseAmount(match.group(1)!);
        if (value == null) continue;
        if (!marked && value < 100) continue; // ratings, sizes, counts
        if (value > 5000000) continue; // order numbers, phone numbers

        final score = line.h * line.conf * (marked ? 1.7 : 1) * discounted;
        if (bestValue == null || score > bestScore) {
          bestValue = value;
          bestY = line.y;
          bestScore = score;
        } else if (score > bestScore * .9 && value < bestValue) {
          // Two prices at the same size: the selling price, not the struck-out one.
          bestValue = value;
          bestY = line.y;
        }
      }
    }
    return bestValue == null ? null : (value: bestValue, y: bestY);
  }

  /// The biggest line that reads like a product name, preferring the one
  /// sitting just above the price — which is where titles almost always are.
  static String? _name(List<OcrLine> lines, double? priceY) {
    String? best;
    var bestScore = 0.0;

    for (final line in lines) {
      final text = line.text.trim();
      final lower = text.toLowerCase();
      if (text.length < 4 || text.length > 90) continue;
      if (_letters(text) < 3) continue; // prices, sizes, clock, battery
      if (_junk.hasMatch(text)) continue; // "4.3 ★ 2,145 ratings"
      if (_discount.hasMatch(text)) continue; // "40% off", but not "100% WOOL"
      if (_marked.hasMatch(text) || _markedAfter.hasMatch(text)) continue;
      if (_domainPattern.hasMatch(text)) continue; // the address bar
      if (_chrome.any((word) => lower.contains(word))) continue;
      if (line.y > .85) continue; // tab bar

      var score = line.h * line.conf;
      if (line.y < .1) score *= .35; // status bar and the store's own logo
      if (priceY != null) {
        if (line.y < priceY && priceY - line.y < .2) {
          score *= 1.6;
        } else if (line.y > priceY) {
          score *= .7; // descriptions and offers trail the price
        }
      }
      if (score > bestScore) {
        bestScore = score;
        best = text;
      }
    }
    return best == null ? null : LinkReader.tidyTitle(best);
  }

  static String? _domain(List<OcrLine> lines) {
    for (final line in lines) {
      // Only the address bar counts — and since iOS 15 Safari puts it at the
      // bottom by default, which is where most real screenshots have it. A
      // domain in the middle of the page is a footer link, not the store.
      if (line.y > .22 && line.y < .88) continue;
      final match = _domainPattern.firstMatch(line.text);
      if (match != null) {
        return match.group(1)!.toLowerCase().replaceFirst(RegExp(r'^(www\d?|m)\.'), '');
      }
    }
    return null;
  }

  static final _letter = RegExp('[A-Za-z]');

  static int _letters(String s) => _letter.allMatches(s).length;
}
