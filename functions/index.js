/**
 * Cloud Functions entry point (Blaze plan).
 *
 *   api                     the Express app in server.js, as one HTTPS function
 *   onNotificationCreated   push every inbox notification to the user's devices
 *   onOrderStatusChanged    release or refund held money when an order ends
 *   autoCompleteOrders      complete deliveries the client ignored (scheduled)
 *   reconcilePayments       settle checkouts whose callback never came (scheduled)
 *   flagDormantWallets      balances whose owner stopped signing in (scheduled)
 *
 * The same Express app also runs standalone via `node server.js` on any host,
 * so moving between Cloud Functions and a container host is a deployment
 * choice, not a rewrite. The triggers and the schedule only exist here.
 */
const { onRequest } = require('firebase-functions/v2/https');
const {
  onDocumentCreated,
  onDocumentUpdated,
  onDocumentWritten,
} = require('firebase-functions/v2/firestore');
const { onSchedule } = require('firebase-functions/v2/scheduler');
const { beforeUserCreated, beforeUserSignedIn, HttpsError } = require('firebase-functions/v2/identity');
const { isUmEmail } = require('./policy');
const { setGlobalOptions } = require('firebase-functions/v2');
const admin = require('firebase-admin');
const { publicIdentityKey } = require('./public-identity');
const {
  activeFeatured,
  buildFeaturedRotations,
  featuredPoolChanged,
  rotationScopeId,
} = require('./featured-rotation');

const { createApp } = require('./server');
const ledger = require('./ledger');
const xendit = require('./xendit');
const { pushNotification, writeNotification, notifyAdmins } = require('./push');
const audit = require('./audit');

// Guarded: Cloud Functions may load this module more than once per instance,
// and a second initializeApp() throws.
if (!admin.apps.length) admin.initializeApp();

const REGION = 'asia-southeast1';
setGlobalOptions({ region: REGION, maxInstances: 10 });

const db = admin.firestore();

function normalizeSearch(value) {
  return String(value || '').normalize('NFKD').replace(/[\u0300-\u036f]/g, '')
    .toLowerCase().trim().replace(/\s+/g, ' ');
}

async function syncPublicUser(uid, profile) {
  const access = await db.doc(`admins/${uid}`).get();
  const adminData = access.exists ? access.data() : null;
  const role = adminData?.role === 'admin' ? 'Admin'
    : adminData?.role === 'staff' && (adminData.permissions || []).some((p) =>
      p === 'services.moderate' || p === 'users.manage') ? 'Moderator' : null;
  const userRef = db.doc(`users/${uid}`);
  if (profile.publicRole !== role) {
    await userRef.update({ publicRole: role });
  }
  const projection = db.doc(`publicUserSearch/${uid}`);
  if (profile.suspended === true) {
    await projection.delete();
    return;
  }
  const departments = {
    cce: 'College of Computing Education',
    case: 'College of Arts and Sciences Education',
    cbae: 'College of Business Administration Education',
    cae: 'College of Accounting Education',
    cee: 'College of Engineering Education',
    cte: 'College of Teacher Education',
    chse: 'College of Health Sciences Education',
  };
  const department = departments[profile.collegeId] || '';
  await projection.set({
    identityKey: publicIdentityKey(profile, uid),
    displayName: profile.displayName || 'Student',
    nameLower: normalizeSearch(profile.displayName),
    program: profile.program || '',
    programLower: normalizeSearch(profile.program),
    department,
    departmentLower: normalizeSearch(department),
    departmentCodeLower: normalizeSearch(profile.collegeId),
    photoUrl: profile.photoUrl || null,
    createdAt: profile.createdAt || admin.firestore.Timestamp.now(),
    publicRole: role,
    suspended: false,
  });
}

/** The dependency bundle every module takes. Built lazily so secrets, which
 *  are only injected into functions that declare them, are read at call time. */
function deps() {
  return {
    db,
    verifyIdToken: (token) => admin.auth().verifyIdToken(token),
    serverTimestamp: () => admin.firestore.FieldValue.serverTimestamp(),
    increment: (n) => admin.firestore.FieldValue.increment(n),
    now: () => new Date(),
    fetchImpl: globalThis.fetch,
    deleteFile: (path) => admin.storage().bucket().file(path).delete(),
    logger: console,
  };
}

const GATEWAY_SECRETS = ['XENDIT_SECRET_KEY', 'XENDIT_CALLBACK_TOKEN'];

exports.api = onRequest(
  {
    secrets: GATEWAY_SECRETS,
    // A payment request should fail fast rather than hold a slot open.
    timeoutSeconds: 60,
    memory: '256MiB',
  },
  // Built on first request rather than at load: configFromEnv() reads the
  // secrets, and they are not present while the module is merely analysed.
  (() => {
    let app;
    return (req, res) => {
      app ??= createApp(deps());
      return app(req, res);
    };
  })(),
);

/**
 * Push for every notification document, whoever wrote it. The client writes
 * most of them (validated by rules); the backend writes the money ones.
 */
exports.onNotificationCreated = onDocumentCreated(
  'users/{uid}/notifications/{notificationId}',
  async (event) => {
    const data = event.data?.data();
    if (!data) return;
    try {
      await pushNotification(
        { db, messaging: admin.messaging(), logger: console },
        {
          uid: event.params.uid,
          notificationId: event.params.notificationId,
          notification: data,
        },
      );
    } catch (error) {
      // A push failure is not a notification failure: the inbox row exists.
      console.error('push failed', { uid: event.params.uid, message: error.message });
    }
  },
);

/**
 * The hold-and-release step of the revenue model.
 *
 * `completed` releases the freelancer's net to their wallet; `cancelled` and
 * `rejected` refund the client through the gateway. Both are no-ops for
 * manual settlements and for orders that were never paid, and both are safe
 * to re-run: the ledger only moves money that is still `held`.
 */
exports.onOrderStatusChanged = onDocumentUpdated(
  { document: 'orders/{orderId}', secrets: GATEWAY_SECRETS },
  async (event) => {
    const before = event.data?.before.data();
    const after = event.data?.after.data();
    if (!before || !after || before.status === after.status) return;
    const orderId = event.params.orderId;
    const d = deps();

    await audit.writeAudit(d, {
      actorId: after.autoCompleted && after.status === 'completed' ? 'system' : 'participant',
      action: audit.ACTIONS.orderStatusChanged,
      targetType: 'order',
      targetId: orderId,
      details: {
        before: before.status,
        after: after.status,
        price: after.price,
        clientId: after.clientId,
        freelancerId: after.freelancerId,
      },
    });

    if (after.status === 'completed') {
      const outcome = await ledger.releaseHeldPayment(d, orderId);
      if (outcome === 'released' || outcome === 'released-clearing') {
        await writeNotification(d, after.freelancerId, {
          type: 'payment.released',
          title: outcome === 'released'
            ? `${after.serviceTitle}: payment released to your balance`
            : `${after.serviceTitle}: payment released, clearing for 7 days`,
          orderId,
        });
        await audit.writeAudit(d, {
          actorId: 'system',
          action: audit.ACTIONS.paymentReleased,
          targetType: 'payment',
          targetId: orderId,
          details: { freelancerId: after.freelancerId, outcome },
        });
      }
      return;
    }

    if (after.status === 'cancelled' || after.status === 'rejected') {
      const { configFromEnv } = require('./server');
      const config = configFromEnv();
      const outcome = await ledger.refundHeldPayment(
        {
          ...d,
          refundImpl: ({ paymentId, amount, reason, referenceId }) =>
            xendit.createRefund(
              { invoiceId: paymentId, amountPesos: amount, reason, referenceId },
              { fetchImpl: globalThis.fetch, config },
            ),
        },
        orderId,
        'REQUESTED_BY_CUSTOMER',
      );
      if (outcome === 'refunded') {
        await writeNotification(d, after.clientId, {
          type: 'payment.refunded',
          title: `${after.serviceTitle}: your payment was refunded`,
          orderId,
        });
        await audit.writeAudit(d, {
          actorId: 'system',
          action: audit.ACTIONS.paymentRefunded,
          targetType: 'payment',
          targetId: orderId,
          details: { clientId: after.clientId, via: 'gateway' },
        });
      } else if (outcome === 'refund-failed' || outcome === 'manual-required') {
        console.error('refund needs staff attention', { orderId, outcome });
        await notifyAdmins(d, {
          type: 'admin.refund_attention',
          title: `${after.serviceTitle}: a refund needs staff attention`,
          orderId,
        });
      }
    }
  },
);

/**
 * Every six hours: a delivery ignored for three days completes itself, the
 * clients whose window closes within a day are reminded, and releases whose
 * clearance period has passed become available.
 */
exports.autoCompleteOrders = onSchedule(
  { schedule: 'every 6 hours', timeZone: 'Asia/Manila' },
  async () => {
    const d = deps();
    const now = new Date();
    const { completed, reminded } = await ledger.autoCompleteStaleOrders(
      { ...d, notify: (uid, payload) => writeNotification(d, uid, payload) },
      now,
    );
    const cleared = await ledger.clearSettledFunds(d, now);
    if (completed || reminded || cleared) {
      console.log('scheduled jobs', { completed, reminded, cleared });
    }
  },
);

/**
 * Daily: balances whose owners have not signed in for DORMANT_WALLET_DAYS
 * are flagged, the student is told, and staff are asked to reach out.
 * Authentication's own last-refresh time is the signal, so no profile field
 * has to be kept in step with sign-ins.
 */
exports.flagDormantWallets = onSchedule(
  { schedule: 'every day 03:00', timeZone: 'Asia/Manila' },
  async () => {
    const d = deps();
    const outcome = await ledger.flagDormantWallets(
      {
        ...d,
        lastSignInOf: async (uid) => {
          try {
            const { metadata } = await admin.auth().getUser(uid);
            const seen = metadata.lastRefreshTime || metadata.lastSignInTime;
            return seen ? new Date(seen) : null;
          } catch (error) {
            // No auth record means the university closed the account: as
            // dormant as it gets.
            if (error.code === 'auth/user-not-found') return null;
            throw error;
          }
        },
        notify: (uid, payload) => writeNotification(d, uid, payload),
        notifyStaff: (payload) => notifyAdmins(d, payload),
      },
      d.now(),
    );
    if (outcome.flagged || outcome.cleared) console.log('dormant wallets', outcome);
  },
);

/**
 * Every half hour: any checkout still pending past the reconciliation window
 * is looked up at the gateway and settled or expired exactly as its callback
 * would have. Needs the gateway secrets, so it is its own function.
 */
exports.reconcilePayments = onSchedule(
  { schedule: 'every 30 minutes', timeZone: 'Asia/Manila', secrets: GATEWAY_SECRETS },
  async () => {
    const { reconcilePendingPayments, configFromEnv } = require('./server');
    const d = { ...deps(), config: configFromEnv() };
    const counts = await reconcilePendingPayments(d, d.now());
    if (counts.checked) console.log('reconciled pending payments', counts);
  },
);

/**
 * Refuses any Google account outside the university domain before it exists
 * in Authentication at all. The app and the rules refuse such accounts too;
 * this closes the last gap, where a non-UM user record could sit in the
 * Authentication console with nothing it can do.
 *
 * Needs "Firebase Authentication with Identity Platform" enabled on the
 * project (a one-click upgrade in the console). On a project without it the
 * *deploy itself* is refused ("Blocking Functions may only be configured for
 * GCIP projects"), and one refused function fails the whole batch, so the
 * two blocking functions are exported only when `IDENTITY_PLATFORM=true` is
 * set in `functions/.env`. Flip it after the upgrade and deploy again.
 */
const identityPlatform = process.env.IDENTITY_PLATFORM === 'true';

const gateSignUp = beforeUserCreated(async (event) => {
  const user = event.data;
  if (!user || !isUmEmail(user.email) || !user.emailVerified) {
    await audit.writeAudit(deps(), {
      actorId: user?.uid ?? 'unknown',
      action: audit.ACTIONS.authRejected,
      targetType: 'auth',
      targetId: user?.uid ?? null,
      details: { email: user?.email ?? null, reason: 'not a verified UM account' },
    });
    throw new HttpsError(
      'permission-denied',
      'Only verified University of Mindanao accounts (@umindanao.edu.ph) can sign in.',
    );
  }
});

/** Every sign-in is checked again and recorded. Same Identity Platform
 *  requirement as gateSignUp. */
const gateSignIn = beforeUserSignedIn(async (event) => {
  const user = event.data;
  const d = deps();
  if (!user || !isUmEmail(user.email) || !user.emailVerified) {
    await audit.writeAudit(d, {
      actorId: user?.uid ?? 'unknown',
      action: audit.ACTIONS.authRejected,
      targetType: 'auth',
      targetId: user?.uid ?? null,
      details: { email: user?.email ?? null, reason: 'not a verified UM account' },
    });
    throw new HttpsError('permission-denied', 'Only verified UM accounts can sign in.');
  }
  await audit.writeAudit(d, {
    actorId: user.uid,
    action: audit.ACTIONS.authSignIn,
    targetType: 'auth',
    targetId: user.uid,
    details: { email: user.email, provider: event.credential?.providerId ?? null },
  });
});

if (identityPlatform) {
  exports.gateSignUp = gateSignUp;
  exports.gateSignIn = gateSignIn;
}

/** Profile, listing, offer and order documents the app writes directly are
 *  audited from their changes, with the actor the document names. */
exports.auditUsers = onDocumentWritten('users/{uid}', async (event) => {
  const entries = audit.userAuditEntries(
    event.params.uid,
    event.data?.before.data(),
    event.data?.after.data(),
  );
  const d = deps();
  for (const entry of entries) await audit.writeAudit(d, entry);
});

exports.syncPublicUserSearch = onDocumentWritten('users/{uid}', async (event) => {
  const profile = event.data?.after.data();
  if (!profile) {
    await db.doc(`publicUserSearch/${event.params.uid}`).delete();
    return;
  }
  await syncPublicUser(event.params.uid, profile);
});

exports.syncPublicUserRole = onDocumentWritten('admins/{uid}', async (event) => {
  const profile = await db.doc(`users/${event.params.uid}`).get();
  if (profile.exists) await syncPublicUser(event.params.uid, profile.data());
});

exports.markFeaturedRotationDirty = onDocumentWritten(
  'services/{serviceId}',
  async (event) => {
    const before = event.data?.before.data();
    const after = event.data?.after.data();
    if (!featuredPoolChanged(before, after, Date.now())) return;
    await db.doc('system/featuredRotationState').set({
      generation: admin.firestore.FieldValue.increment(1),
      changedAt: admin.firestore.FieldValue.serverTimestamp(),
    }, { merge: true });
  },
);

exports.refreshFeaturedRotations = onSchedule(
  {
    schedule: 'every 5 minutes',
    timeZone: 'Asia/Manila',
    timeoutSeconds: 540,
    memory: '512MiB',
  },
  async () => {
    const stateRef = db.doc('system/featuredRotationState');
    const stateSnapshot = await stateRef.get();
    const state = stateSnapshot.data() || {};
    const generation = state.generation || 0;
    const hourIndex = Math.floor(Date.now() / 3600000);
    const nextExpiryMillis = state.nextExpiryAt?.toMillis?.() ?? 0;
    if (
      generation === (state.processedGeneration ?? -1) &&
      state.windowHour === hourIndex &&
      (state.nextExpiryAt == null || nextExpiryMillis > Date.now())
    ) return;

    const now = admin.firestore.Timestamp.now();
    const candidates = await db.collection('services')
      .where('status', '==', 'published')
      .where('featuredUntil', '>', now)
      .orderBy('featuredUntil', 'desc')
      .get();
    const services = candidates.docs.map((doc) => ({ ...doc.data(), id: doc.id }))
      .filter((service) => activeFeatured(service, now.toMillis()));
    const nextExpiry = services.reduce((earliest, service) => {
      const expiry = service.featuredUntil.toMillis();
      return earliest == null || expiry < earliest ? expiry : earliest;
    }, null);
    const rotations = buildFeaturedRotations(services, hourIndex);
    const projectionCollection = db.collection('featuredRotations');
    const existing = await projectionCollection.get();
    const updates = new Map(
      Object.entries(rotations).map(([scopeId, rotation]) => [scopeId, rotation]),
    );
    // Keep the prior unpaged document ids current during mobile app rollout.
    for (const rotation of Object.values(rotations)) {
      if (rotation.pageIndex !== 0) continue;
      const legacyId = rotationScopeId(
        rotation.scope === 'all' ? null : rotation.categoryId,
      );
      updates.set(legacyId, rotation);
    }
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
      for (const [scopeId, rotation] of entries.slice(offset, offset + 450)) {
        batch.set(projectionCollection.doc(scopeId), {
          ...rotation,
          windowHour: hourIndex,
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        });
      }
      await batch.commit();
    }

    const committed = await db.runTransaction(async (transaction) => {
      const latest = await transaction.get(stateRef);
      if ((latest.data()?.generation || 0) !== generation) return false;
      transaction.set(stateRef, {
        processedGeneration: generation,
        windowHour: hourIndex,
        nextExpiryAt: nextExpiry == null
          ? admin.firestore.FieldValue.delete()
          : admin.firestore.Timestamp.fromMillis(nextExpiry),
        generatedAt: admin.firestore.FieldValue.serverTimestamp(),
      }, { merge: true });
      return true;
    });
    console.log('featured rotation refreshed', {
      listings: services.length,
      projectionPages: Object.keys(rotations).length,
      hourIndex,
      committed,
    });
  },
);

exports.clearExpiredAnnouncement = onSchedule(
  { schedule: 'every 5 minutes', timeZone: 'Asia/Manila' },
  async () => {
    const ref = db.doc('settings/platform');
    await db.runTransaction(async (transaction) => {
      const snapshot = await transaction.get(ref);
      if (!snapshot.exists) return;
      const data = snapshot.data();
      const expiresAt = data.announcementExpiresAt?.toDate?.();
      if (!data.announcement || !expiresAt || expiresAt > new Date()) return;
      transaction.update(ref, {
        announcement: '',
        announcementExpiresAt: admin.firestore.FieldValue.delete(),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        updatedBy: 'system',
      });
    });
  },
);

exports.auditServices = onDocumentWritten('services/{serviceId}', async (event) => {
  const entries = audit.serviceAuditEntries(
    event.params.serviceId,
    event.data?.before.data(),
    event.data?.after.data(),
  );
  const d = deps();
  for (const entry of entries) await audit.writeAudit(d, entry);
});

exports.auditOffers = onDocumentWritten('offers/{offerId}', async (event) => {
  const entries = audit.offerAuditEntries(
    event.params.offerId,
    event.data?.before.data(),
    event.data?.after.data(),
  );
  const d = deps();
  for (const entry of entries) await audit.writeAudit(d, entry);
});

exports.auditOrderCreated = onDocumentCreated('orders/{orderId}', async (event) => {
  const order = event.data?.data();
  if (!order) return;
  await audit.writeAudit(deps(), {
    actorId: order.clientId,
    action: audit.ACTIONS.orderCreated,
    targetType: 'order',
    targetId: event.params.orderId,
    details: {
      serviceId: order.serviceId,
      freelancerId: order.freelancerId,
      price: order.price,
      offerId: order.offerId ?? null,
    },
  });
});

exports.auditStaff = onDocumentWritten('admins/{uid}', async (event) => {
  const before = event.data?.before.data();
  const after = event.data?.after.data();
  await audit.writeAudit(deps(), {
    actorId: after?.createdBy ?? before?.createdBy ?? 'service-account',
    action: audit.ACTIONS.staffChanged,
    targetType: 'staff',
    targetId: event.params.uid,
    details: {
      change: !before ? 'granted' : !after ? 'revoked' : 'updated',
      role: after?.role ?? before?.role ?? null,
      permissions: (after?.permissions ?? []).join(','),
    },
  });
});

exports.auditSettings = onDocumentWritten('settings/{settingId}', async (event) => {
  const after = event.data?.after.data();
  if (!after) return;
  await audit.writeAudit(deps(), {
    actorId: after.updatedBy ?? 'staff',
    action: audit.ACTIONS.settingsChanged,
    targetType: 'settings',
    targetId: event.params.settingId,
    details: { announcement: after.announcement ?? '', ordersPaused: after.ordersPaused === true },
  });
});

exports.auditCategories = onDocumentWritten('categories/{categoryId}', async (event) => {
  const after = event.data?.after.data();
  if (!after) return;
  await audit.writeAudit(deps(), {
    actorId: after.updatedBy ?? 'staff',
    action: audit.ACTIONS.categoryChanged,
    targetType: 'category',
    targetId: event.params.categoryId,
    details: { label: after.label, active: after.active === true },
  });
});

/** Staff are told when someone is waiting on them. */
exports.onPayoutRequested = onDocumentCreated('payouts/{payoutId}', async (event) => {
  const payout = event.data?.data();
  if (!payout) return;
  await notifyAdmins(deps(), {
    type: 'admin.payout_requested',
    title: `Payout of ₱${payout.amount} requested`,
  });
});

exports.onVerificationRequested = onDocumentWritten(
  'verificationRequests/{uid}',
  async (event) => {
    const before = event.data?.before.data();
    const after = event.data?.after.data();
    if (!after || after.status !== 'pending') return;
    if (before && before.status === 'pending') return;
    await notifyAdmins(deps(), {
      type: 'admin.verification_pending',
      title: 'A student is waiting for an identity check',
    });
  },
);
