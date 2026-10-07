import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../../core/constants/firestore_paths.dart';
import '../../../core/errors/app_failure.dart';
import '../../../core/platform/platform_repository.dart';
import '../../../core/utils/feedback.dart';
import '../../../core/widgets/content_width.dart';
import '../../../core/widgets/lily.dart';
import '../../../core/widgets/status_views.dart';
import '../../auth/presentation/auth_controller.dart';
import '../data/service_repository.dart';
import '../domain/freelance_service.dart';

/// Create/edit form for the seller's own services. `serviceId` is null for
/// creation. Ownership and immutable fields are re-enforced by security rules.
class EditServiceScreen extends StatefulWidget {
  const EditServiceScreen({super.key, this.serviceId});

  final String? serviceId;

  @override
  State<EditServiceScreen> createState() => _EditServiceScreenState();
}

class _EditServiceScreenState extends State<EditServiceScreen> {
  final _formKey = GlobalKey<FormState>();
  final _titleController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _priceController = TextEditingController();
  final _daysController = TextEditingController();
  final _revisionsController = TextEditingController();
  PricingMode _pricingMode = PricingMode.fixed;
  bool _requiresContact = false;
  final _skillsController = TextEditingController();

  String _categoryId = kServiceCategories.first.id;
  late final Stream<List<({String id, String label})>> _categories = context
      .read<PlatformSettingsRepository>()
      .watchCategories();
  bool _loadingExisting = true;
  bool _submitting = false;
  bool get _isNew => widget.serviceId == null;

  @override
  void initState() {
    super.initState();
    _loadExisting();
  }

  Future<void> _loadExisting() async {
    if (_isNew) {
      setState(() => _loadingExisting = false);
      return;
    }
    try {
      final service = await context.read<ServiceRepository>().fetchById(
        widget.serviceId!,
      );
      if (!mounted) return;
      _titleController.text = service.title;
      _descriptionController.text = service.description;
      _priceController.text = '${service.startingPrice}';
      _daysController.text = '${service.deliveryDays}';
      _revisionsController.text = '${service.revisionCount}';
      _pricingMode = service.pricingMode;
      _requiresContact = service.requiresContact;
      _skillsController.text = service.skills.join(', ');
      setState(() {
        _categoryId = service.categoryId;
        _loadingExisting = false;
      });
    } on AppFailure catch (failure) {
      if (mounted) {
        setState(() => _loadingExisting = false);
        showFailureSnackBar(context, failure);
      }
    }
  }

  @override
  void dispose() {
    for (final controller in [
      _titleController,
      _descriptionController,
      _priceController,
      _daysController,
      _revisionsController,
      _skillsController,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate() || _submitting) return;
    final profile = context.read<AuthController>().profile;
    if (_isNew && !(profile?.isAdult ?? false)) {
      showFailureSnackBar(
        context,
        const InvalidInputFailure(
          'Selling is open to students aged 18 and over. Add your birth date '
          'in Edit profile before creating a service.',
        ),
      );
      return;
    }
    final repository = context.read<ServiceRepository>();
    final sellerId = context.read<AuthController>().uid!;
    final existing = !_isNew
        ? await repository.fetchById(widget.serviceId!)
        : null;

    setState(() => _submitting = true);
    final service = FreelanceService(
      id: widget.serviceId ?? repository.newServiceId(),
      sellerId: existing?.sellerId ?? sellerId,
      title: _titleController.text.trim(),
      description: _descriptionController.text.trim(),
      categoryId: _categoryId,
      skills: _parseSkills(_skillsController.text),
      startingPrice: int.tryParse(_priceController.text.trim()) ?? 0,
      currency: 'PHP',
      deliveryDays: int.tryParse(_daysController.text.trim()) ?? 0,
      revisionCount: int.tryParse(_revisionsController.text.trim()) ?? 0,
      status: existing?.status ?? ServiceStatus.draft,
      createdAt: existing?.createdAt ?? DateTime.now(),
      updatedAt: DateTime.now(),
      // Preserved from the loaded document; a seller edit must leave the
      // score and the backend's featured flag exactly where they were or
      // security rules reject the write.
      ratingSum: existing?.ratingSum ?? 0,
      ratingCount: existing?.ratingCount ?? 0,
      featuredUntil: existing?.featuredUntil,
      pricingMode: _pricingMode,
      requiresContact: _requiresContact,
    );

    try {
      await repository.save(service, isNew: _isNew);
      if (mounted) context.pop();
    } on AppFailure catch (failure) {
      if (mounted) showFailureSnackBar(context, failure);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  List<String> _parseSkills(String raw) => raw
      .split(',')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty && s.length <= 24)
      .take(8)
      .toList();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final canCreateService =
        context.watch<AuthController>().profile?.isAdult ?? false;
    return Scaffold(
      appBar: AppBar(title: Text(_isNew ? 'New service' : 'Edit service')),
      body: _loadingExisting
          ? const LoadingView()
          : ContentWidth(
              child: Form(
                key: _formKey,
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                  children: [
                    if (_isNew && !canCreateService) ...[
                      LilyPanel(
                        tint: theme.colorScheme.error,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Complete seller eligibility',
                              style: theme.textTheme.titleSmall,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Selling is open to students aged 18 and over. '
                              'Add your birth date once in your profile to '
                              'create a service.',
                              style: theme.textTheme.bodySmall,
                            ),
                            const SizedBox(height: 10),
                            OutlinedButton.icon(
                              onPressed: () => context.push('/profile/edit'),
                              icon: const Icon(Icons.edit_outlined),
                              label: const Text('Add birth date'),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                    ],
                    const SectionHeader(
                      'What you offer',
                      padding: EdgeInsets.fromLTRB(0, 8, 0, 10),
                    ),
                    LilyPanel(
                      child: Column(
                        children: [
                          TextFormField(
                            controller: _titleController,
                            decoration: const InputDecoration(
                              labelText: 'Title',
                              hintText: 'Logo design for student orgs',
                            ),
                            maxLength: 80,
                            textCapitalization: TextCapitalization.sentences,
                            validator: (value) =>
                                value != null && value.trim().isNotEmpty
                                ? null
                                : 'Enter a title',
                          ),
                          const SizedBox(height: 8),
                          // Staff-managed categories merged over the built-in
                          // list. A listing already in a retired category
                          // keeps it, so the current id is always among the
                          // choices.
                          StreamBuilder<List<({String id, String label})>>(
                            stream: _categories,
                            builder: (context, snapshot) {
                              final categories = [
                                ...snapshot.data ??
                                    PlatformSettingsRepository.mergeCategories(
                                      const [],
                                    ),
                              ];
                              if (!categories.any((c) => c.id == _categoryId)) {
                                categories.add((
                                  id: _categoryId,
                                  label: categoryLabelOf(_categoryId),
                                ));
                              }
                              return DropdownButtonFormField<String>(
                                initialValue: _categoryId,
                                decoration: const InputDecoration(
                                  labelText: 'Category',
                                ),
                                items: [
                                  for (final category in categories)
                                    DropdownMenuItem(
                                      value: category.id,
                                      child: Text(category.label),
                                    ),
                                ],
                                onChanged: (value) => setState(
                                  () => _categoryId = value ?? _categoryId,
                                ),
                              );
                            },
                          ),
                          const SizedBox(height: 16),
                          TextFormField(
                            controller: _descriptionController,
                            decoration: const InputDecoration(
                              labelText: 'Description',
                              hintText:
                                  'What you will deliver, what you need from '
                                  'the client, and what is not included.',
                              alignLabelWithHint: true,
                            ),
                            minLines: 5,
                            maxLines: 10,
                            maxLength: 4000,
                            textCapitalization: TextCapitalization.sentences,
                            validator: (value) =>
                                value != null && value.trim().length >= 20
                                ? null
                                : 'At least 20 characters',
                          ),
                          const SizedBox(height: 8),
                          TextFormField(
                            controller: _skillsController,
                            decoration: const InputDecoration(
                              labelText: 'Skills',
                              helperText: 'Comma-separated, up to eight.',
                              hintText: 'Figma, Illustrator, branding',
                            ),
                            textCapitalization: TextCapitalization.words,
                          ),
                        ],
                      ),
                    ),
                    const SectionHeader('Price and delivery'),
                    LilyPanel(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            flex: 3,
                            child: TextFormField(
                              controller: _priceController,
                              decoration: InputDecoration(
                                labelText: _pricingMode == PricingMode.fixed
                                    ? 'Price'
                                    : 'Starting price',
                                prefixText: '₱ ',
                              ),
                              keyboardType: TextInputType.number,
                              validator: (value) {
                                final price = int.tryParse(value ?? '');
                                return price != null &&
                                        price >= 1 &&
                                        price <= 1000000
                                    ? null
                                    : '₱1 to ₱1,000,000';
                              },
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            flex: 2,
                            child: TextFormField(
                              controller: _daysController,
                              decoration: const InputDecoration(
                                labelText: 'Days',
                              ),
                              keyboardType: TextInputType.number,
                              validator: (value) {
                                final days = int.tryParse(value ?? '');
                                return days != null && days >= 1 && days <= 90
                                    ? null
                                    : '1 to 90';
                              },
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            flex: 2,
                            child: TextFormField(
                              controller: _revisionsController,
                              decoration: const InputDecoration(
                                labelText: 'Revisions',
                              ),
                              keyboardType: TextInputType.number,
                              validator: (value) {
                                final revisions = int.tryParse(value ?? '');
                                return revisions != null &&
                                        revisions >= 0 &&
                                        revisions <= 10
                                    ? null
                                    : '0 to 10';
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SectionHeader('How ordering works'),
                    LilyPanel(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          SegmentedButton<PricingMode>(
                            segments: const [
                              ButtonSegment(
                                value: PricingMode.fixed,
                                label: Text('Fixed price'),
                                icon: Icon(Icons.sell_outlined),
                              ),
                              ButtonSegment(
                                value: PricingMode.negotiable,
                                label: Text('Starting price'),
                                icon: Icon(Icons.forum_outlined),
                              ),
                            ],
                            selected: {_pricingMode},
                            showSelectedIcon: false,
                            onSelectionChanged: (selection) =>
                                setState(() => _pricingMode = selection.first),
                          ),
                          const SizedBox(height: 10),
                          Text(
                            _pricingMode == PricingMode.fixed
                                ? 'The price above is the price. Clients can '
                                      'order it directly unless you ask to be '
                                      'contacted first.'
                                : 'The price above is a starting point for the '
                                      'smallest job. Clients message you, you '
                                      'agree on scope and price in chat, and you '
                                      'send an offer card they accept before '
                                      'paying. Direct ordering is off.',
                            style: theme.textTheme.bodySmall,
                          ),
                          const SizedBox(height: 4),
                          SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            title: const Text('Talk to me before ordering'),
                            subtitle: Text(
                              _pricingMode == PricingMode.negotiable
                                  ? 'Always on for a starting price.'
                                  : 'Clients must message you first; you then '
                                        'send an offer card at the listed price '
                                        'or another one.',
                            ),
                            value:
                                _pricingMode == PricingMode.negotiable ||
                                _requiresContact,
                            onChanged: _pricingMode == PricingMode.negotiable
                                ? null
                                : (value) =>
                                      setState(() => _requiresContact = value),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 24),
                    FilledButton.icon(
                      icon: const Icon(Icons.save_outlined),
                      label: Text(
                        _submitting
                            ? 'Saving…'
                            : _isNew
                            ? 'Save as draft'
                            : 'Save changes',
                      ),
                      onPressed: _submitting || (_isNew && !canCreateService)
                          ? null
                          : _submit,
                    ),
                    if (_isNew) ...[
                      const SizedBox(height: 8),
                      Text(
                        'Drafts are private. Publish from My services when it '
                        'is ready.',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ],
                ),
              ),
            ),
    );
  }
}
