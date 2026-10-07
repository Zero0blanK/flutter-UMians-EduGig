import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/widgets/lily.dart';
import 'theme_controller.dart';

/// The light/dark control, shown in Profile.
///
/// A three-way picker rather than a switch, because "follow my phone" is a
/// real answer and a two-state switch has nowhere to put it. The choice is
/// shown as a segmented control so all three states are visible at once —
/// with a switch you have to toggle it to find out what it does.
class AppearanceCard extends StatelessWidget {
  const AppearanceCard({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final controller = context.watch<ThemeController>();

    return LilyPanel(
      child: Padding(
        padding: EdgeInsets.zero,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  controller.mode.icon,
                  size: 20,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text('Appearance', style: theme.textTheme.titleSmall),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              _describe(context, controller.mode),
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: LayoutBuilder(
                builder: (context, constraints) => SegmentedButton<ThemeMode>(
                  direction:
                      constraints.maxWidth <
                          340 * MediaQuery.textScalerOf(context).scale(14) / 14
                      ? Axis.vertical
                      : Axis.horizontal,
                  segments: [
                    for (final mode in ThemeMode.values)
                      ButtonSegment(
                        value: mode,
                        icon: Icon(mode.icon, size: 18),
                        label: Text(mode.label),
                      ),
                  ],
                  selected: {controller.mode},
                  onSelectionChanged: (selection) =>
                      controller.setMode(selection.first),
                  showSelectedIcon: false,
                  style: SegmentedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 12,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Says what the current setting actually does. For [ThemeMode.system] that
  /// depends on the phone, so it names what the phone is doing right now
  /// rather than leaving the student to guess.
  static String _describe(BuildContext context, ThemeMode mode) {
    switch (mode) {
      case ThemeMode.light:
        return 'Always light, whatever your phone is set to.';
      case ThemeMode.dark:
        return 'Always dark, whatever your phone is set to.';
      case ThemeMode.system:
        final dark =
            MediaQuery.platformBrightnessOf(context) == Brightness.dark;
        return 'Following your phone, which is ${dark ? 'dark' : 'light'} '
            'right now.';
    }
  }
}

/// A one-tap light/dark flip for an app bar.
///
/// Sits beside the picker rather than replacing it: the picker is where you
/// go to set a preference, this is for the moment you walk outside and the
/// screen is suddenly unreadable. Tapping it commits to an explicit mode —
/// there is no half-state where the app is dark but still says "System".
class ThemeToggleButton extends StatelessWidget {
  const ThemeToggleButton({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<ThemeController>();
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return IconButton(
      tooltip: isDark ? 'Switch to light' : 'Switch to dark',
      icon: Icon(isDark ? Icons.light_mode_outlined : Icons.dark_mode_outlined),
      onPressed: () =>
          controller.setMode(isDark ? ThemeMode.light : ThemeMode.dark),
    );
  }
}
