/** Shared featured demo fixtures and projection refresh for seed.js. */
'use strict';

const {
  activeFeatured,
  buildFeaturedRotations,
  rotationScopeId,
} = require('../../functions/featured-rotation');

const PREFIX = 'featured_demo_';
const FIXTURE_COUNT = 100;

function featuredFixture(index, admin) {
  const number = String(index).padStart(3, '0');
  const uid = `${PREFIX}seller_${number}`;
  const serviceId = `${PREFIX}service_${number}`;
  const now = Date.now();
  // Keep demo placements out of the newest regular-results pages. The
  // Featured carousel uses its own fair rotation, independent of listing age.
  const createdAt = admin.firestore.Timestamp.fromMillis(
    now - 120 * 86400000,
  );
  const expiresAt = admin.firestore.Timestamp.fromMillis(now + 30 * 86400000);
  return {
    uid,
    serviceId,
    user: {
      uid,
      displayName: `Featured Demo ${number}`,
      email: `f.demo.${String(900000 + index)}@umindanao.edu.ph`,
      collegeId: 'cce',
      program: 'BS Information Technology',
      bio: 'A verified Pro seller fixture for testing fair featured rotation.',
      skills: ['Design', 'Student services'],
      identityVerified: true,
      proUntil: expiresAt,
      birthDate: admin.firestore.Timestamp.fromDate(new Date('2000-01-01T00:00:00Z')),
      createdAt,
    },
    service: {
      sellerId: uid,
      title: `Featured demo service ${number}`,
      titleLower: `featured demo service ${number}`,
      description: 'A fixture listing used to test the marketplace featured showcase and rotation.',
      categoryId: 'other',
      skills: ['Design', 'Student services'],
      keywords: ['featured', 'demo', 'service', number],
      startingPrice: 250 + index,
      pricingMode: 'fixed',
      requiresContact: false,
      currency: 'PHP',
      deliveryDays: 3,
      revisionCount: 1,
      status: 'published',
      ratingSum: 0,
      ratingCount: 0,
      featuredUntil: expiresAt,
      createdAt,
      updatedAt: createdAt,
    },
  };
}

async function seedFeaturedFixtures(db, admin, track) {
  const fixtures = Array.from(
    { length: FIXTURE_COUNT },
    (_, index) => featuredFixture(index + 1, admin),
  );
  for (let offset = 0; offset < fixtures.length; offset += 200) {
    const batch = db.batch();
    for (const fixture of fixtures.slice(offset, offset + 200)) {
      batch.set(db.doc(`users/${fixture.uid}`), fixture.user);
      batch.set(db.doc(`services/${fixture.serviceId}`), fixture.service);
      track('users', fixture.uid);
      track('services', fixture.serviceId);
    }
    await batch.commit();
  }
  console.log(`  ${FIXTURE_COUNT} verified Pro featured sellers`);
}

async function refreshFeaturedRotations(db, admin) {
  const now = admin.firestore.Timestamp.now();
  const snapshot = await db.collection('services')
    .where('status', '==', 'published')
    .where('featuredUntil', '>', now)
    .orderBy('featuredUntil', 'desc')
    .get();
  const services = snapshot.docs
    .map((doc) => ({ ...doc.data(), id: doc.id }))
    .filter((service) => activeFeatured(service, now.toMillis()));
  const hourIndex = Math.floor(Date.now() / 3600000);
  const rotations = buildFeaturedRotations(services, hourIndex);
  const updates = new Map(Object.entries(rotations));
  for (const rotation of Object.values(rotations)) {
    if (rotation.pageIndex !== 0) continue;
    updates.set(rotationScopeId(
      rotation.scope === 'all' ? null : rotation.categoryId,
    ), rotation);
  }

  const collection = db.collection('featuredRotations');
  const existing = await collection.get();
  for (const doc of existing.docs) {
    if (!updates.has(doc.id)) {
      updates.set(doc.id, {
        scope: doc.data().scope || (doc.id.startsWith('all__') ? 'all' : 'category'),
        categoryId: doc.data().categoryId || null,
        pageIndex: doc.data().pageIndex ?? 0,
        pageCount: 1,
        serviceIds: [],
      });
    }
  }
  const entries = [...updates.entries()];
  for (let offset = 0; offset < entries.length; offset += 450) {
    const batch = db.batch();
    for (const [id, rotation] of entries.slice(offset, offset + 450)) {
      batch.set(collection.doc(id), {
        ...rotation,
        windowHour: hourIndex,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    }
    await batch.commit();
  }
  console.log(`  featured rotations refreshed for ${services.length} listings`);
}

module.exports = { refreshFeaturedRotations, seedFeaturedFixtures };
