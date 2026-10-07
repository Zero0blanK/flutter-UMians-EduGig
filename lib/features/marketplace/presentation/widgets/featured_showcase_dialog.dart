import 'package:flutter/material.dart';

import '../../../../app/theme/app_theme.dart';
import '../../../../core/constants/firestore_paths.dart';
import '../../../../core/widgets/lily.dart';
import '../../../../core/widgets/user_name.dart';
import '../../../../core/errors/app_failure.dart';
import '../../../services/domain/freelance_service.dart';
import 'category_visuals.dart';

/// A dismissible launch carousel for the same first batch as the marketplace.
class FeaturedShowcaseDialog extends StatefulWidget {
  const FeaturedShowcaseDialog({
    super.key,
    required this.services,
    this.onLoadMore,
    this.hasMore,
    this.onSuppressTodayChanged,
  });

  final List<FreelanceService> services;
  final Future<List<FreelanceService>> Function()? onLoadMore;
  final bool Function()? hasMore;
  final Future<void> Function(bool)? onSuppressTodayChanged;

  @override
  State<FeaturedShowcaseDialog> createState() => _FeaturedShowcaseDialogState();
}

class _FeaturedShowcaseDialogState extends State<FeaturedShowcaseDialog> {
  final _controller = PageController();
  int _page = 0;
  late List<FreelanceService> _services = List.of(widget.services);
  bool _loading = false;
  String? _error;
  bool _suppressToday = false;
  bool _savingPreference = false;
  String? _preferenceError;

  Future<void> _changeSuppression(bool value) async {
    if (_savingPreference) return;
    setState(() {
      _savingPreference = true;
      _preferenceError = null;
    });
    try {
      await widget.onSuppressTodayChanged?.call(value);
      if (mounted) setState(() => _suppressToday = value);
    } catch (failure) {
      if (mounted) {
        setState(() => _preferenceError = AppFailure.from(failure).message);
      }
    } finally {
      if (mounted) setState(() => _savingPreference = false);
    }
  }

  bool get _hasMore => widget.hasMore?.call() ?? false;

  Future<void> _loadMore() async {
    if (_loading || !_hasMore || widget.onLoadMore == null) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final services = await widget.onLoadMore!();
      if (!mounted) return;
      setState(() {
        _services = services;
        if (!_hasMore && _page >= _services.length && _services.isNotEmpty) {
          _page = _services.length - 1;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && _controller.hasClients) {
              _controller.jumpToPage(_page);
            }
          });
        }
      });
    } catch (failure) {
      if (mounted) setState(() => _error = AppFailure.from(failure).message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final availableHeight = MediaQuery.sizeOf(context).height * 0.9;
    final selected = _page < _services.length ? _services[_page] : null;
    return Dialog(
      insetPadding: const EdgeInsets.all(20),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 460, maxHeight: availableHeight),
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Featured for you',
                        style: theme.textTheme.titleLarge,
                      ),
                    ),
                    IconButton(
                      tooltip: 'Close showcase',
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Discover services from fellow students',
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  height: 286 * MediaQuery.textScalerOf(context).scale(14) / 14,
                  child: PageView.builder(
                    controller: _controller,
                    itemCount: _services.length + (_hasMore ? 1 : 0),
                    onPageChanged: (page) {
                      setState(() => _page = page);
                      if (page >= _services.length - 2 && _error == null) {
                        _loadMore();
                      }
                    },
                    itemBuilder: (context, index) {
                      if (index >= _services.length) {
                        return Center(
                          child: _loading
                              ? const CircularProgressIndicator()
                              : TextButton(
                                  onPressed: _loadMore,
                                  child: Text(
                                    _error == null
                                        ? 'More featured services'
                                        : 'Retry featured listings',
                                  ),
                                ),
                        );
                      }
                      final service = _services[index];
                      final visual = categoryVisualOf(
                        service.categoryId,
                        brightness: theme.brightness,
                      );
                      return Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 2),
                        child: Card(
                          clipBehavior: Clip.antiAlias,
                          child: InkWell(
                            onTap: () => Navigator.of(context).pop(service),
                            child: Padding(
                              padding: const EdgeInsets.all(20),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  IconDisc(
                                    icon: visual.icon,
                                    tint: visual.tint,
                                    size: 58,
                                  ),
                                  const SizedBox(height: 16),
                                  Text(
                                    categoryLabelOf(service.categoryId),
                                    style: theme.textTheme.labelLarge?.copyWith(
                                      color: theme.colorScheme.primary,
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    service.title,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.titleLarge,
                                  ),
                                  const Spacer(),
                                  Row(
                                    children: [
                                      UserAvatarFor(
                                        uid: service.sellerId,
                                        radius: 16,
                                        ring: visual.tint,
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: UserName(
                                          uid: service.sellerId,
                                          style: theme.textTheme.bodyMedium,
                                        ),
                                      ),
                                      Text(
                                        '₱${service.startingPrice}',
                                        style: AppTheme.price(
                                          context,
                                          size: 17,
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    service.description,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.bodySmall,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
                if (_services.length > 1) ...[
                  const SizedBox(height: 12),
                  Text(
                    '${_page + 1} / ${_services.length}${_hasMore ? '+' : ''}',
                  ),
                ],
                if (_error != null) Text(_error!),
                if (widget.onSuppressTodayChanged != null)
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    title: const Text("Don't show again today"),
                    subtitle: const Text('Resets tomorrow'),
                    value: _suppressToday,
                    onChanged: _savingPreference
                        ? null
                        : (value) => _changeSuppression(value ?? false),
                  ),
                if (_preferenceError != null) Text(_preferenceError!),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: selected == null
                        ? null
                        : () => Navigator.of(context).pop(selected),
                    child: const Text('View service'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
