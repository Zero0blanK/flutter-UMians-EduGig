'use strict';

const { FEATURED_PER_PAGE: SLOT_COUNT } = require('./policy');

function rotationScopeId(categoryId) {
  if (categoryId == null || categoryId === '') return 'all';
  return `category_${Buffer.from(categoryId, 'utf8').toString('base64url')}`;
}

function rotationPageId(scopeId, pageIndex) {
  return `${scopeId}__page_${pageIndex}`;
}

function buildFeaturedRotations(services, hourIndex) {
  const scopes = new Map([['all', { categoryId: null, services: [] }]]);
  for (const service of services) {
    scopes.get('all').services.push(service);
    if (typeof service.categoryId !== 'string' || !service.categoryId) continue;
    const scopeId = rotationScopeId(service.categoryId);
    if (!scopes.has(scopeId)) {
      scopes.set(scopeId, { categoryId: service.categoryId, services: [] });
    }
    scopes.get(scopeId).services.push(service);
  }

  const rotations = {};
  for (const [scopeId, scope] of scopes) {
    const bySeller = new Map();
    for (const service of scope.services) {
      const sellerId = service.sellerId || service.id;
      if (!bySeller.has(sellerId)) bySeller.set(sellerId, []);
      bySeller.get(sellerId).push(service.id);
    }
    const sellers = [...bySeller.keys()].sort();
    const orderedServiceIds = [];
    if (sellers.length > 0) {
      const start = ((hourIndex % sellers.length) + sellers.length) % sellers.length;
      const rotationCycle = Math.floor(hourIndex / sellers.length);
      for (let slot = 0; slot < sellers.length; slot++) {
        const seller = sellers[(start + slot) % sellers.length];
        const listings = bySeller.get(seller).sort();
        orderedServiceIds.push(listings[rotationCycle % listings.length]);
      }
    }
    const pageCount = Math.max(1, Math.ceil(orderedServiceIds.length / SLOT_COUNT));
    for (let pageIndex = 0; pageIndex < pageCount; pageIndex++) {
      rotations[rotationPageId(scopeId, pageIndex)] = {
        scope: scopeId === 'all' ? 'all' : 'category',
        categoryId: scope.categoryId,
        pageIndex,
        pageCount,
        sellerCount: orderedServiceIds.length,
        serviceIds: orderedServiceIds.slice(
          pageIndex * SLOT_COUNT,
          (pageIndex + 1) * SLOT_COUNT,
        ),
      };
    }
  }
  return rotations;
}

function activeFeatured(service, nowMillis) {
  const until = service?.featuredUntil;
  const untilMillis = typeof until?.toMillis === 'function'
    ? until.toMillis()
    : until instanceof Date
      ? until.getTime()
      : null;
  return service?.status === 'published' && untilMillis != null && untilMillis > nowMillis;
}

function featuredPoolChanged(before, after, nowMillis) {
  const beforeActive = activeFeatured(before, nowMillis);
  const afterActive = activeFeatured(after, nowMillis);
  if (beforeActive !== afterActive) return true;
  return beforeActive && afterActive && (
    before.sellerId !== after.sellerId || before.categoryId !== after.categoryId
  );
}

module.exports = {
  SLOT_COUNT,
  activeFeatured,
  buildFeaturedRotations,
  featuredPoolChanged,
  rotationPageId,
  rotationScopeId,
};
