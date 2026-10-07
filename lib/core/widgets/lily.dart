import 'package:flutter/material.dart';

import '../../app/theme/app_theme.dart';

/// The Red Lily component kit: the handful of shapes every screen is built
/// from, so a panel on the order page and a panel on the profile are the
/// same panel.

/// Breakpoints. Below [tablet] the app is a phone; between, a tablet; above
/// [desktop], a wide window with a navigation rail and multi-column grids.
abstract final class Breakpoints {
  static const tablet = 700.0;
  static const desktop = 1000.0;

  static bool isWide(BuildContext context) =>
      MediaQuery.sizeOf(context).width >= desktop;

  static int columns(BuildContext context, {double minTile = 340}) {
    final width = MediaQuery.sizeOf(context).width;
    return (width / minTile).floor().clamp(1, 3);
  }
}

/// A titled region of a page, with an optional trailing action.
class SectionHeader extends StatelessWidget {
  const SectionHeader(
    this.title, {
    super.key,
    this.subtitle,
    this.actionLabel,
    this.onAction,
    this.padding = const EdgeInsets.fromLTRB(0, 24, 0, 10),
  });

  final String title;
  final String? subtitle;
  final String? actionLabel;
  final VoidCallback? onAction;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: padding,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: theme.textTheme.titleLarge),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(subtitle!, style: theme.textTheme.bodySmall),
                ],
              ],
            ),
          ),
          if (actionLabel != null && onAction != null)
            TextButton(
              onPressed: onAction,
              style: TextButton.styleFrom(
                foregroundColor: theme.colorScheme.primary,
              ),
              child: Text(actionLabel!),
            ),
        ],
      ),
    );
  }
}

/// A white panel on the ivory ground: the container for a group of related
/// content. Cards inside a list are [Card]; regions of a page are this.
class LilyPanel extends StatelessWidget {
  const LilyPanel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(18),
    this.tint,
    this.onTap,
  });

  final Widget child;
  final EdgeInsets padding;

  /// A faint wash of colour for a panel that carries a state (a warning, a
  /// highlight). Null keeps the panel white.
  final Color? tint;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    // Full width of whatever holds it: a region of a page, not a chip.
    final body = SizedBox(
      width: double.infinity,
      child: Padding(padding: padding, child: child),
    );
    return Material(
      color: tint != null
          ? tint!.withValues(alpha: dark ? 0.18 : 0.10)
          : dark
          ? theme.colorScheme.surfaceContainer
          : theme.colorScheme.surfaceContainerLowest,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppTheme.radiusPanel),
        side: dark || tint != null
            ? BorderSide(
                color:
                    tint?.withValues(alpha: 0.35) ??
                    theme.colorScheme.outlineVariant,
              )
            : BorderSide.none,
      ),
      elevation: dark || tint != null ? 0 : 2,
      shadowColor: theme.colorScheme.shadow.withValues(alpha: 0.08),
      clipBehavior: Clip.antiAlias,
      child: onTap == null
          ? body
          : InkWell(
              onTap: onTap,
              splashColor: Colors.transparent,
              highlightColor: Colors.transparent,
              hoverColor: theme.colorScheme.primary.withValues(alpha: 0.06),
              child: body,
            ),
    );
  }
}

/// The five tones a status can carry. Chosen once, here, so a pill on an
/// order and a pill on a payout that mean the same thing look the same.
enum Tone { neutral, active, attention, success, danger }

/// A small pill that names a state. Pills are the only rounded-full shapes
/// besides buttons and chips, and never tappable.
class StatusPill extends StatelessWidget {
  const StatusPill({
    super.key,
    required this.label,
    required this.tone,
    this.icon,
    this.dense = false,
  });

  final String label;
  final Tone tone;
  final IconData? icon;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (bg, fg) = switch (tone) {
      Tone.neutral => (scheme.surfaceContainerHigh, scheme.onSurfaceVariant),
      Tone.active => (scheme.primaryContainer, scheme.onPrimaryContainer),
      Tone.attention => (scheme.tertiaryContainer, scheme.onTertiaryContainer),
      Tone.success => (scheme.secondaryContainer, scheme.onSecondaryContainer),
      Tone.danger => (scheme.errorContainer, scheme.onErrorContainer),
    };
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: dense ? 8 : 10,
        vertical: dense ? 3 : 5,
      ),
      decoration: BoxDecoration(
        color: bg,
        shape: BoxShape.rectangle,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: dense ? 12 : 14, color: fg),
            const SizedBox(width: 4),
          ],
          Flexible(
            child: Text(
              label,
              style: TextStyle(
                fontSize: dense ? 11.5 : 12.5,
                fontWeight: FontWeight.w700,
                color: fg,
                height: 1.2,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One figure with its label, for a row of key numbers.
class StatTile extends StatelessWidget {
  const StatTile({
    super.key,
    required this.label,
    required this.value,
    this.icon,
    this.emphasis = false,
    this.caption,
  });

  final String label;
  final String value;
  final IconData? icon;
  final bool emphasis;
  final String? caption;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      constraints: const BoxConstraints(minHeight: 98),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainer.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(AppTheme.radiusControl),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (icon != null) ...[
                Icon(icon, size: 14, color: theme.colorScheme.onSurfaceVariant),
                const SizedBox(width: 5),
              ],
              Flexible(
                child: Text(
                  label,
                  style: theme.textTheme.labelMedium,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: emphasis
                ? AppTheme.price(context, size: 22)
                : theme.textTheme.titleMedium,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 2),
          SizedBox(
            height:
                (theme.textTheme.bodySmall?.height ?? 1.2) *
                (theme.textTheme.bodySmall?.fontSize ?? 12),
            child: caption == null
                ? null
                : Text(
                    caption!,
                    style: theme.textTheme.bodySmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
          ),
        ],
      ),
    );
  }
}

/// A grid of [StatTile]s that wraps on a phone and rows out on a tablet.
class StatGrid extends StatelessWidget {
  const StatGrid({super.key, required this.tiles, this.minTile = 150});

  final List<Widget> tiles;
  final double minTile;

  @override
  Widget build(BuildContext context) {
    if (tiles.isEmpty) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = ((constraints.maxWidth + 10) / (minTile + 10))
            .floor()
            .clamp(1, tiles.length.clamp(1, 4));
        final width = (constraints.maxWidth - (columns - 1) * 10) / columns;
        return Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            for (final tile in tiles) SizedBox(width: width, child: tile),
          ],
        );
      },
    );
  }
}

/// The gradient header a page opens with. White text on the lily gradient,
/// with the page body overlapping its bottom edge.
class PageHero extends StatelessWidget {
  const PageHero({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.fromLTRB(20, 16, 20, 36),
  });

  final Widget child;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(gradient: AppTheme.hero(context)),
      child: SafeArea(
        bottom: false,
        child: Padding(padding: padding, child: child),
      ),
    );
  }
}

/// Text styles for content sitting on [PageHero].
abstract final class OnHero {
  static const title = TextStyle(
    fontFamily: 'Bricolage',
    fontSize: 28,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.8,
    height: 1.1,
    color: Colors.white,
  );
  static const subtitle = TextStyle(
    fontFamily: 'Jakarta',
    fontSize: 13.5,
    fontWeight: FontWeight.w500,
    height: 1.4,
    color: Color(0xE6FFFFFF),
  );
}

/// The lily mark: a rounded square with a stylised petal.
class LilyMark extends StatelessWidget {
  const LilyMark({super.key, this.size = 44, this.onHero = false});

  final double size;
  final bool onHero;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: onHero ? Colors.white.withValues(alpha: 0.18) : scheme.primary,
        borderRadius: BorderRadius.circular(size * 0.32),
        border: onHero
            ? Border.all(color: Colors.white.withValues(alpha: 0.35))
            : null,
      ),
      child: Icon(
        Icons.local_florist_rounded,
        size: size * 0.58,
        color: onHero ? Colors.white : scheme.onPrimary,
      ),
    );
  }
}

/// A bar pinned to the bottom of a detail screen with the primary action
/// and, usually, the figure the action is about.
class StickyActionBar extends StatelessWidget {
  const StickyActionBar({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    return Container(
      decoration: BoxDecoration(
        color: dark
            ? theme.colorScheme.surfaceContainerLow
            : theme.colorScheme.surfaceContainerLowest,
        border: Border(
          top: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
        boxShadow: AppTheme.lift(context),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: child,
        ),
      ),
    );
  }
}

/// A row of chips that scrolls sideways instead of wrapping or overflowing.
///
/// Filter and sort pills sit in one line on every screen; on a phone the
/// line is longer than the screen, so it scrolls. A [Wrap] would push the
/// content down by a row per extra chip, and a bare [Row] paints the
/// overflow stripes.
class ChipStrip extends StatelessWidget {
  const ChipStrip({
    super.key,
    required this.children,
    this.padding = const EdgeInsets.fromLTRB(16, 8, 16, 8),
    this.spacing = 8,
  });

  final List<Widget> children;
  final EdgeInsets padding;
  final double spacing;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: padding,
      child: Row(
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) SizedBox(width: spacing),
            children[i],
          ],
        ],
      ),
    );
  }
}

/// A grey block that stands in for content while it loads.
class SkeletonBox extends StatefulWidget {
  const SkeletonBox({super.key, this.height = 16, this.width, this.radius = 8});

  final double height;
  final double? width;
  final double radius;

  @override
  State<SkeletonBox> createState() => _SkeletonBoxState();
}

class _SkeletonBoxState extends State<SkeletonBox>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final base = Theme.of(context).colorScheme.surfaceContainerHigh;
    return FadeTransition(
      opacity: Tween(begin: 0.55, end: 1.0).animate(_pulse),
      child: Container(
        height: widget.height,
        width: widget.width,
        decoration: BoxDecoration(
          color: base,
          borderRadius: BorderRadius.circular(widget.radius),
        ),
      ),
    );
  }
}

/// A list of card-shaped skeletons, for lists that are loading.
/// A column, not a list view, so it can stand in for a list whether it is
/// the whole body or one block inside a scrolling page: a viewport inside
/// a column has no height to fill and throws.
class SkeletonList extends StatelessWidget {
  const SkeletonList({
    super.key,
    this.count = 4,
    this.height = 96,
    this.padding = const EdgeInsets.all(16),
  });

  final int count;
  final double height;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < count; i++) ...[
            if (i > 0) const SizedBox(height: 10),
            SkeletonBox(height: height, radius: AppTheme.radiusCard),
          ],
        ],
      ),
    );
  }
}

/// A round tinted icon, the head of a row or an empty state.
class IconDisc extends StatelessWidget {
  const IconDisc({super.key, required this.icon, this.tint, this.size = 40});

  final IconData icon;
  final Color? tint;
  final double size;

  @override
  Widget build(BuildContext context) {
    final colour = tint ?? Theme.of(context).colorScheme.primary;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: colour.withValues(alpha: 0.12),
        shape: BoxShape.circle,
      ),
      child: Icon(icon, size: size * 0.5, color: colour),
    );
  }
}

/// A row in a settings-style list: icon, title, subtitle, chevron.
class NavTile extends StatelessWidget {
  const NavTile({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.onTap,
    this.trailing,
    this.tint,
    this.destructive = false,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback? onTap;
  final Widget? trailing;
  final Color? tint;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colour = destructive ? theme.colorScheme.error : tint;
    return ListTile(
      onTap: onTap,
      contentPadding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      leading: IconDisc(
        icon: icon,
        tint: colour ?? theme.colorScheme.onSurfaceVariant,
        size: 38,
      ),
      title: Text(
        title,
        style: theme.textTheme.titleSmall?.copyWith(
          color: destructive ? theme.colorScheme.error : null,
        ),
      ),
      subtitle: subtitle == null ? null : Text(subtitle!),
      trailing:
          trailing ??
          (onTap == null
              ? null
              : Icon(
                  Icons.chevron_right_rounded,
                  color: theme.colorScheme.outline,
                )),
    );
  }
}
