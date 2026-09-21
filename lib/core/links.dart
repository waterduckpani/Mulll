/// Mull's pages on the web. Source in `site/`.
library;

import 'package:url_launcher/url_launcher.dart';

class MullLinks {
  static const site = 'https://mull.oblunestudio.com';
  static final privacy = Uri.parse('$site/privacy.html');
  static final terms = Uri.parse('$site/terms.html');
  static final support = Uri.parse('$site/support.html');

  /// Where an invite sends people. The site until the App Store listing is
  /// live; swap in the apps.apple.com link the day it is.
  static const download = site;

  /// In Safari's in-app sheet, so reading the policy does not leave Mull.
  static Future<void> open(Uri page) async {
    try {
      await launchUrl(page, mode: LaunchMode.inAppBrowserView);
    } catch (_) {
      // No browser to hand it to. Nothing useful to say about it.
    }
  }
}
