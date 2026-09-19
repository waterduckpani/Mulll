/// Picking the mark a group carries.
///
/// A search field over a grid, rather than a grid alone. Sixty icons is small
/// enough to scroll and big enough that scrolling is the slower way to find
/// the plane — and people arrive knowing the word for what they want. The
/// search matches on what someone would actually type, so "goa" finds the
/// beach and "rent" finds the house.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/models.dart';
import '../../data/store.dart';
import '../../ui/group_icons.dart';
import '../../ui/icons.dart';
import '../../ui/page.dart';
import '../../ui/sheet.dart';
import '../../ui/tokens.dart';
import '../../ui/widgets.dart';

/// Resolves to the chosen key, or to null if the sheet was closed without
/// choosing. "No icon" resolves to the empty string, because null already
/// means "changed your mind".
Future<String?> showIconPicker(BuildContext context, {String? current}) =>
    showMullSheet<String>(context, height: 640, builder: (_) => _IconPicker(current: current));

/// Picks an icon straight onto a group. Returns whether anything changed.
Future<bool> pickGroupIcon(BuildContext context, Group group) async {
  final store = context.readStore;
  final chosen = await showIconPicker(context, current: group.icon);
  if (chosen == null) return false;
  store.setGroupIcon(group, chosen.isEmpty ? null : chosen);
  HapticFeedback.selectionClick();
  return true;
}

class _IconPicker extends StatefulWidget {
  const _IconPicker({this.current});

  final String? current;

  @override
  State<_IconPicker> createState() => _IconPickerState();
}

class _IconPickerState extends State<_IconPicker> {
  final _query = TextEditingController();

  @override
  void initState() {
    super.initState();
    _query.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final results = searchGroupIcons(_query.text);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SheetHeader('Pick an icon'),
        Padding(
          padding: const EdgeInsets.fromLTRB(Gutter.text, 8, Gutter.text, 0),
          child: BigField(
            controller: _query,
            size: 20,
            autofocus: false,
            hint: 'Search — trip, rent, dinner',
          ),
        ),
        const SizedBox(height: 18),
        Expanded(
          child: results.isEmpty
              ? Padding(
                  padding: const EdgeInsets.fromLTRB(Gutter.text, 10, Gutter.text, 0),
                  child: Text(
                    'Nothing matches “${_query.text.trim()}”. Try the thing itself '
                    '— a place, a meal, a bill.',
                    style: MullType.body(c.ink3),
                  ),
                )
              : GridView.builder(
                  physics: const BouncingScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(Gutter.card, 0, Gutter.card, 20),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 5,
                    mainAxisSpacing: 10,
                    crossAxisSpacing: 10,
                  ),
                  itemCount: results.length,
                  itemBuilder: (context, i) {
                    final icon = results[i];
                    return _IconCell(
                      icon: icon,
                      selected: icon.key == widget.current,
                      onTap: () => Navigator.of(context).pop(icon.key),
                    );
                  },
                ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(Gutter.card, 0, Gutter.card, 26),
          child: SecondaryButton(
            'No icon',
            onTap: () => Navigator.of(context).pop(''),
          ),
        ),
      ],
    );
  }
}

class _IconCell extends StatelessWidget {
  const _IconCell({required this.icon, required this.selected, required this.onTap});

  final GroupIcon icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Pressable(
      onTap: onTap,
      scale: .92,
      semanticLabel: icon.key,
      child: Container(
        alignment: Alignment.center,
        decoration: selected
            ? BoxDecoration(color: c.pill, borderRadius: BorderRadius.circular(20))
            : surfaceOf(c, Lift.flat, radius: BorderRadius.circular(20)),
        // Selected is the inverse fill, exactly like every other chosen thing
        // in Mull. No tick, no ring, and certainly no accent colour.
        child: Icon(icon.glyph, size: 22, color: selected ? c.pillInk : c.ink2),
      ),
    );
  }
}

/// The mark on a group row, wherever one is shown.
///
/// Falls back to the generic people glyph so a group that has never picked one
/// still has something in the slot — a row that is sometimes indented and
/// sometimes not is worse than a row with a default in it.
class IconWell extends StatelessWidget {
  const IconWell({
    super.key,
    this.iconKey,
    this.size = 38,
    this.glyphSize = 18,
    this.fallback = MullGlyph.groups,
    this.onTap,
    this.quiet = false,
  });

  final String? iconKey;
  final double size;
  final double glyphSize;
  final MullGlyph fallback;
  final VoidCallback? onTap;

  /// Sinks into the page instead of floating, for a row that is already on a
  /// card of its own — a badge lifting off a lifted surface reads as a button.
  final bool quiet;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final glyph = groupGlyph(iconKey);
    final well = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: surfaceOf(
        c,
        quiet ? Lift.flat : Lift.low,
        radius: BorderRadius.circular(size / 2.6),
      ),
      child: glyph != null
          ? Icon(glyph, size: glyphSize, color: c.ink2)
          : MullIcon(fallback, size: glyphSize - 1, color: c.ink3, strokeWidth: 1.6),
    );
    if (onTap == null) return well;
    return Pressable(onTap: onTap, scale: .92, semanticLabel: 'Pick an icon', child: well);
  }
}

class GroupBadge extends StatelessWidget {
  const GroupBadge({
    super.key,
    required this.group,
    this.size = 38,
    this.glyphSize = 18,
    this.quiet = false,
  });

  final Group group;
  final double size;
  final double glyphSize;
  final bool quiet;

  @override
  Widget build(BuildContext context) => IconWell(
    iconKey: group.icon,
    size: size,
    glyphSize: glyphSize,
    quiet: quiet,
    fallback: group.isDirect ? MullGlyph.person : MullGlyph.groups,
  );
}
