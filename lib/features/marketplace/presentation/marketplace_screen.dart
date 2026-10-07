import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/constants/firestore_paths.dart';
import '../../../core/errors/app_failure.dart';
import '../../../core/platform/platform_repository.dart';
import '../../../core/widgets/lily.dart';
import '../../../core/widgets/status_views.dart';
import '../../../core/widgets/user_name.dart';
import '../../auth/presentation/auth_controller.dart';
import '../../services/data/service_repository.dart';
import '../../services/domain/freelance_service.dart';
import '../data/people_search_repository.dart';
import '../domain/featured_session.dart';
import 'widgets/category_visuals.dart';
import 'widgets/featured_showcase_dialog.dart';
import 'widgets/service_card.dart';

/// Home. Opens with the student's name and a search box, then the
/// categories as tiles, a strip of featured listings, and the marketplace
/// itself. On a wide window the list becomes a grid.
class MarketplaceScreen extends StatefulWidget {
  const MarketplaceScreen({
    super.key,
    required this.repository,
    this.peopleSearchRepository,
    this.featuredSession,
  });

  final ServiceRepository repository;
  final FeaturedSession? featuredSession;
  final PeopleSearchRepository? peopleSearchRepository;

  @override
  State<MarketplaceScreen> createState() => _MarketplaceScreenState();
}

class _MarketplaceScreenState extends State<MarketplaceScreen>
    with WidgetsBindingObserver {
  final _scrollController = ScrollController();
  final _searchController = TextEditingController();

  ServiceRepository get _repository => widget.repository;

  List<FreelanceService> _services = [];
  List<FreelanceService> _featured = [];
  final List<FreelanceService> _featuredQueued = [];
  final List<int> _servicePageEnds = [];
  final Set<String> _featuredSellerIds = {};
  int _featuredPageIndex = 0;
  bool _featuredExhausted = false;
  bool _featuredLoading = false;
  String? _featuredError;
  late final _featuredSession = widget.featuredSession ?? FeaturedSession();
  Timer? _featuredTimer;
  bool _showcaseOpen = false;
  bool _featuredPrepared = false;
  Future<void> _featuredWrites = Future<void>.value();
  static const _featuredPreferenceKey = 'marketplace_featured_selection_v1';
  static const _showcaseSuppressionKey = 'featured_showcase_suppressed_until';
  bool _suppressionLoaded = false;
  int _featuredSessionSeed = Random.secure().nextInt(1 << 30);
  int _featuredGeneration = 0;
  bool _featuredInitialized = false;

  List<PeopleSearchResult> _people = [];
  bool _peopleLoading = false;
  bool _peopleUnavailable = false;
  DocumentSnapshot? _lastDocument;
  bool _loading = true;
  bool _servicesExhausted = false;
  String? _error;
  String? _pageError;
  int _generation = 0;
  String? _categoryId;
  String _query = '';
  ServiceSort _sort = ServiceSort.newest;
  bool? _cardMode;
  Future<void> _preferenceWrites = Future<void>.value();
  int _selectionRevision = 0;

  static const _categoryPreferenceKey = 'marketplace_category_id';
  static const _sortPreferenceKey = 'marketplace_sort';
  static const _cardModePreferenceKey = 'marketplace_card_mode';

  late final Stream<List<({String id, String label})>> _categories = context
      .read<PlatformSettingsRepository>()
      .watchCategories();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scrollController.addListener(_onScroll);
    _restorePreferencesAndLoad();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _rotateFeaturedIfExpired();
  }

  Future<void> _refreshMarketplace() async {
    await _rotateFeaturedIfExpired();
    await _loadFirstPage();
  }

  Future<void> _prepareFeatured() async {
    if (_featuredPrepared) return;
    if (!_featuredSession.isFresh(DateTime.now())) {
      try {
        final preferences = await SharedPreferences.getInstance();
        final raw = preferences.getString(_featuredPreferenceKey);
        if (raw != null) {
          final saved = jsonDecode(raw) as Map<String, Object?>;
          final selectedAt = DateTime.fromMillisecondsSinceEpoch(
            saved['selectedAt'] as int,
          );
          final age = DateTime.now().difference(selectedAt);
          if (!age.isNegative && age < FeaturedSession.rotationInterval) {
            final ids = (saved['ids'] as List<Object?>).cast<String>();
            final selected = await _repository.fetchFeaturedSelection(ids);
            _featuredSession
              ..selectedAt = selectedAt
              ..seed = saved['seed'] as int
              ..services = selected
              ..queued = []
              ..sellerIds = selected.map((service) => service.sellerId).toSet()
              ..pageIndex = 0
              ..exhausted = false;
          }
        }
      } on FormatException {
        // An invalid local cache can be replaced with a fresh rotation.
      } on TypeError {
        // Old or malformed preference data must not prevent browsing.
      } on Exception catch (failure) {
        if (failure is AppFailure || failure is FirebaseException) rethrow;
        // Preference storage can be unavailable; use the in-memory cache.
      }
    }
    if (!mounted) return;
    if (_featuredSession.isFresh(DateTime.now())) {
      _featuredSessionSeed = _featuredSession.seed;
      _featured = List.of(_featuredSession.services);
      _featuredQueued.addAll(_featuredSession.queued);
      _featuredSellerIds.addAll(_featuredSession.sellerIds);
      _featuredPageIndex = _featuredSession.pageIndex;
      _featuredExhausted = _featuredSession.exhausted;
    } else {
      _featuredSession
        ..selectedAt = DateTime.now()
        ..seed = _featuredSessionSeed
        ..services = []
        ..queued = []
        ..sellerIds = {}
        ..pageIndex = 0
        ..exhausted = false;
    }
    _featuredPrepared = true;
    _scheduleFeaturedRotation();
  }

  Future<void> _loadShowcaseSuppression() async {
    if (_suppressionLoaded) return;
    try {
      final preferences = await SharedPreferences.getInstance();
      final until = preferences.getInt(_showcaseSuppressionKey);
      if (until != null) {
        _featuredSession.suppressedUntil = DateTime.fromMillisecondsSinceEpoch(
          until,
        );
      }
    } on Exception {
      // If local storage is unavailable, retain this launch's in-memory state.
    }
    _suppressionLoaded = true;
  }

  Future<void> _setShowcaseSuppression(bool suppress) async {
    final until = suppress ? FeaturedSession.nextDay(DateTime.now()) : null;
    final preferences = await SharedPreferences.getInstance();
    final saved = until == null
        ? await preferences.remove(_showcaseSuppressionKey)
        : await preferences.setInt(
            _showcaseSuppressionKey,
            until.millisecondsSinceEpoch,
          );
    if (!saved) {
      throw const InvalidInputFailure(
        'Could not save this preference. Please try again.',
      );
    }
    _featuredSession.suppressedUntil = until;
  }

  void _scheduleFeaturedRotation() {
    _featuredTimer?.cancel();
    final selectedAt = _featuredSession.selectedAt;
    if (selectedAt == null) return;
    final remaining = selectedAt
        .add(FeaturedSession.rotationInterval)
        .difference(DateTime.now());
    _featuredTimer = Timer(
      remaining.isNegative ? Duration.zero : remaining,
      () {
        if (mounted && !_showcaseOpen) _rotateFeaturedIfExpired();
      },
    );
  }

  Future<void> _rotateFeaturedIfExpired() async {
    if (!mounted ||
        !_featuredPrepared ||
        _showcaseOpen ||
        _featuredSession.isFresh(DateTime.now())) {
      return;
    }
    setState(() {
      _featuredGeneration++;
      _featuredSessionSeed = Random.secure().nextInt(1 << 30);
      _featuredSession
        ..selectedAt = DateTime.now()
        ..seed = _featuredSessionSeed
        ..services = []
        ..queued = []
        ..sellerIds = {}
        ..pageIndex = 0
        ..exhausted = false;
      _featured = [];
      _featuredQueued.clear();
      _featuredSellerIds.clear();
      _featuredPageIndex = 0;
      _featuredExhausted = false;
      _featuredLoading = false;
      _featuredError = null;
    });
    _scheduleFeaturedRotation();
    await _loadInitialFeatured(_featuredGeneration);
  }

  void _cacheFeatured() {
    _featuredSession
      ..services = List.of(_featured)
      ..queued = List.of(_featuredQueued)
      ..sellerIds = Set.of(_featuredSellerIds)
      ..pageIndex = _featuredPageIndex
      ..exhausted = _featuredExhausted;
    if (_featured.isEmpty) return;
    final saved = jsonEncode({
      'selectedAt': _featuredSession.selectedAt!.millisecondsSinceEpoch,
      'seed': _featuredSessionSeed,
      'ids': _featured.take(5).map((service) => service.id).toList(),
    });
    _featuredWrites = _featuredWrites.then((_) async {
      try {
        final preferences = await SharedPreferences.getInstance();
        await preferences.setString(_featuredPreferenceKey, saved);
      } on Exception {
        // The in-memory selection still survives tab navigation.
      }
    });
  }

  Future<void> _restorePreferencesAndLoad() async {
    final revision = _selectionRevision;
    try {
      final preferences = await SharedPreferences.getInstance();
      final savedSort = preferences.getString(_sortPreferenceKey);
      var sort = ServiceSort.newest;
      for (final option in ServiceSort.values) {
        if (option.name == savedSort) {
          sort = option;
          break;
        }
      }
      if (!mounted || revision != _selectionRevision) return;
      setState(() {
        _categoryId = preferences.getString(_categoryPreferenceKey);
        _sort = sort;
        _cardMode = preferences.getBool(_cardModePreferenceKey);
      });
    } on Exception {
      // Continue with adaptive defaults if local preference storage is absent.
    }
    if (mounted && revision == _selectionRevision) await _loadFirstPage();
  }

  void _savePreferences() {
    final categoryId = _categoryId;
    final sort = _sort;
    final cardMode = _cardMode;
    _preferenceWrites = _preferenceWrites.then((_) async {
      try {
        final preferences = await SharedPreferences.getInstance();
        if (categoryId == null) {
          await preferences.remove(_categoryPreferenceKey);
        } else {
          await preferences.setString(_categoryPreferenceKey, categoryId);
        }
        await preferences.setString(_sortPreferenceKey, sort.name);
        if (cardMode == null) {
          await preferences.remove(_cardModePreferenceKey);
        } else {
          await preferences.setBool(_cardModePreferenceKey, cardMode);
        }
      } on Exception {
        // A preference write must not interrupt browsing.
      }
    });
  }

  void _onScroll() {
    if (_scrollController.position.pixels >
        _scrollController.position.maxScrollExtent - 400) {
      if (_pageError == null) _loadMore();
    }
  }

  Future<void> _loadFirstPage() async {
    final generation = ++_generation;
    final categoryId = _categoryId;
    final query = _query;
    if (query.length >= 2 && widget.peopleSearchRepository != null) {
      _searchPeople(query, generation);
    } else {
      _people = [];
      _peopleUnavailable = false;
      _peopleLoading = false;
    }
    setState(() {
      _loading = true;
      _error = null;
      _pageError = null;
      _services = [];
      _servicePageEnds.clear();
      _lastDocument = null;
      _servicesExhausted = false;
    });
    if (!_featuredInitialized) {
      _featuredInitialized = true;
      unawaited(_loadInitialFeatured(_featuredGeneration));
    }
    try {
      final page = await _fetchVisibleServices(
        categoryId: categoryId,
        search: query.isEmpty ? null : query,
        sort: _sort,
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        _servicePageEnds
          ..clear()
          ..add(page.items.length);
        _services = page.items;
        _lastDocument = page.lastDocument;
        _servicesExhausted = page.exhausted;
        _loading = false;
      });
    } catch (failure) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _loading = false;
        _error = AppFailure.from(failure).message;
      });
    }
  }

  Future<void> _searchPeople(String query, int generation) async {
    setState(() {
      _peopleLoading = true;
      _peopleUnavailable = false;
      _people = [];
    });
    try {
      final people = await widget.peopleSearchRepository!.search(query);
      if (!mounted || generation != _generation) return;
      setState(() {
        _people = people;
        _peopleLoading = false;
      });
    } on Exception {
      if (!mounted || generation != _generation) return;
      setState(() {
        _people = [];
        _peopleLoading = false;
        _peopleUnavailable = true;
      });
    }
  }

  /// Pull past featured-only pages in the normal query until regular services
  /// are found or the collection is exhausted. The featured
  /// carousel owns those placements, so a newest page made entirely of
  /// featured listings must not leave the marketplace looking empty.
  Future<ServicePage> _fetchVisibleServices({
    String? categoryId,
    String? search,
    required ServiceSort sort,
    DocumentSnapshot? startAfter,
  }) async {
    final services = <FreelanceService>[];
    var cursor = startAfter;
    var exhausted = false;
    do {
      final page = await _repository.fetchPublished(
        categoryId: categoryId,
        search: search,
        sort: sort,
        startAfter: cursor,
      );
      services.addAll(
        page.items.where(
          (service) => search?.isNotEmpty == true || !service.isFeatured,
        ),
      );
      cursor = page.lastDocument ?? cursor;
      exhausted = page.exhausted;
    } while (services.length < ServiceRepository.pageSize && !exhausted);

    return ServicePage(
      items: services,
      lastDocument: cursor,
      exhausted: exhausted,
    );
  }

  Future<void> _maybeShowFeaturedShowcase(
    List<FreelanceService> services,
  ) async {
    if (!_featuredSession.canShowShowcase(DateTime.now()) ||
        services.isEmpty ||
        !mounted ||
        !(ModalRoute.of(context)?.isCurrent ?? true)) {
      return;
    }
    _featuredSession.showcaseShown = true;
    _showcaseOpen = true;
    final selected = await showDialog<FreelanceService>(
      context: context,
      builder: (_) => FeaturedShowcaseDialog(
        services: services,
        onSuppressTodayChanged: _setShowcaseSuppression,
        hasMore: () => !_featuredExhausted || _featuredQueued.isNotEmpty,
        onLoadMore: () async {
          await _loadMoreFeatured(targetCount: _featured.length + 5);
          if (_featuredError != null) {
            throw InvalidInputFailure(_featuredError!);
          }
          return List<FreelanceService>.of(_featured);
        },
      ),
    );
    _showcaseOpen = false;
    await _rotateFeaturedIfExpired();
    if (selected != null && mounted) {
      await context.push('/service/${selected.id}');
    }
  }

  Future<void> _loadInitialFeatured(int generation) async {
    try {
      await _loadShowcaseSuppression();
      await _prepareFeatured();
    } catch (failure) {
      if (mounted) {
        setState(() => _featuredError = AppFailure.from(failure).message);
      }
      return;
    }
    if (!mounted || generation != _featuredGeneration) return;
    await _loadMoreFeatured(targetCount: 5);
    if (!mounted || generation != _featuredGeneration) return;
    await _maybeShowFeaturedShowcase(_featured.take(5).toList());
  }

  Future<void> _loadMoreFeatured({required int targetCount}) async {
    if (_featuredLoading || (_featuredExhausted && _featuredQueued.isEmpty)) {
      return;
    }
    _featuredLoading = true;
    _featuredError = null;
    if (mounted) setState(() {});
    final generation = _featuredGeneration;
    final sellers = Set<String>.of(_featuredSellerIds);
    final added = <FreelanceService>[];
    final queued = List<FreelanceService>.of(_featuredQueued);
    var pageIndex = _featuredPageIndex;
    var exhausted = _featuredExhausted;
    try {
      while (_featured.length + added.length < targetCount) {
        if (queued.isNotEmpty) {
          final needed = targetCount - _featured.length - added.length;
          final used = needed < queued.length ? needed : queued.length;
          added.addAll(queued.take(used));
          queued.removeRange(0, used);
          continue;
        }
        if (exhausted) break;
        final page = await _repository.fetchFeatured(
          pageIndex: pageIndex,
          sessionSeed: _featuredSessionSeed,
          excludedSellerIds: sellers,
        );
        pageIndex++;
        exhausted = page.exhausted;
        sellers.addAll(page.items.map((service) => service.sellerId));
        final needed = targetCount - _featured.length - added.length;
        added.addAll(page.items.take(needed));
        queued.addAll(page.items.skip(needed));
      }
      if (!mounted || generation != _featuredGeneration) return;
      setState(() {
        _featured.addAll(added);
        _featuredQueued
          ..clear()
          ..addAll(queued);
        _featuredSellerIds
          ..clear()
          ..addAll(sellers);
        _featuredPageIndex = pageIndex;
        _featuredExhausted = exhausted;
      });
      _cacheFeatured();
    } catch (failure) {
      if (!mounted || generation != _featuredGeneration) return;
      setState(() => _featuredError = AppFailure.from(failure).message);
    } finally {
      if (generation == _featuredGeneration) {
        _featuredLoading = false;
        if (mounted) setState(() {});
      }
    }
  }

  Future<void> _loadMore() async {
    if (_loading || _servicesExhausted) return;
    final generation = _generation;
    setState(() {
      _loading = true;
      _pageError = null;
    });
    try {
      final page = await _fetchVisibleServices(
        categoryId: _categoryId,
        search: _query.isEmpty ? null : _query,
        sort: _sort,
        startAfter: _lastDocument,
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        _services.addAll(page.items);
        _servicePageEnds.add(_services.length);
        _lastDocument = page.lastDocument ?? _lastDocument;
        _servicesExhausted = page.exhausted;
        _loading = false;
      });
    } catch (failure) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _loading = false;
        _pageError = AppFailure.from(failure).message;
      });
    }
  }

  void _submitSearch(String value) {
    _query = value.trim();
    _loadFirstPage();
  }

  void _pickCategory(String? id) {
    if (id == _categoryId) return;
    _selectionRevision++;
    setState(() => _categoryId = id);
    _savePreferences();
    _loadFirstPage();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _featuredTimer?.cancel();
    _scrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final wide = MediaQuery.sizeOf(context).width >= Breakpoints.tablet;
    final columns = Breakpoints.columns(context, minTile: 360);
    // Keep the familiar adaptive default until the student explicitly picks
    // a view. On a phone that is a list; on a wide display it is cards.
    final cardMode = _cardMode ?? columns > 1;

    final organic = _services;

    return Scaffold(
      body: RefreshIndicator(
        onRefresh: _refreshMarketplace,
        child: CustomScrollView(
          controller: _scrollController,
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverToBoxAdapter(
              child: _Header(
                controller: _searchController,
                onSearch: _submitSearch,
                query: _query,
                onClear: () {
                  _searchController.clear();
                  _submitSearch('');
                },
              ),
            ),
            SliverToBoxAdapter(
              child: _CategoryStrip(
                stream: _categories,
                selected: _categoryId,
                onSelected: _pickCategory,
              ),
            ),
            SliverToBoxAdapter(
              child: _FeaturedStrip(
                services: _featured.take(5).toList(),
                loading: _featuredLoading && _featured.isEmpty,
                error: _featuredError,
                hasMore: false,
                onLoadMore: () => _featured.isEmpty
                    ? _loadInitialFeatured(_featuredGeneration)
                    : _loadMoreFeatured(targetCount: _featured.length + 3),
              ),
            ),
            if (_query.length >= 2 && widget.peopleSearchRepository != null)
              SliverToBoxAdapter(
                child: _PeopleResults(
                  people: _people,
                  loading: _peopleLoading,
                  unavailable: _peopleUnavailable,
                ),
              ),
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  wide ? 24 : 20,
                  8,
                  wide ? 24 : 12,
                  4,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _query.isNotEmpty
                          ? 'Services'
                          : _categoryId == null
                          ? 'All services'
                          : categoryLabelOf(_categoryId!),
                      style: theme.textTheme.titleLarge,
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        Flexible(
                          child: _SortMenu(
                            sort: _sort,
                            onChanged: (sort) {
                              if (sort == _sort) return;
                              _selectionRevision++;
                              setState(() => _sort = sort);
                              _savePreferences();
                              _loadFirstPage();
                            },
                          ),
                        ),
                        IconButton(
                          tooltip: cardMode
                              ? 'Show list view'
                              : 'Show card view',
                          icon: Icon(
                            cardMode
                                ? Icons.view_agenda_outlined
                                : Icons.grid_view_rounded,
                          ),
                          onPressed: () {
                            _selectionRevision++;
                            setState(() => _cardMode = !cardMode);
                            _savePreferences();
                          },
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            ..._results(organic, _featured, wide, columns, cardMode),
          ],
        ),
      ),
    );
  }

  List<Widget> _results(
    List<FreelanceService> organic,
    List<FreelanceService> featured,
    bool wide,
    int columns,
    bool cardMode,
  ) {
    if (_error != null && _services.isEmpty) {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: ErrorView(message: _error!, onRetry: _loadFirstPage),
        ),
      ];
    }
    if (_loading && _services.isEmpty) {
      return const [
        SliverToBoxAdapter(child: SkeletonList(count: 3, height: 128)),
      ];
    }
    if (organic.isEmpty && featured.isEmpty) {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: EmptyView(
            icon: _query.isEmpty
                ? Icons.storefront_outlined
                : Icons.search_off_rounded,
            title: _query.isEmpty
                ? 'Nothing here yet'
                : 'No services found for "$_query"',
            message: _query.isEmpty
                ? (_categoryId == null
                      ? 'Be the first: publish a service from the Me tab.'
                      : 'No published listings in this category yet.')
                : 'Try a different word, or choose someone from People above.',
            actionLabel: _query.isEmpty && _categoryId != null
                ? 'Show all'
                : null,
            onAction: () => _pickCategory(null),
          ),
        ),
      ];
    }
    final padding = EdgeInsets.fromLTRB(wide ? 24 : 16, 8, wide ? 24 : 16, 24);
    final organicIds = {for (final service in organic) service.id};
    final slivers = <Widget>[];
    var pageStart = 0;
    for (var pageIndex = 0; pageIndex < _servicePageEnds.length; pageIndex++) {
      final pageEnd = _servicePageEnds[pageIndex];
      final pageOrganic = [
        for (final service in _services.sublist(pageStart, pageEnd))
          if (organicIds.contains(service.id)) service,
      ];
      if (pageOrganic.isNotEmpty) {
        slivers.add(
          SliverPadding(
            padding: padding,
            sliver: !cardMode
                ? SliverList.separated(
                    itemCount: pageOrganic.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 10),
                    itemBuilder: (context, i) => ServiceCard(
                      service: pageOrganic[i],
                      margin: EdgeInsets.zero,
                    ),
                  )
                : SliverGrid(
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: wide ? (columns < 2 ? 2 : columns) : 2,
                      mainAxisSpacing: 12,
                      crossAxisSpacing: 12,
                      mainAxisExtent:
                          220 * MediaQuery.textScalerOf(context).scale(14) / 14,
                    ),
                    delegate: SliverChildBuilderDelegate(
                      (context, i) => ServiceCard(
                        service: pageOrganic[i],
                        margin: EdgeInsets.zero,
                        compact: true,
                      ),
                      childCount: pageOrganic.length,
                    ),
                  ),
          ),
        );
      }
      pageStart = pageEnd;
    }
    return [
      ...slivers,
      if (!_servicesExhausted)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Center(
              child: _loading
                  ? const CircularProgressIndicator()
                  : Column(
                      children: [
                        if (_pageError != null) ...[
                          Text(_pageError!, textAlign: TextAlign.center),
                          const SizedBox(height: 8),
                        ],
                        TextButton.icon(
                          onPressed: _loadMore,
                          icon: Icon(
                            _pageError == null
                                ? Icons.expand_more_rounded
                                : Icons.refresh_rounded,
                          ),
                          label: Text(
                            _pageError == null
                                ? 'Load more services'
                                : 'Retry loading services',
                          ),
                        ),
                      ],
                    ),
            ),
          ),
        ),
    ];
  }
}

/// Greeting, notifications, and the search box on the lily gradient.
class _PeopleResults extends StatelessWidget {
  const _PeopleResults({
    required this.people,
    required this.loading,
    required this.unavailable,
  });

  final List<PeopleSearchResult> people;
  final bool loading;
  final bool unavailable;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('People', style: theme.textTheme.titleLarge),
          const SizedBox(height: 8),
          if (loading)
            const LinearProgressIndicator()
          else if (unavailable)
            const Text(
              'People search is temporarily unavailable. Service results are still shown.',
            )
          else if (people.isEmpty)
            Text(
              'No people match this search.',
              style: theme.textTheme.bodySmall,
            )
          else
            Card(
              child: Column(
                children: [
                  for (final (index, person) in people.indexed) ...[
                    if (index > 0) const Divider(height: 1),
                    ListTile(
                      leading: UserAvatar(
                        name: person.displayName,
                        photoUrl: person.photoUrl,
                      ),
                      title: Text(person.displayName),
                      subtitle: Text(
                        [
                          if (person.program?.isNotEmpty == true)
                            person.program!,
                          if (person.department?.isNotEmpty == true)
                            person.department!,
                        ].join(' · '),
                      ),
                      trailing: person.publicRole == null
                          ? null
                          : Chip(label: Text(person.publicRole!)),
                      onTap: () => context.push('/user/${person.uid}'),
                    ),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.controller,
    required this.onSearch,
    required this.query,
    required this.onClear,
  });

  final TextEditingController controller;
  final ValueChanged<String> onSearch;
  final String query;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final name = context.watch<AuthController>().profile?.displayName;
    final first = (name ?? '').trim().split(' ').first;
    final hour = DateTime.now().hour;
    final greeting = hour < 12
        ? 'Good morning'
        : hour < 18
        ? 'Good afternoon'
        : 'Good evening';
    return PageHero(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const LilyMark(size: 36, onHero: true),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  first.isEmpty ? greeting : '$greeting, $first',
                  style: OnHero.title.copyWith(fontSize: 22),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              IconButton(
                tooltip: 'Notifications',
                icon: const Icon(
                  Icons.notifications_none_rounded,
                  color: Colors.white,
                ),
                onPressed: () => context.push('/notifications'),
              ),
            ],
          ),
          const SizedBox(height: 6),
          const Text(
            'Find a classmate for the job, or get hired for yours.',
            style: OnHero.subtitle,
          ),
          const SizedBox(height: 16),
          TextField(
            controller: controller,
            textInputAction: TextInputAction.search,
            onSubmitted: onSearch,
            style: const TextStyle(fontSize: 15),
            decoration: InputDecoration(
              hintText: 'Search tutors, designers, editors…',
              prefixIcon: const Icon(Icons.search_rounded),
              fillColor: Theme.of(context).colorScheme.surfaceContainerLowest,
              filled: true,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(999),
                borderSide: BorderSide.none,
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(999),
                borderSide: BorderSide.none,
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(999),
                borderSide: const BorderSide(color: Colors.white, width: 2),
              ),
              suffixIcon: query.isNotEmpty
                  ? IconButton(
                      tooltip: 'Clear search',
                      icon: const Icon(Icons.close_rounded),
                      onPressed: onClear,
                    )
                  : null,
            ),
          ),
        ],
      ),
    );
  }
}

/// Categories as tiles: an icon in its own colour with the label beneath.
class _CategoryStrip extends StatelessWidget {
  const _CategoryStrip({
    required this.stream,
    required this.selected,
    required this.onSelected,
  });

  final Stream<List<({String id, String label})>> stream;
  final String? selected;
  final ValueChanged<String?> onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return StreamBuilder<List<({String id, String label})>>(
      stream: stream,
      builder: (context, snapshot) {
        final categories =
            snapshot.data ??
            PlatformSettingsRepository.mergeCategories(const []);
        return SizedBox(
          height: 90 + MediaQuery.textScalerOf(context).scale(36),
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
            children: [
              _CategoryTile(
                label: 'All',
                icon: Icons.grid_view_rounded,
                tint: theme.colorScheme.primary,
                selected: selected == null,
                onTap: () => onSelected(null),
              ),
              for (final category in categories)
                _CategoryTile(
                  label: category.label,
                  icon: categoryVisualOf(
                    category.id,
                    brightness: theme.brightness,
                  ).icon,
                  tint: categoryVisualOf(
                    category.id,
                    brightness: theme.brightness,
                  ).tint,
                  selected: selected == category.id,
                  onTap: () => onSelected(category.id),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _CategoryTile extends StatelessWidget {
  const _CategoryTile({
    required this.label,
    required this.icon,
    required this.tint,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final Color tint;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(right: 10),
      child: Semantics(
        button: true,
        selected: selected,
        child: Tooltip(
          message: label,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(AppTheme.radiusControl),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              width: 108 * MediaQuery.textScalerOf(context).scale(12.5) / 12.5,
              padding: const EdgeInsets.symmetric(vertical: 8),
              decoration: BoxDecoration(
                color: selected
                    ? tint.withValues(alpha: 0.14)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(AppTheme.radiusControl),
                border: Border.all(
                  color: selected
                      ? tint.withValues(alpha: 0.5)
                      : Colors.transparent,
                ),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconDisc(icon: icon, tint: tint, size: 40),
                  const SizedBox(height: 6),
                  Text(
                    label,
                    maxLines: 2,
                    textAlign: TextAlign.center,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: selected
                          ? tint
                          : theme.colorScheme.onSurfaceVariant,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Paid placements, labelled as such, as a horizontal strip.
class _FeaturedStrip extends StatelessWidget {
  const _FeaturedStrip({
    required this.services,
    required this.loading,
    required this.hasMore,
    required this.onLoadMore,
    this.error,
  });

  final List<FreelanceService> services;
  final bool loading;
  final bool hasMore;
  final VoidCallback onLoadMore;
  final String? error;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(20, 14, 20, 8),
          child: SectionHeader(
            'Featured',
            subtitle: 'Pinned by Pro sellers',
            padding: EdgeInsets.zero,
          ),
        ),
        if (services.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
            child: loading
                ? const LinearProgressIndicator()
                : Text(error ?? 'No active featured listings right now.'),
          )
        else
          SizedBox(
            height: 240 * MediaQuery.textScalerOf(context).scale(14) / 14,
            child: NotificationListener<ScrollNotification>(
              onNotification: (notification) {
                if (notification.metrics.axis == Axis.horizontal &&
                    notification.metrics.maxScrollExtent > 0 &&
                    notification.metrics.extentAfter < 300 &&
                    hasMore &&
                    !loading) {
                  onLoadMore();
                }
                return false;
              },
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                itemCount: services.length + (loading ? 1 : 0),
                separatorBuilder: (_, _) => const SizedBox(width: 10),
                itemBuilder: (context, i) {
                  if (i == services.length) {
                    return const SizedBox(
                      width: 48,
                      child: Center(child: CircularProgressIndicator()),
                    );
                  }
                  return SizedBox(
                    width: 300,
                    child: ServiceCard(
                      service: services[i],
                      margin: EdgeInsets.zero,
                      featured: true,
                    ),
                  );
                },
              ),
            ),
          ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: TextButton(
              onPressed: loading ? null : onLoadMore,
              child: const Text('Retry featured listings'),
            ),
          ),
      ],
    );
  }
}

class _SortMenu extends StatelessWidget {
  const _SortMenu({required this.sort, required this.onChanged});

  final ServiceSort sort;
  final ValueChanged<ServiceSort> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PopupMenuButton<ServiceSort>(
      tooltip: 'Sort',
      initialValue: sort,
      onSelected: onChanged,
      itemBuilder: (context) => [
        for (final option in ServiceSort.values)
          PopupMenuItem(value: option, child: Text(option.label)),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.swap_vert_rounded,
              size: 18,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                sort.label,
                style: theme.textTheme.labelLarge?.copyWith(
                  color: theme.colorScheme.primary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
