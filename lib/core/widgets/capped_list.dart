import 'package:flutter/material.dart';

/// A page of results plus whether the query hit its ceiling.
///
/// Several streams here read a fixed number of documents and returned a plain
/// list. Past that ceiling records simply vanished from the UI with nothing to
/// indicate it — the same failure mode as the earnings total that silently
/// summed only the first page. Carrying [truncated] alongside the items means
/// a screen can say so out loud.
class CappedList<T> {
  const CappedList({required this.items, required this.truncated});

  const CappedList.complete(this.items) : truncated = false;

  final List<T> items;

  /// True when the underlying query returned as many documents as it asked
  /// for, so older records exist but were not fetched.
  final bool truncated;

  int get length => items.length;
  bool get isEmpty => items.isEmpty;
  bool get isNotEmpty => items.isNotEmpty;
}

/// Footer shown under a list that was cut short by its query limit.
class TruncationNotice extends StatelessWidget {
  const TruncationNotice({super.key, required this.shown, required this.noun});

  final int shown;
  final String noun;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
      child: Row(
        children: [
          Icon(
            Icons.history_toggle_off,
            size: 15,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Showing your $shown most recent $noun. Older ones are not '
              'listed here.',
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}
