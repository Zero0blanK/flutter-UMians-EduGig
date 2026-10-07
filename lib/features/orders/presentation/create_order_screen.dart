import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/errors/app_failure.dart';
import '../../../core/utils/feedback.dart';
import '../../../core/widgets/content_width.dart';
import '../../../core/widgets/lily.dart';
import '../../../core/widgets/status_views.dart';
import '../../../core/widgets/user_name.dart';
import '../../auth/presentation/auth_controller.dart';
import '../../marketplace/presentation/widgets/service_card.dart';
import '../../services/data/service_repository.dart';
import '../../services/domain/freelance_service.dart';
import '../data/order_repository.dart';

/// The one form between a listing and an order: what the buyer needs.
///
/// The listing is fetched here rather than passed through the route, so
/// the summary at the top is the seller's real title and price, and the
/// same trusted document is used inside the creation transaction.
class CreateOrderScreen extends StatefulWidget {
  const CreateOrderScreen({super.key, required this.serviceId});

  final String serviceId;

  @override
  State<CreateOrderScreen> createState() => _CreateOrderScreenState();
}

class _CreateOrderScreenState extends State<CreateOrderScreen> {
  final _formKey = GlobalKey<FormState>();
  final _requirementsController = TextEditingController();
  late Future<FreelanceService> _service;
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    _service = context.read<ServiceRepository>().fetchById(widget.serviceId);
  }

  @override
  void dispose() {
    _requirementsController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate() || _submitting) return;
    final orderRepository = context.read<OrderRepository>();
    final serviceRepository = context.read<ServiceRepository>();
    final buyerId = context.read<AuthController>().uid!;
    setState(() => _submitting = true);
    try {
      // The service is re-fetched and its trusted values are used inside the
      // creation transaction, so UI-supplied prices can never be persisted.
      final service = await serviceRepository.fetchById(widget.serviceId);
      final orderId = await orderRepository.create(
        service: service,
        buyerId: buyerId,
        requirements: _requirementsController.text,
      );
      if (mounted) {
        context.go('/order/$orderId');
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Request sent. The seller has been notified.'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } on AppFailure catch (failure) {
      if (mounted) {
        setState(() => _submitting = false);
        showFailureSnackBar(context, failure);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FutureBuilder<FreelanceService>(
      future: _service,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Scaffold(
            appBar: AppBar(title: const Text('New order')),
            body: ErrorView(
              message: snapshot.error is AppFailure
                  ? '${snapshot.error}'
                  : 'Could not load this service.',
              onRetry: () => setState(() {
                _service = context.read<ServiceRepository>().fetchById(
                  widget.serviceId,
                );
              }),
            ),
          );
        }
        final service = snapshot.data;
        if (service == null) {
          return Scaffold(
            appBar: AppBar(title: const Text('New order')),
            body: const LoadingView(),
          );
        }
        final price =
            '₱${NumberFormat.decimalPattern().format(service.startingPrice)}';
        return Scaffold(
          appBar: AppBar(title: const Text('New order')),
          body: ContentWidth(
            child: Form(
              key: _formKey,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                children: [
                  LilyPanel(
                    padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                    child: Row(
                      children: [
                        CategoryDisc(categoryId: service.categoryId, size: 44),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                service.title,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.titleMedium,
                              ),
                              const SizedBox(height: 2),
                              UserName(
                                uid: service.sellerId,
                                prefix: 'by ',
                                style: theme.textTheme.bodySmall,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                  StatGrid(
                    minTile: 100,
                    tiles: [
                      StatTile(
                        label: 'Price',
                        value: price,
                        icon: Icons.sell_outlined,
                        emphasis: true,
                      ),
                      StatTile(
                        label: 'Delivery',
                        value:
                            '${service.deliveryDays} day${service.deliveryDays == 1 ? '' : 's'}',
                        icon: Icons.schedule_rounded,
                        caption: 'once started',
                      ),
                      StatTile(
                        label: 'Revisions',
                        value: '${service.revisionCount}',
                        icon: Icons.replay_rounded,
                      ),
                    ],
                  ),
                  const SectionHeader(
                    'What do you need?',
                    subtitle:
                        'The seller reads this before accepting. Be specific.',
                  ),
                  LilyPanel(
                    child: TextFormField(
                      controller: _requirementsController,
                      autofocus: true,
                      decoration: const InputDecoration(
                        labelText: 'Requirements',
                        hintText:
                            'Scope, files you will provide, deadlines, '
                            'references, anything that would change the job.',
                        alignLabelWithHint: true,
                      ),
                      minLines: 6,
                      maxLines: 12,
                      maxLength: 4000,
                      textCapitalization: TextCapitalization.sentences,
                      validator: (value) =>
                          value != null && value.trim().length >= 10
                          ? null
                          : 'At least 10 characters',
                    ),
                  ),
                  const SectionHeader('What happens next'),
                  LilyPanel(
                    padding: const EdgeInsets.fromLTRB(18, 14, 18, 14),
                    child: Column(
                      children: [
                        for (final (i, step) in const [
                          (
                            Icons.send_rounded,
                            'The seller accepts or declines your request.',
                          ),
                          (
                            Icons.lock_outline_rounded,
                            'You pay in the app. The money is held, not sent.',
                          ),
                          (
                            Icons.check_circle_outline_rounded,
                            'You approve the delivery, and only then is the seller paid.',
                          ),
                        ].indexed)
                          Padding(
                            padding: EdgeInsets.only(bottom: i == 2 ? 0 : 10),
                            child: Row(
                              children: [
                                IconDisc(icon: step.$1, size: 32),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Text(
                                    step.$2,
                                    style: theme.textTheme.bodyMedium,
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          bottomNavigationBar: StickyActionBar(
            child: ContentWidth(
              child: Row(
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Nothing charged yet',
                        style: theme.textTheme.labelMedium,
                      ),
                      Text(price, style: AppTheme.price(context, size: 22)),
                    ],
                  ),
                  const Spacer(),
                  FilledButton.icon(
                    onPressed: _submitting ? null : _submit,
                    icon: _submitting
                        ? const SizedBox(
                            height: 18,
                            width: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.send_rounded),
                    label: Text(_submitting ? 'Sending…' : 'Send request'),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
