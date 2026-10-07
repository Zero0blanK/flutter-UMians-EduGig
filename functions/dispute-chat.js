'use strict';
const { randomUUID } = require('node:crypto');

const VALID_ID = /^[A-Za-z0-9_-]{1,120}$/;
const PAGE_SIZE = 50;
const CAPTURE_LEASE_MS = 2 * 60 * 1000;
const asDate = (value) => value?.toDate ? value.toDate() : new Date(value);

/** The caller is authenticated and has disputes.resolve before entering. */
async function reviewChat(req, res, { db, now }) {
  const orderId = req.params.id;
  const afterId = req.body?.afterId;
  if (!VALID_ID.test(orderId) || (afterId != null &&
      (typeof afterId !== 'string' || !VALID_ID.test(afterId)))) {
    return res.status(400).json({ error: 'invalid identifier' });
  }
  const order = await db.doc(`orders/${orderId}`).get();
  if (!order.exists) return res.status(404).json({ error: 'order not found' });
  const data = order.data();
  if (data.status !== 'disputed' && !data.disputeReason) {
    return res.status(409).json({ error: 'Chat review is only available for disputed orders.' });
  }
  if (typeof data.clientId !== 'string' || typeof data.freelancerId !== 'string') {
    return res.status(409).json({ error: 'Order participants are unavailable.' });
  }
  const conversationId = [data.clientId, data.freelancerId].sort().join('_');
  const snapshotRef = db.doc(`disputeChatSnapshots/${orderId}`);
  const attempt = randomUUID();
  const capture = await db.runTransaction(async (tx) => {
    const existing = await tx.get(snapshotRef);
    const previous = existing.exists ? existing.data() : null;
    if (previous?.status === 'ready') return previous;
    const startedAt = now();
    if (previous?.status === 'building' &&
        startedAt.getTime() - asDate(previous.startedAt).getTime() < CAPTURE_LEASE_MS) {
      return null;
    }
    const record = { orderId, conversationId, status: 'building', attempt,
      capturedAt: previous?.capturedAt || startedAt, startedAt, capturedBy: req.uid };
    tx.set(snapshotRef, record);
    return record;
  });
  if (!capture) return res.status(503).json({ error: 'Chat snapshot is being captured. Please try again.' });
  if (capture.status !== 'ready') {
    const source = await db.collection(`conversations/${conversationId}/messages`)
      .where('sentAt', '<=', capture.capturedAt).get();
    for (let offset = 0; offset < source.docs.length; offset += 450) {
      const batch = db.batch();
      for (const document of source.docs.slice(offset, offset + 450)) {
        batch.set(db.doc(`${snapshotRef.path}/messages/${document.id}`), document.data());
      }
      await batch.commit();
    }
    await db.runTransaction(async (tx) => {
      const record = await tx.get(snapshotRef);
      if (record.data()?.attempt !== attempt) throw new Error('snapshot capture lease changed');
      tx.update(snapshotRef, { status: 'ready', messageCount: source.docs.length });
    });
  }
  const capturedAt = capture.capturedAt;
  let query = db.collection(`${snapshotRef.path}/messages`).orderBy('sentAt', 'desc');
  if (afterId != null) {
    const cursor = await db.doc(`${snapshotRef.path}/messages/${afterId}`).get();
    if (!cursor.exists || asDate(cursor.data().sentAt) > asDate(capturedAt)) {
      return res.status(400).json({ error: 'invalid chat cursor' });
    }
    query = query.startAfter(cursor);
  }
  const page = await query.limit(PAGE_SIZE + 1).get();
  const documents = page.docs.slice(0, PAGE_SIZE);
  const messages = documents.map((document) => {
    const message = document.data();
    return {
      id: document.id, senderId: message.senderId, text: message.text || '',
      sentAt: asDate(message.sentAt).toISOString(), offerId: message.offerId || null,
      serviceId: message.serviceId || null, serviceTitle: message.serviceTitle || null,
      attachment: message.attachmentUrl ? {
        url: message.attachmentUrl, name: message.attachmentName,
        type: message.attachmentType, size: message.attachmentSize,
      } : null,
    };
  });
  // Copies freeze the evidence independently of later message insertion.
  // Clients have no access to this server-owned collection; every page must
  // pass authentication and disputes.resolve on the parent route.
  return res.json({ capturedAt: asDate(capturedAt).toISOString(), messages,
    nextCursor: page.docs.length > PAGE_SIZE ? documents.at(-1).id : null });
}

module.exports = { reviewChat, PAGE_SIZE };
