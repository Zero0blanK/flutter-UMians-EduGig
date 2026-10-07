'use strict';

const crypto = require('node:crypto');

/** Stable, private key for merging duplicate public search projections. */
function publicIdentityKey(profile, fallbackId) {
  const studentId = typeof profile.studentId === 'string'
    ? profile.studentId.trim().toLowerCase()
    : '';
  const email = typeof profile.email === 'string'
    ? profile.email.trim().toLowerCase()
    : '';
  const identity = studentId
    ? `student:${studentId}`
    : email
      ? `email:${email}`
      : `account:${fallbackId}`;
  return crypto.createHash('sha256').update(identity).digest('hex');
}

module.exports = { publicIdentityKey };
