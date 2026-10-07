import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../features/chat/data/chat_repository.dart';
import 'verified_badge.dart';

/// Renders the display name behind a uid.
///
/// Several screens held a uid but showed nothing — a service page named no
/// seller, and reviews were attributed to nobody — which is a poor look on a
/// marketplace whose whole premise is knowing who you are dealing with.
///
/// Resolution goes through [ChatRepository.displayNameOf], which keeps a
/// session-local cache, so a list of reviews by the same person costs one read
/// rather than one per row.
class UserName extends StatefulWidget {
  const UserName({
    super.key,
    required this.uid,
    this.style,
    this.prefix = '',
    this.fallback = 'Student',
    this.linkToProfile = false,
  });

  final String uid;
  final TextStyle? style;

  /// Optional lead-in, e.g. `'by '`.
  final String prefix;

  /// Shown while loading and if the profile cannot be read, so the row never
  /// collapses or flashes empty.
  final String fallback;

  /// Makes the name open that student's public profile.
  ///
  /// Off by default: inside a row that is already tappable, a second tap
  /// target competing with the first is worse than a plain label.
  final bool linkToProfile;

  @override
  State<UserName> createState() => _UserNameState();
}

class _UserNameState extends State<UserName> {
  late Future<PeerSummary> _summary;

  @override
  void initState() {
    super.initState();
    _summary = _resolve();
  }

  @override
  void didUpdateWidget(UserName oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.uid != widget.uid) _summary = _resolve();
  }

  Future<PeerSummary> _resolve() =>
      context.read<ChatRepository>().summaryOf(widget.uid);

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<PeerSummary>(
      future: _summary,
      builder: (context, snapshot) {
        final text = Text(
          '${widget.prefix}${snapshot.data?.name ?? widget.fallback}',
          style: widget.linkToProfile
              ? (widget.style ?? const TextStyle()).copyWith(
                  decoration: TextDecoration.underline,
                  decorationColor: Theme.of(context).colorScheme.outlineVariant,
                )
              : widget.style,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        );
        // The badge rides on the same cached read as the name, so showing
        // it on every card costs nothing extra.
        final label = snapshot.data?.verified ?? false
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(child: text),
                  const SizedBox(width: 3),
                  VerifiedBadge(size: (widget.style?.fontSize ?? 14) + 2),
                ],
              )
            : text;
        if (!widget.linkToProfile) return label;
        return InkWell(
          onTap: () => context.push('/user/${widget.uid}'),
          borderRadius: BorderRadius.circular(4),
          child: label,
        );
      },
    );
  }
}

/// Circular initial for a uid whose display name is not yet known.
///
/// [UserAvatar] takes a name you already have; this one resolves it, through
/// the same session cache [UserName] uses, so a row can show a face without
/// its parent having to fetch the profile first.
///
/// [ring] tints the border. The marketplace passes the category colour, which
/// puts the seller and what they sell into a single mark at the head of every
/// listing.
class UserAvatarFor extends StatefulWidget {
  const UserAvatarFor({
    super.key,
    required this.uid,
    this.radius = 22,
    this.ring,
  });

  final String uid;
  final double radius;
  final Color? ring;

  @override
  State<UserAvatarFor> createState() => _UserAvatarForState();
}

class _UserAvatarForState extends State<UserAvatarFor> {
  late Future<String> _name;

  @override
  void initState() {
    super.initState();
    _name = _resolve();
  }

  @override
  void didUpdateWidget(UserAvatarFor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.uid != widget.uid) _name = _resolve();
  }

  Future<String> _resolve() =>
      context.read<ChatRepository>().displayNameOf(widget.uid);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ring = widget.ring ?? theme.colorScheme.outlineVariant;
    return FutureBuilder<String>(
      future: _name,
      builder: (context, snapshot) {
        final name = (snapshot.data ?? '').trim();
        return Container(
          width: widget.radius * 2,
          height: widget.radius * 2,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            // The tint at low alpha behind the initial, at full strength on
            // the ring: enough category colour to scan a list by, not enough
            // to fight the title next to it.
            color: ring.withValues(alpha: 0.14),
            shape: BoxShape.circle,
            border: Border.all(color: ring.withValues(alpha: 0.55), width: 1.5),
          ),
          child: Text(
            name.isEmpty ? '·' : name[0].toUpperCase(),
            style: theme.textTheme.titleMedium?.copyWith(
              color: ring,
              fontSize: widget.radius * 0.8,
              height: 1,
            ),
          ),
        );
      },
    );
  }
}

/// Circular initial for a uid, paired with [UserName] in list rows.
class UserAvatar extends StatelessWidget {
  const UserAvatar({
    super.key,
    required this.name,
    this.radius = 18,
    this.photoUrl,
  });

  final String name;
  final double radius;
  final String? photoUrl;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final initial = name.trim().isEmpty ? '?' : name.trim()[0].toUpperCase();
    final photo = photoUrl;
    return CircleAvatar(
      radius: radius,
      backgroundColor: theme.colorScheme.primaryContainer,
      foregroundColor: theme.colorScheme.onPrimaryContainer,
      child: photo == null || photo.isEmpty
          ? Text(initial, style: theme.textTheme.titleSmall)
          : ClipOval(
              child: Image.network(
                photo,
                width: radius * 2,
                height: radius * 2,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) =>
                    Text(initial, style: theme.textTheme.titleSmall),
              ),
            ),
    );
  }
}
