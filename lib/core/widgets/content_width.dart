import 'package:flutter/material.dart';

/// Caps how wide a reading column may grow.
///
/// The app is phone-first, but it also runs on web and desktop, where a
/// full-bleed list stretched a card to 1200px to hold three short lines and a
/// price — leaving a corridor of empty space down the middle of every row. A
/// line of text stops being comfortable to read somewhere around 70–80
/// characters, and a list row stops being scannable when its two ends are that
/// far apart.
///
/// Content stays left-aligned within the column; only the column itself is
/// centred, so nothing shifts on a phone where the constraint never binds.
class ContentWidth extends StatelessWidget {
  const ContentWidth({super.key, required this.child, this.maxWidth = 760});

  final Widget child;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    // heightFactor keeps the column as tall as its content, not as tall as
    // it may be: inside a bottom action bar a plain Align would grow to the
    // whole screen and leave nothing for the body.
    return Align(
      alignment: Alignment.topCenter,
      heightFactor: 1,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: child,
      ),
    );
  }
}
