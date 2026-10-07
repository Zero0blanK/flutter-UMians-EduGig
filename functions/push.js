/**
 * Notifications the server writes, and the push that follows every
 * notification document — whoever wrote it.
 *
 * The app already writes most notifications itself, validated per type by
 * security rules, and consumes them over a Firestore stream while it is open.
 * Push is the same document delivered to a locked screen: the trigger in
 * index.js watches `users/{uid}/notifications` and fans out to that user's
 * registered devices. Nothing here decides *whether* someone gets told; that
 * was decided when the document was written.
 */

const RETENTION_DAYS = 60;

/** Writes an inbox notification the same shape the client writes. */
async function writeNotification(deps, uid, { type, title, orderId, conversationId }) {
  const { db } = deps;
  const now = new Date();
  await db.collection(`users/${uid}/notifications`).add({
    type,
    title: String(title).slice(0, 140),
    body: '',
    read: false,
    createdAt: deps.serverTimestamp ? deps.serverTimestamp() : now,
    expiresAt: new Date(now.getTime() + RETENTION_DAYS * 24 * 60 * 60 * 1000),
    ...(orderId ? { orderId } : {}),
    ...(conversationId ? { conversationId } : {}),
  });
}

/**
 * Sends one notification document to every device the recipient registered,
 * and forgets devices the platform reports as gone.
 *
 * The payload mirrors `AppNotification.toRouteData()` so a tapped push lands
 * on the same screen as a tapped inbox row, through the same router.
 */
async function pushNotification(deps, { uid, notificationId, notification }) {
  const { db, messaging, logger = console } = deps;
  const devices = await db.collection(`users/${uid}/devices`).get();
  const tokens = devices.docs
    .map((doc) => doc.data()?.token)
    .filter((token) => typeof token === 'string' && token.length > 0);
  if (tokens.length === 0) return { sent: 0, pruned: 0 };

  const data = {
    type: String(notification.type || ''),
    notificationId: String(notificationId),
  };
  if (notification.orderId) data.orderId = String(notification.orderId);
  if (notification.conversationId) {
    data.conversationId = String(notification.conversationId);
  }

  const response = await messaging.sendEachForMulticast({
    tokens,
    notification: {
      title: String(notification.title || 'Student Freelance Services'),
      body: String(notification.body || ''),
    },
    data,
    android: {
      priority: 'high',
      notification: { channelId: 'default', clickAction: 'FLUTTER_NOTIFICATION_CLICK' },
    },
    apns: { payload: { aps: { sound: 'default' } } },
    webpush: { fcmOptions: { link: '/' } },
  });

  // A token that no longer exists comes back with one of these codes on every
  // send; keeping it means paying to fail forever.
  const dead = new Set([
    'messaging/registration-token-not-registered',
    'messaging/invalid-registration-token',
    'messaging/invalid-argument',
  ]);
  const stale = [];
  response.responses.forEach((result, index) => {
    if (!result.success && dead.has(result.error?.code)) {
      stale.push(tokens[index]);
    } else if (!result.success) {
      logger.warn('push failed', { uid, code: result.error?.code });
    }
  });
  if (stale.length) {
    const batch = db.batch();
    devices.docs
      .filter((doc) => stale.includes(doc.data()?.token))
      .forEach((doc) => batch.delete(doc.ref));
    await batch.commit();
  }
  return { sent: response.successCount, pruned: stale.length };
}

/** Tells every staff member something needs a human. */
async function notifyAdmins(deps, payload) {
  const admins = await deps.db.collection('admins').get();
  for (const doc of admins.docs) {
    await writeNotification(deps, doc.id, payload);
  }
  return admins.docs.length;
}

module.exports = { writeNotification, pushNotification, notifyAdmins, RETENTION_DAYS };
