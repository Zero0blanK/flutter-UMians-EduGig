'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const {
  activeFeatured,
  buildFeaturedRotations,
  featuredPoolChanged,
  rotationPageId,
  rotationScopeId,
} = require('./featured-rotation');

function listing(id, sellerId, categoryId = 'design', featuredUntil = new Date(10_000)) {
  return { id, sellerId, categoryId, status: 'published', featuredUntil };
}

test('100 sellers receive equal top-strip exposure and are paged through in groups of three', () => {
  const services = Array.from({ length: 100 }, (_, i) => listing(`service-${i}`, `seller-${i}`));
  const topCounts = new Map(services.map((service) => [service.sellerId, 0]));
  for (let hour = 0; hour < services.length; hour++) {
    const rotations = buildFeaturedRotations(services, hour);
    const firstPage = rotations[rotationPageId('all', 0)].serviceIds;
    assert.equal(firstPage.length, 3);
    firstPage.forEach((id) => {
      const service = services.find((candidate) => candidate.id === id);
      topCounts.set(service.sellerId, topCounts.get(service.sellerId) + 1);
    });

    const seenSellers = new Set();
    const pageIds = Object.entries(rotations)
      .filter(([id]) => id.startsWith('all__page_'))
      .sort((a, b) => Number(a[1].pageIndex) - Number(b[1].pageIndex));
    for (const [, page] of pageIds) {
      assert.equal(page.pageCount, pageIds.length);
      assert.ok(page.serviceIds.length <= 3);
      const sellers = page.serviceIds.map((id) =>
        services.find((service) => service.id === id).sellerId,
      );
      assert.equal(new Set(sellers).size, sellers.length);
      sellers.forEach((seller) => seenSellers.add(seller));
    }
    assert.equal(seenSellers.size, services.length);
  }
  assert.deepEqual([...new Set(topCounts.values())], [3]);
});

test('a seller with multiple listings rotates them with equal exposure', () => {
  const services = [listing('a1', 'seller-a'), listing('a2', 'seller-a'), listing('b', 'seller-b')];
  const counts = new Map([['a1', 0], ['a2', 0]]);
  for (let hour = 0; hour < 12; hour++) {
    const id = buildFeaturedRotations(services, hour)[rotationPageId('all', 0)]
      .serviceIds.find((serviceId) => serviceId.startsWith('a'));
    counts.set(id, counts.get(id) + 1);
  }
  assert.deepEqual([...counts.values()], [6, 6]);
});

test('category projections contain only that category and remain deterministic', () => {
  const services = [listing('b', 'seller-b', 'writing'), listing('a', 'seller-a', 'design')];
  const forward = buildFeaturedRotations(services, 42);
  const reversed = buildFeaturedRotations([...services].reverse(), 42);
  assert.deepEqual(forward, reversed);
  assert.deepEqual(forward[rotationPageId(rotationScopeId('writing'), 0)].serviceIds, ['b']);
  assert.deepEqual(forward[rotationPageId(rotationScopeId('design'), 0)].serviceIds, ['a']);
  assert.equal(rotationScopeId(null), 'all');
});

test('active pool detects eligibility, seller, and category changes only', () => {
  const current = listing('a', 'seller-a', 'design');
  assert.equal(activeFeatured(current, 1_000), true);
  assert.equal(activeFeatured({ ...current, status: 'draft' }, 1_000), false);
  assert.equal(activeFeatured({ ...current, featuredUntil: new Date(1_000) }, 1_000), false);
  assert.equal(featuredPoolChanged(undefined, current, 1_000), true);
  assert.equal(featuredPoolChanged(current, { ...current, title: 'Renamed' }, 1_000), false);
  assert.equal(featuredPoolChanged(current, { ...current, sellerId: 'seller-b' }, 1_000), true);
  assert.equal(featuredPoolChanged(current, { ...current, categoryId: 'writing' }, 1_000), true);
});

test('an empty pool still produces a clear global projection', () => {
  assert.deepEqual(buildFeaturedRotations([], 1), {
    all__page_0: {
      scope: 'all',
      categoryId: null,
      pageIndex: 0,
      pageCount: 1,
      sellerCount: 0,
      serviceIds: [],
    },
  });
});
