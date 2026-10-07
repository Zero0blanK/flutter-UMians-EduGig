import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

/// Keeps the actual destination visible, including for shared cloud files.
class ChatMessageText extends StatefulWidget {
  const ChatMessageText(this.text, {super.key, this.style});

  final String text;
  final TextStyle? style;

  @override
  State<ChatMessageText> createState() => _ChatMessageTextState();
}

class _ChatMessageTextState extends State<ChatMessageText> {
  final _recognizers = <TapGestureRecognizer>[];

  void _clearRecognizers() {
    for (final recognizer in _recognizers) {
      recognizer.dispose();
    }
    _recognizers.clear();
  }

  Future<void> _open(Uri uri) async {
    try {
      if (await launchUrl(uri, mode: LaunchMode.externalApplication)) return;
    } on Exception {
      // The same actionable error covers missing handlers and launch errors.
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Could not open this link. Copy it into your browser.'),
      ),
    );
  }

  @override
  void dispose() {
    _clearRecognizers();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _clearRecognizers();
    final spans = <TextSpan>[];
    var end = 0;
    for (final match in RegExp(
      r'https://[^\s<>]+',
      caseSensitive: false,
    ).allMatches(widget.text)) {
      // Do not turn the HTTPS suffix of another scheme into a link.
      if (match.start > 0 &&
          !RegExp(r'''[\s(\[{'"]''').hasMatch(widget.text[match.start - 1])) {
        continue;
      }
      var url = match.group(0)!;
      url = url.replaceFirst(RegExp(r'''[.,!?;:'"]+$'''), '');
      for (final pair in [('(', ')'), ('[', ']'), ('{', '}')]) {
        while (url.endsWith(pair.$2) &&
            pair.$2.allMatches(url).length > pair.$1.allMatches(url).length) {
          url = url.substring(0, url.length - 1);
        }
      }
      final uri = Uri.tryParse(url);
      if (uri == null ||
          uri.scheme != 'https' ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty) {
        continue;
      }
      spans.add(TextSpan(text: widget.text.substring(end, match.start)));
      final recognizer = TapGestureRecognizer()..onTap = () => _open(uri);
      _recognizers.add(recognizer);
      spans.add(
        TextSpan(
          text: url,
          style: const TextStyle(decoration: TextDecoration.underline),
          recognizer: recognizer,
        ),
      );
      end = match.start + url.length;
    }
    spans.add(TextSpan(text: widget.text.substring(end)));
    return SelectableText.rich(TextSpan(style: widget.style, children: spans));
  }
}
