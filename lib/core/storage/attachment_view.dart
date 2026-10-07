import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'attachment.dart';
import 'cached_attachment_image.dart';
import 'video_attachment_view.dart';

/// Renders images and chat videos inline, with an external file fallback.
/// Used by chat bubbles and delivery cards.
class AttachmentView extends StatelessWidget {
  const AttachmentView({
    super.key,
    required this.attachment,
    this.foreground,
    this.maxImageHeight = 220,
  });

  final Attachment attachment;

  /// Text and icon colour; defaults to the theme's on-surface colour.
  final Color? foreground;
  final double maxImageHeight;

  Future<void> _open(BuildContext context) async {
    try {
      if (await launchUrl(
        Uri.parse(attachment.url),
        mode: LaunchMode.externalApplication,
      )) {
        return;
      }
    } on Exception {
      // Report the launch failure without exposing platform details.
    }
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Could not open this attachment. Please try again.'),
      ),
    );
  }

  void _showImage(BuildContext context) {
    showDialog<void>(
      context: context,
      barrierColor: Colors.black,
      builder: (context) => Dialog.fullscreen(
        backgroundColor: Colors.black,
        child: Stack(
          children: [
            Positioned.fill(
              child: InteractiveViewer(
                minScale: 0.8,
                maxScale: 4,
                child: Center(
                  child: CachedAttachmentImage(
                    url: attachment.url,
                    fit: BoxFit.contain,
                    errorBuilder: (context, error, stack) => const Icon(
                      Icons.broken_image_outlined,
                      color: Colors.white70,
                      size: 48,
                    ),
                  ),
                ),
              ),
            ),
            SafeArea(
              child: Align(
                alignment: Alignment.topRight,
                child: IconButton(
                  tooltip: 'Close image',
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close, color: Colors.white),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colour = foreground ?? theme.colorScheme.onSurface;
    if (attachment.isVideo) {
      return VideoAttachmentView(
        attachment: attachment,
        foreground: colour,
        onOpen: () => _open(context),
      );
    }

    if (attachment.isImage) {
      return GestureDetector(
        onTap: () => _showImage(context),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxImageHeight),
            child: CachedAttachmentImage(
              url: attachment.url,
              fit: BoxFit.cover,
              errorBuilder: (context, error, stack) => _FileChip(
                attachment: attachment,
                colour: colour,
                onTap: () => _open(context),
              ),
            ),
          ),
        ),
      );
    }
    return _FileChip(
      attachment: attachment,
      colour: colour,
      onTap: () => _open(context),
    );
  }
}

class _FileChip extends StatelessWidget {
  const _FileChip({
    required this.attachment,
    required this.colour,
    required this.onTap,
  });

  final Attachment attachment;
  final Color colour;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: colour.withValues(alpha: 0.25)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.insert_drive_file_outlined, size: 20, color: colour),
            const SizedBox(width: 8),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    attachment.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: colour,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    attachment.sizeLabel,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colour.withValues(alpha: 0.7),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(Icons.open_in_new, size: 16, color: colour),
          ],
        ),
      ),
    );
  }
}
