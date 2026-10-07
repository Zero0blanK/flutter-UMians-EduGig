import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/errors/app_failure.dart';
import '../../../core/utils/feedback.dart';
import '../../services/data/service_repository.dart';
import '../../services/domain/freelance_service.dart';
import '../data/offer_repository.dart';
import '../domain/offer.dart';

/// The freelancer writes down what was agreed in chat and sends it as a
/// card. Defaults come from the chosen listing; every figure can be changed
/// to what the conversation settled on.
class SendOfferDialog extends StatefulWidget {
  const SendOfferDialog({
    super.key,
    required this.freelancerId,
    required this.clientId,
  });

  final String freelancerId;
  final String clientId;

  @override
  State<SendOfferDialog> createState() => _SendOfferDialogState();
}

class _SendOfferDialogState extends State<SendOfferDialog> {
  final _formKey = GlobalKey<FormState>();
  final _price = TextEditingController();
  final _days = TextEditingController();
  final _revisions = TextEditingController();
  final _scope = TextEditingController();
  late final Stream<List<FreelanceService>> _services;
  FreelanceService? _service;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _services = context.read<ServiceRepository>().watchPublishedBySeller(
      widget.freelancerId,
    );
  }

  @override
  void dispose() {
    _price.dispose();
    _days.dispose();
    _revisions.dispose();
    _scope.dispose();
    super.dispose();
  }

  void _pick(FreelanceService? service) {
    setState(() {
      _service = service;
      if (service != null) {
        _price.text = '${service.startingPrice}';
        _days.text = '${service.deliveryDays}';
        _revisions.text = '${service.revisionCount}';
      }
    });
  }

  Future<void> _send() async {
    final service = _service;
    if (service == null || !_formKey.currentState!.validate()) return;
    setState(() => _sending = true);
    try {
      await context.read<OfferRepository>().send(
        service: service,
        freelancerId: widget.freelancerId,
        clientId: widget.clientId,
        price: int.parse(_price.text.trim()),
        deliveryDays: int.parse(_days.text.trim()),
        revisionCount: int.parse(_revisions.text.trim()),
        scope: _scope.text,
      );
      if (mounted) Navigator.pop(context, true);
    } on AppFailure catch (failure) {
      if (mounted) showFailureSnackBar(context, failure);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  String? _intIn(String? value, int min, int max, String label) {
    final n = int.tryParse(value ?? '');
    return n != null && n >= min && n <= max ? null : label;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('Send an offer'),
      content: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              StreamBuilder<List<FreelanceService>>(
                stream: _services,
                builder: (context, snapshot) {
                  final services = snapshot.data ?? const <FreelanceService>[];
                  if (snapshot.hasData && services.isEmpty) {
                    return Text(
                      'Publish a listing first; an offer is always for one.',
                      style: theme.textTheme.bodySmall,
                    );
                  }
                  return DropdownButtonFormField<FreelanceService>(
                    initialValue: _service,
                    decoration: const InputDecoration(labelText: 'Listing'),
                    items: [
                      for (final service in services)
                        DropdownMenuItem(
                          value: service,
                          child: Text(
                            service.title,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: _pick,
                    validator: (value) =>
                        value == null ? 'Choose a listing' : null,
                  );
                },
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _price,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'Price (₱)'),
                      validator: (v) =>
                          _intIn(v, 1, 1000000, '₱1 – ₱1,000,000'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextFormField(
                      controller: _days,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'Days'),
                      validator: (v) => _intIn(v, 1, 90, '1 – 90'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextFormField(
                      controller: _revisions,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'Revisions'),
                      validator: (v) => _intIn(v, 0, 10, '0 – 10'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _scope,
                minLines: 3,
                maxLines: 6,
                maxLength: Offer.maxScopeLength,
                decoration: const InputDecoration(
                  labelText: 'Scope',
                  hintText: 'What exactly you will deliver, as agreed in chat',
                ),
                validator: (v) =>
                    (v ?? '').trim().length >= Offer.minScopeLength
                    ? null
                    : 'At least ${Offer.minScopeLength} characters',
              ),
              const SizedBox(height: 4),
              Text(
                'The client accepts this card to place the order at this '
                'price. The listing\'s starting price is not used. Valid for '
                '${Offer.validity.inDays} days.',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _sending || _service == null ? null : _send,
          child: const Text('Send offer'),
        ),
      ],
    );
  }
}
