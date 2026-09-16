import 'dart:convert';

import 'package:http/http.dart' as http;

class LinkPreview {
  const LinkPreview({required this.url, required this.domain, this.title, this.price});
  final String url;
  final String domain;
  final String? title;
  final int? price;
}

/// Reads a product page and pulls out a sensible name and price.
/// Works on OpenGraph / JSON-LD / microdata, with a few store-specific fallbacks.
class LinkReader {
  static final _urlPattern = RegExp(r'https?://[^\s<>"]+', caseSensitive: false);

  static String? extractUrl(String text) => _urlPattern.firstMatch(text)?.group(0);

  static String domainOf(String url) {
    final host = Uri.tryParse(url)?.host ?? url;
    return host.replaceFirst(RegExp(r'^(www\d?|m)\.'), '');
  }

  static Future<LinkPreview> read(String url, {http.Client? client}) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return LinkPreview(url: url, domain: url);
    final c = client ?? http.Client();
    try {
      final res = await c
          .get(
            uri,
            headers: const {
              'User-Agent': 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1',
              'Accept': 'text/html,application/xhtml+xml',
              'Accept-Language': 'en-IN,en;q=0.9',
            },
          )
          .timeout(const Duration(seconds: 8));
      final finalUrl = res.request?.url.toString() ?? url;
      final html = utf8.decode(res.bodyBytes, allowMalformed: true);
      return LinkPreview(
        url: finalUrl,
        domain: domainOf(finalUrl),
        title: _title(html) ?? _slugTitle(Uri.parse(finalUrl)),
        price: _price(html),
      );
    } catch (_) {
      return LinkPreview(url: url, domain: domainOf(url), title: _slugTitle(uri));
    } finally {
      if (client == null) c.close();
    }
  }

  static final _metaTag = RegExp(r'<meta\s[^>]*>', caseSensitive: false);
  static final _attr = RegExp(r'''([\w:-]+)\s*=\s*("([^"]*)"|'([^']*)')''');

  static Map<String, String> _metas(String html) {
    final out = <String, String>{};
    for (final tag in _metaTag.allMatches(html)) {
      final attrs = <String, String>{};
      for (final a in _attr.allMatches(tag.group(0)!)) {
        attrs[a.group(1)!.toLowerCase()] = a.group(3) ?? a.group(4) ?? '';
      }
      final key = attrs['property'] ?? attrs['name'] ?? attrs['itemprop'];
      final content = attrs['content'];
      if (key != null && content != null) out.putIfAbsent(key.toLowerCase(), () => content);
    }
    return out;
  }

  static String? _title(String html) {
    final metas = _metas(html);
    var raw = metas['og:title'] ?? metas['twitter:title'];
    raw ??= RegExp(r'<title[^>]*>([\s\S]*?)</title>', caseSensitive: false).firstMatch(html)?.group(1);
    if (raw == null) return null;
    return tidyTitle(_decodeEntities(raw));
  }

  /// "Anker 65W USB-C Charger, Nano … : Amazon.in: Electronics" → "Anker 65W USB-C Charger"
  static String? tidyTitle(String raw) {
    var t = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
    t = t.replaceFirst(RegExp(r'^(buy|shop)\s+', caseSensitive: false), '');
    for (final sep in [' : ', ' | ', ' – ', ' — ', ' - ']) {
      final i = t.indexOf(sep);
      if (i > 3) t = t.substring(0, i);
    }
    t = t.replaceFirst(RegExp(r'\s+(online|at best price).*$', caseSensitive: false), '');
    for (final sep in [', ', ' (', ' with ']) {
      final i = t.indexOf(sep);
      if (i > 12) t = t.substring(0, i);
    }
    if (t.length > 42) {
      final cut = t.substring(0, 42);
      final space = cut.lastIndexOf(' ');
      t = space > 20 ? cut.substring(0, space) : cut;
    }
    t = t.trim();
    return t.isEmpty ? null : t;
  }

  static int? _price(String html) {
    final metas = _metas(html);
    for (final key in ['product:price:amount', 'og:price:amount', 'price', 'twitter:data1']) {
      final v = metas[key];
      final p = v == null ? null : _num(v);
      if (p != null) return p;
    }
    final jsonLd = RegExp(r'"(?:price|lowPrice)"\s*:\s*"?([\d.,]+)"?').firstMatch(html);
    if (jsonLd != null) {
      final p = _num(jsonLd.group(1)!);
      if (p != null) return p;
    }
    final amazon = RegExp(r'a-price-whole">([\d,]+)').firstMatch(html);
    if (amazon != null) return _num(amazon.group(1)!);
    final rupee = RegExp(r'(?:₹|&#8377;|Rs\.?)\s?([\d,]{3,}(?:\.\d{1,2})?)').firstMatch(html);
    if (rupee != null) return _num(rupee.group(1)!);
    return null;
  }

  static int? _num(String s) {
    final cleaned = s.replaceAll(RegExp(r'[^\d.]'), '');
    final d = double.tryParse(cleaned);
    if (d == null || d <= 0) return null;
    return d.round();
  }

  static String? _slugTitle(Uri uri) {
    final segments = uri.pathSegments.where((s) {
      if (s.isEmpty || s.length < 4) return false;
      if (RegExp(r'^[\dA-Z]+$').hasMatch(s)) return false;
      return !{'dp', 'p', 'product', 'products', 'item', 'd', 'gp'}.contains(s.toLowerCase());
    }).toList();
    if (segments.isEmpty) return null;
    final slug = segments.reduce((a, b) => b.contains('-') && b.length >= a.length ? b : a);
    final words = Uri.decodeComponent(slug)
        .replaceAll(RegExp(r'\.(html?|php|aspx)$'), '')
        .split(RegExp(r'[-_+]'))
        .where((w) => w.isNotEmpty && !RegExp(r'^\d{5,}$').hasMatch(w))
        .take(5)
        .join(' ');
    if (words.isEmpty) return null;
    return words[0].toUpperCase() + words.substring(1);
  }

  static String _decodeEntities(String s) => s
      .replaceAll('&amp;', '&')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&#x27;', "'")
      .replaceAll('&apos;', "'")
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&nbsp;', ' ')
      .replaceAllMapped(RegExp(r'&#(\d+);'), (m) => String.fromCharCode(int.parse(m.group(1)!)));
}
