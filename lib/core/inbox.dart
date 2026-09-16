import 'package:flutter/services.dart';

import 'link_reader.dart';
import 'screenshot_reader.dart';

/// Something the user shared into Mull from another app.
sealed class InboxItem {
  const InboxItem();
}

/// A screenshot, already recognised on the native side.
final class SharedShot extends InboxItem {
  const SharedShot(this.read);

  final ScreenshotRead read;
}

/// A product URL — [LinkReader] may still be able to fetch the real title.
final class SharedLink extends InboxItem {
  const SharedLink(this.url);

  final String url;
}

/// Shared text that had no URL in it. Usually a product name someone copied.
final class SharedText extends InboxItem {
  const SharedText(this.text);

  final String text;
}

/// The queue the share extension writes to.
///
/// The extension stays a dumb pipe: it only files what it was handed into the
/// App Group container. All the guessing happens here, on the same
/// [ScreenshotReader] and [LinkReader] the in-app add flow uses, so there is
/// one parser to test rather than a Swift copy no `flutter test` can reach.
class Inbox {
  static const _channel = MethodChannel('mull/screenshot');

  /// Everything shared since the app was last open, oldest first. Reading is
  /// destructive — the native side deletes each entry as it hands it over, so
  /// a share is never offered twice.
  static Future<List<InboxItem>> drain() async {
    final List<Object?>? raw;
    try {
      raw = await _channel.invokeMethod<List<Object?>>('drain');
    } on PlatformException {
      return const [];
    } on MissingPluginException {
      return const [];
    }
    if (raw == null) return const [];

    final items = <InboxItem>[];
    for (final entry in raw) {
      final map = (entry as Map).cast<Object?, Object?>();
      final item = _parse(map);
      if (item != null) items.add(item);
    }
    return items;
  }

  static InboxItem? _parse(Map<Object?, Object?> map) {
    switch (map['kind'] as String?) {
      case 'image':
        final lines = [
          for (final line in (map['lines'] as List? ?? const []))
            OcrLine.fromMap((line as Map).cast<Object?, Object?>()),
        ];
        final read = ScreenshotReader.parse(lines, thumb: map['thumb'] as Uint8List?);
        // A screenshot of a page we could read nothing from is worse than
        // nothing — it opens an empty sheet the user has to dismiss.
        return read.isEmpty ? null : SharedShot(read);

      case 'link':
        final url = map['url'] as String?;
        return url == null ? null : SharedLink(url);

      case 'text':
        final text = (map['text'] as String?)?.trim();
        if (text == null || text.isEmpty) return null;
        // Share sheets often hand over "Product name https://…" as one string.
        final url = LinkReader.extractUrl(text);
        return url != null ? SharedLink(url) : SharedText(text);

      default:
        return null;
    }
  }
}
