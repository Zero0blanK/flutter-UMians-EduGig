import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import 'attachment.dart';

class VideoAttachmentView extends StatefulWidget {
  const VideoAttachmentView({
    super.key,
    required this.attachment,
    required this.onOpen,
    this.foreground,
  });

  final Attachment attachment;
  final VoidCallback onOpen;
  final Color? foreground;

  @override
  State<VideoAttachmentView> createState() => _VideoAttachmentViewState();
}

class _VideoAttachmentViewState extends State<VideoAttachmentView>
    with WidgetsBindingObserver {
  VideoPlayerController? _controller;
  bool _loading = false;
  bool _failed = false;

  bool get _supported =>
      kIsWeb ||
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (ModalRoute.isCurrentOf(context) == false) _controller?.pause();
  }

  @override
  void didUpdateWidget(VideoAttachmentView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.attachment.url != widget.attachment.url) {
      _controller?.dispose();
      _controller = null;
      _loading = false;
      _failed = false;
    }
  }

  Future<void> _start() async {
    if (_loading || _controller != null) return;
    setState(() => _loading = true);
    final controller = VideoPlayerController.networkUrl(
      Uri.parse(widget.attachment.url),
    );
    _controller = controller;
    try {
      await controller.initialize().timeout(const Duration(seconds: 30));
      if (!mounted || _controller != controller) return;
      setState(() => _loading = false);
      // A second tap starts playback, preserving browser user activation.
    } on Exception {
      if (mounted && _controller == controller) {
        setState(() {
          _failed = true;
          _loading = false;
        });
      }
    }
  }

  Future<void> _toggle() async {
    final controller = _controller;
    if (controller == null) return;
    try {
      if (controller.value.isPlaying) {
        await controller.pause();
      } else {
        await controller.play();
      }
    } on Exception {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _controller?.pause();
  }

  @override
  void deactivate() {
    _controller?.pause();
    super.deactivate();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller?.dispose();
    super.dispose();
  }

  Widget _fallback() => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      const Text('Video playback is unavailable here.'),
      TextButton(
        style: TextButton.styleFrom(foregroundColor: widget.foreground),
        onPressed: widget.onOpen,
        child: const Text('Open video externally'),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    return SizedBox(
      width: 280,
      child: DefaultTextStyle.merge(
        style: TextStyle(color: widget.foreground),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.attachment.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            Text(widget.attachment.sizeLabel),
            if (!_supported || _failed)
              _fallback()
            else if (_loading)
              Padding(
                padding: const EdgeInsets.all(16),
                child: CircularProgressIndicator(color: widget.foreground),
              )
            else if (controller == null)
              IconButton(
                tooltip: 'Load video',
                onPressed: _start,
                icon: Icon(
                  Icons.play_circle_outline,
                  color: widget.foreground,
                  size: 40,
                ),
              )
            else
              ValueListenableBuilder<VideoPlayerValue>(
                valueListenable: controller,
                builder: (context, value, _) {
                  if (value.hasError) return _fallback();
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AspectRatio(
                        aspectRatio: value.aspectRatio,
                        child: VideoPlayer(controller),
                      ),
                      if (value.isBuffering)
                        LinearProgressIndicator(color: widget.foreground),
                      VideoProgressIndicator(
                        controller,
                        allowScrubbing: true,
                        colors: VideoProgressColors(
                          playedColor:
                              widget.foreground ??
                              Theme.of(context).colorScheme.primary,
                          bufferedColor:
                              (widget.foreground ??
                                      Theme.of(context).colorScheme.primary)
                                  .withValues(alpha: 0.4),
                          backgroundColor:
                              (widget.foreground ??
                                      Theme.of(context).colorScheme.primary)
                                  .withValues(alpha: 0.15),
                        ),
                      ),
                      IconButton(
                        tooltip: value.isPlaying ? 'Pause video' : 'Play video',
                        onPressed: _toggle,
                        icon: Icon(
                          value.isPlaying ? Icons.pause : Icons.play_arrow,
                          color: widget.foreground,
                        ),
                      ),
                    ],
                  );
                },
              ),
          ],
        ),
      ),
    );
  }
}
