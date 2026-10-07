const fs = require('node:fs');
const path = require('node:path');
const { assertFails, assertSucceeds, initializeTestEnvironment } = require('@firebase/rules-unit-testing');

describe('chat storage uploads', function () {
  this.timeout(30000);
  let env;
  const run = Date.now();
  const conversation = 'alice_bob';
  const claims = { email: 'a.student.123456@umindanao.edu.ph', email_verified: true };

  before(async () => {
    env = await initializeTestEnvironment({
      projectId: 'demo-chat-storage',
      firestore: { host: '127.0.0.1', port: 8080,
        rules: fs.readFileSync(path.join(__dirname, '../firestore.rules'), 'utf8') },
      storage: { host: '127.0.0.1', port: 9199,
        rules: fs.readFileSync(path.join(__dirname, '../storage.rules'), 'utf8') },
    });
    await env.withSecurityRulesDisabled(async (ctx) => {
      await ctx.firestore().doc(`conversations/${conversation}`).set({ participantIds: ['alice', 'bob'] });
    });
  });

  after(async () => { if (env) await env.cleanup(); });

  function upload(uid, name, size, contentType) {
    const context = uid ? env.authenticatedContext(uid, claims) : env.unauthenticatedContext();
    return context.storage().ref(`conversations/${conversation}/${run}-${name}`).put(new Uint8Array(size), { contentType });
  }

  for (const [type, limit] of [['image/png', 10], ['application/pdf', 10], ['video/mp4', 25], ['video/quicktime', 25], ['video/webm', 25]]) {
    it(`checks actual byte limits for ${type}`, async () => {
      const name = type.replace('/', '-');
      await assertSucceeds(upload('alice', name, limit * 1024 * 1024, type));
      await assertFails(upload('alice', `${name}-large`, limit * 1024 * 1024 + 1, type));
    });
  }

  it('rejects empty files, outsiders and anonymous uploads', async () => {
    await assertFails(upload('alice', 'empty', 0, 'video/mp4'));
    await assertFails(upload('stranger', 'stranger', 1, 'video/mp4'));
    await assertFails(upload(null, 'anonymous', 1, 'video/mp4'));
    await assertFails(upload('alice', 'unknown-video', 11 * 1024 * 1024, 'video/unknown'));
  });

  it('keeps existing files immutable', async () => {
    await assertSucceeds(upload('alice', 'immutable', 1, 'application/pdf'));
    await assertFails(upload('alice', 'immutable', 2, 'application/pdf'));
    await assertFails(env.authenticatedContext('alice', claims).storage().ref(`conversations/${conversation}/${run}-immutable`).delete());
  });
});
