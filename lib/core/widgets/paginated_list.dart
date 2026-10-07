import 'dart:async';

import 'package:flutter/material.dart';

import '../errors/app_failure.dart';
import 'status_views.dart';

/// Expands a live query window as the reader approaches its end. One extra
/// record distinguishes a full final page from a page with more records.
/// Keeping a single window preserves updates and avoids gaps when records
/// move between pages after status changes.
class PaginatedList<T> extends StatefulWidget {
  const PaginatedList({
    super.key,
    required this.load,
    required this.itemBuilder,
    required this.emptyMessage,
    this.header,
    this.headerBuilder,
    this.pageSize = 50,
  });

  final Stream<List<T>> Function(int limit) load;
  final Widget Function(BuildContext context, T item) itemBuilder;
  final String emptyMessage;
  final Widget? header;
  final Widget Function(BuildContext context, List<T> items)? headerBuilder;
  final int pageSize;

  @override
  State<PaginatedList<T>> createState() => _PaginatedListState<T>();
}

class _PaginatedListState<T> extends State<PaginatedList<T>> {
  final _controller = ScrollController();
  StreamSubscription<List<T>>? _subscription;
  List<T> _items = [];
  late int _limit = widget.pageSize;
  bool _loading = true;
  bool _hasMore = false;
  String? _error;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onScroll);
    _listen();
  }

  void _listen() {
    final generation = ++_generation;
    _subscription?.cancel();
    _subscription = widget
        .load(_limit + 1)
        .listen(
          (items) {
            if (!mounted || generation != _generation) return;
            setState(() {
              _items = items.take(_limit).toList();
              _hasMore = items.length > _limit;
              _loading = false;
              _error = null;
            });
          },
          onError: (Object failure) {
            if (!mounted || generation != _generation) return;
            setState(() {
              _loading = false;
              _error = AppFailure.from(failure).message;
            });
          },
        );
  }

  void _onScroll() {
    if (_controller.position.extentAfter < 300 && _error == null) _loadMore();
  }

  void _loadMore() {
    if (_loading || !_hasMore) return;
    setState(() {
      _loading = true;
      _limit += widget.pageSize;
    });
    _listen();
  }

  void _retry() {
    setState(() {
      _loading = true;
      _error = null;
    });
    _listen();
  }

  @override
  void dispose() {
    _generation++;
    _subscription?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final header = widget.headerBuilder?.call(context, _items) ?? widget.header;
    if (_items.isEmpty && header == null) {
      if (_loading) return const LoadingView();
      if (_error != null) return ErrorView(message: _error!, onRetry: _retry);
      return EmptyView(message: widget.emptyMessage);
    }
    final headerCount = header == null ? 0 : 1;
    final footer = _loading || _hasMore || _error != null || _items.isEmpty;
    return ListView.builder(
      controller: _controller,
      padding: const EdgeInsets.all(16),
      itemCount: headerCount + _items.length + (footer ? 1 : 0),
      itemBuilder: (context, index) {
        if (headerCount == 1 && index == 0) return header!;
        final itemIndex = index - headerCount;
        if (itemIndex < _items.length) {
          return widget.itemBuilder(context, _items[itemIndex]);
        }
        if (_loading) {
          return const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        if (_error != null) {
          return TextButton(onPressed: _retry, child: Text('$_error Retry'));
        }
        if (_items.isEmpty) return EmptyView(message: widget.emptyMessage);
        return TextButton(onPressed: _loadMore, child: const Text('Load more'));
      },
    );
  }
}
