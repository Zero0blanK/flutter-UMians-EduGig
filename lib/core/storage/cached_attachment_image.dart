import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'attachment_image_cache.dart';

class CachedAttachmentImage extends StatefulWidget {
  const CachedAttachmentImage({
    super.key,
    required this.url,
    required this.fit,
    required this.errorBuilder,
  });

  final String url;
  final BoxFit fit;
  final ImageErrorWidgetBuilder errorBuilder;

  @override
  State<CachedAttachmentImage> createState() => _CachedAttachmentImageState();
}

class _CachedAttachmentImageState extends State<CachedAttachmentImage> {
  late Future<Uint8List> _bytes;

  @override
  void initState() {
    super.initState();
    _bytes = AttachmentImageCache.shared.load(widget.url);
  }

  @override
  void didUpdateWidget(CachedAttachmentImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _bytes = AttachmentImageCache.shared.load(widget.url);
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<Uint8List>(
    key: ValueKey(widget.url),
    future: _bytes,
    initialData: AttachmentImageCache.shared.cached(widget.url),
    builder: (context, snapshot) {
      if (snapshot.hasError) {
        return widget.errorBuilder(context, snapshot.error!, null);
      }
      final bytes = snapshot.data;
      if (bytes == null) {
        return const SizedBox(
          height: 120,
          child: Center(child: CircularProgressIndicator()),
        );
      }
      return Image.memory(
        bytes,
        fit: widget.fit,
        errorBuilder: (context, error, stackTrace) {
          AttachmentImageCache.shared.remove(widget.url);
          return widget.errorBuilder(context, error, stackTrace);
        },
      );
    },
  );
}
