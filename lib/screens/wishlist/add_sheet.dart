import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/inbox.dart';
import '../../core/link_reader.dart';
import '../../core/money.dart';
import '../../core/screenshot_reader.dart';
import '../../data/models.dart';
import '../../data/store.dart';
import '../../ui/icons.dart';
import '../../ui/sheet.dart';
import '../../ui/tokens.dart';
import '../../ui/widgets.dart';
import 'need_check_sheet.dart';

class AddResult {
  const AddResult(this.name, this.price, this.kind, this.url);
  final String name;
  final int price;
  final ItemKind? kind;
  final String? url;
}

/// "Add something" — two taps, details later. Opens the need check for needs.
///
/// [shared] is set when the item arrived through the share sheet rather than
/// being typed. Same sheet, same save path — only prefilled, so there is one
/// add flow to reason about instead of two.
Future<void> showQuickAdd(BuildContext context, {ItemKind? kind, InboxItem? shared}) async {
  final store = context.readStore;
  final result = await showMullSheet<AddResult>(
    context,
    // Tall enough for the need/want pair to sit above the fold. Below this the
    // scroll view clips them, and a choice you cannot see is a choice you
    // cannot make — it is the one control this sheet cannot save without.
    height: 664,
    builder: (_) => AddSheet(
      title: shared == null ? 'Add something' : 'Add this to Mull',
      cta: 'Save it',
      footnote: shared == null
          ? 'Two taps. You can add details later.'
          : 'Shared from another app — check it over.',
      askKind: true,
      initialKind: kind,
      initialShot: shared is SharedShot ? shared.read : null,
      initialUrl: shared is SharedLink ? shared.url : null,
      initialName: shared is SharedText ? shared.text : null,
    ),
  );
  if (result == null || !context.mounted) return;
  final item = store.addItem(name: result.name, price: result.price, kind: result.kind!, url: result.url);
  HapticFeedback.mediumImpact();
  if (item.kind == ItemKind.need) {
    await Future.delayed(const Duration(milliseconds: 180));
    if (context.mounted) await showNeedCheck(context, item);
  } else {
    if (context.mounted) Toast.show(context, 'Saved ${item.name}');
  }
}

/// Reused for list entries and logged spends.
class AddSheet extends StatefulWidget {
  const AddSheet({
    super.key,
    required this.title,
    required this.cta,
    this.footnote,
    this.askKind = false,
    this.initialKind,
    this.readLinks = true,
    this.namePlaceholder = "What's it called?",
    this.nameHelp = 'Or paste any link — we read the name and price for you.',
    this.priceHint = 'roughly is fine',
    this.initialShot,
    this.initialUrl,
    this.initialName,
  });

  final String title;
  final String cta;
  final String? footnote;
  final bool askKind;
  final ItemKind? initialKind;
  final bool readLinks;
  final String namePlaceholder;
  final String nameHelp;
  final String priceHint;

  /// Prefill from something shared into Mull from another app. The sheet opens
  /// already filled in, so the share sheet and the in-app scan land in the same
  /// editable place rather than two different flows.
  final ScreenshotRead? initialShot;
  final String? initialUrl;
  final String? initialName;

  @override
  State<AddSheet> createState() => _AddSheetState();
}

class _AddSheetState extends State<AddSheet> {
  final _name = TextEditingController();
  final _price = AmountController();
  final _nameFocus = FocusNode();
  final _priceFocus = FocusNode();
  late ItemKind? _kind = widget.initialKind;
  String? _url;
  ScreenshotRead? _shot;
  bool _reading = false;
  bool _scanning = false;
  bool _clipboardHasText = false;

  @override
  void initState() {
    super.initState();
    _priceFocus.addListener(() {
      if (!_priceFocus.hasFocus) _price.tidy();
      setState(() {});
    });
    _price.addListener(() => setState(() {}));
    if (widget.readLinks) {
      Clipboard.hasStrings().then((v) {
        if (mounted) setState(() => _clipboardHasText = v);
      });
    }
    final shot = widget.initialShot;
    if (shot != null) {
      _shot = shot;
      if (shot.name != null) _name.text = shot.name!;
      if (shot.price != null) _price.text = inr(shot.price!);
    }
    if (widget.initialName != null && _name.text.isEmpty) {
      _name.text = widget.initialName!;
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      final url = widget.initialUrl;
      if (url != null) {
        _readLink(url);
        return;
      }
      Future.delayed(const Duration(milliseconds: 280), () {
        if (!mounted) return;
        // Land on the first thing still missing. With nothing prefilled that is
        // the name, which is the old behaviour.
        if (_name.text.isEmpty) {
          _nameFocus.requestFocus();
        } else if (_price.amount == null) {
          _priceFocus.requestFocus();
        }
      });
    });
  }

  @override
  void dispose() {
    _name.dispose();
    _price.dispose();
    _nameFocus.dispose();
    _priceFocus.dispose();
    super.dispose();
  }

  void _onName(String text) {
    if (!widget.readLinks) {
      setState(() {});
      return;
    }
    final url = LinkReader.extractUrl(text);
    if (url != null) {
      _readLink(url);
    } else {
      setState(() {});
    }
  }

  /// Reads the item off a screenshot the user picks. Works on the stores that
  /// block [LinkReader] — which is most of the big ones.
  Future<void> _scan() async {
    FocusScope.of(context).unfocus();
    setState(() => _scanning = true);

    ScreenshotRead? read;
    var failed = false;
    try {
      read = await ScreenshotReader.pick();
    } catch (_) {
      failed = true;
    }
    if (!mounted) return;
    setState(() => _scanning = false);

    if (failed) {
      Toast.show(context, "Couldn't open your photos");
      return;
    }
    final result = read;
    if (result == null) return; // backed out of the picker
    if (result.isEmpty) {
      Toast.show(context, "Couldn't read that one — type it in");
      return;
    }

    setState(() {
      _shot = result;
      _url = null;
      if (result.name != null) _name.text = result.name!;
      if (result.price != null) _price.text = inr(result.price!);
    });
    HapticFeedback.lightImpact();
    if (_name.text.isEmpty) {
      _nameFocus.requestFocus();
    } else if (_price.amount == null) {
      _priceFocus.requestFocus();
    }
  }

  Future<void> _readLink(String url) async {
    setState(() {
      _url = url;
      _shot = null;
      _reading = true;
      _name.text = '';
    });
    final preview = await LinkReader.read(url);
    if (!mounted || _url != url) return;
    setState(() {
      _reading = false;
      _url = preview.url;
      if (_name.text.isEmpty && preview.title != null) _name.text = preview.title!;
      if (_price.text.isEmpty && preview.price != null) _price.text = inr(preview.price!);
    });
    HapticFeedback.lightImpact();
    if (_name.text.isEmpty) {
      _nameFocus.requestFocus();
    } else if (_price.amount == null) {
      _priceFocus.requestFocus();
    } else {
      FocusScope.of(context).unfocus();
    }
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim();
    if (text == null || text.isEmpty || !mounted) return;
    final url = LinkReader.extractUrl(text);
    if (url != null) {
      _readLink(url);
    } else {
      _name.text = text.length > 60 ? text.substring(0, 60) : text;
      _name.selection = TextSelection.collapsed(offset: _name.text.length);
      setState(() {});
    }
  }

  bool get _valid =>
      _name.text.trim().isNotEmpty &&
      _price.amount != null &&
      (!widget.askKind || _kind != null) &&
      !_reading &&
      !_scanning;

  /// Offers the screenshot route, then becomes a receipt for what it read.
  Widget _scanCard() {
    final c = context.c;
    const margin = EdgeInsets.fromLTRB(26, 14, 26, 0);
    final shot = _shot;

    if (shot != null) {
      return Glass(
        margin: margin,
        padding: const EdgeInsets.fromLTRB(12, 12, 18, 12),
        child: Row(
          children: [
            if (shot.thumb != null)
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Image.memory(
                  shot.thumb!,
                  width: 38,
                  height: 38,
                  fit: BoxFit.cover,
                  alignment: Alignment.topCenter,
                ),
              ),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                shot.domain == null ? 'Read from your screenshot' : 'Read from ${shot.domain}',
                style: ranade(13, color: c.ink2),
              ),
            ),
            Pressable(
              onTap: () => setState(() => _shot = null),
              child: Text(
                'Remove',
                style: ranade(12.5, color: c.ink3, decoration: TextDecoration.underline),
              ),
            ),
          ],
        ),
      );
    }

    return Pressable(
      onTap: _scanning ? null : _scan,
      scale: .985,
      child: Glass(
        margin: margin,
        padding: const EdgeInsets.fromLTRB(18, 14, 16, 14),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _scanning ? 'Reading your screenshot…' : 'Scan a screenshot',
                    style: ranade(15, color: c.ink),
                  ),
                  const SizedBox(height: 3),
                  Text('From Zara, Amazon, Instagram — anywhere', style: ranade(11.5, color: c.ink3)),
                ],
              ),
            ),
            const SizedBox(width: 12),
            if (_scanning)
              SizedBox.square(dimension: 13, child: CircularProgressIndicator(strokeWidth: 1.3, color: c.ink3))
            else
              MullIcon(MullGlyph.chevronRight, size: 16, color: c.ink3, strokeWidth: 1.8),
          ],
        ),
      ),
    );
  }

  void _save() {
    if (!_valid) return;
    Navigator.of(context).pop(AddResult(_name.text.trim(), _price.amount!, _kind, _url));
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final keyboardUp = MediaQuery.viewInsetsOf(context).bottom > 0;
    final domain = _url == null ? null : LinkReader.domainOf(_url!);
    final parsed = _price.amount;
    final showParsed = parsed != null && _price.text != inr(parsed);

    Widget nameHelp;
    if (_reading) {
      nameHelp = Row(
        children: [
          SizedBox.square(dimension: 10, child: CircularProgressIndicator(strokeWidth: 1.2, color: c.ink3)),
          const SizedBox(width: 8),
          Text('Reading $domain…'),
        ],
      );
    } else if (domain != null) {
      nameHelp = GestureDetector(
        onTap: () => setState(() => _url = null),
        child: Text.rich(
          TextSpan(
            children: [
              TextSpan(text: 'From $domain  ·  '),
              TextSpan(
                text: 'Remove link',
                style: TextStyle(color: c.ink2, decoration: TextDecoration.underline, decorationColor: c.line),
              ),
            ],
          ),
        ),
      );
    } else {
      nameHelp = Text(widget.readLinks ? widget.nameHelp : '');
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SheetHeader(widget.title),
        Expanded(
          child: SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            // On a short screen the content still scrolls; this keeps the last
            // control clear of the fold instead of flush against it.
            padding: const EdgeInsets.only(bottom: 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (widget.readLinks) _scanCard(),
                Padding(
                  padding: const EdgeInsets.fromLTRB(30, 16, 30, 0),
                  child: BigField(
                    controller: _name,
                    focusNode: _nameFocus,
                    hint: _reading ? '' : widget.namePlaceholder,
                    onChanged: _onName,
                    textInputAction: TextInputAction.next,
                    onSubmitted: (_) => _priceFocus.requestFocus(),
                    trailing: widget.readLinks && _name.text.isEmpty && !_reading && _clipboardHasText
                        ? Pressable(
                            onTap: _paste,
                            child: Container(
                              height: 32,
                              padding: const EdgeInsets.symmetric(horizontal: 12),
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(color: c.line),
                              ),
                              child: Text('Paste', style: ranade(12.5, color: c.ink2)),
                            ),
                          )
                        : null,
                    help: widget.readLinks ? nameHelp : null,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(30, 22, 30, 0),
                  child: BigField(
                    controller: _price,
                    focusNode: _priceFocus,
                    hint: '₹0',
                    numeric: true,
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) {
                      _price.tidy();
                      if (!widget.askKind || _kind != null) _save();
                    },
                    trailing: Text(
                      showParsed ? inr(parsed) : widget.priceHint,
                      style: showParsed ? excon(13, color: c.ink2) : ranade(11.5, color: c.ink3),
                    ),
                    help: const Text('28000, 28k, 28,000 or ₹28k all work.'),
                  ),
                ),
                if (widget.askKind)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(26, 24, 26, 12),
                    child: ChoicePair<ItemKind>(
                      options: const [(ItemKind.need, 'Need'), (ItemKind.want, 'Want')],
                      value: _kind,
                      onChanged: (k) {
                        _price.tidy();
                        setState(() => _kind = k);
                      },
                    ),
                  ),
              ],
            ),
          ),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(26, 8, 26, keyboardUp ? 4 : 34),
          child: Column(
            children: [
              PillButton(widget.cta, onTap: _valid ? _save : null),
              if (!keyboardUp && widget.footnote != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    widget.askKind && _kind == null && _name.text.isNotEmpty && parsed != null
                        ? 'Is it a need or a want?'
                        : widget.footnote!,
                    style: ranade(11.5, color: c.ink3),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
