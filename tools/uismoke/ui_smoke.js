/**
 * UI smoke test.
 *
 * Drives the built web app (APP_ENV=emulator) in headless Chrome against the seeded emulator,
 * signs in as a demo student, and walks the main screens. Its real job is to
 * catch what `flutter analyze` and unit tests cannot: uncaught exceptions at
 * runtime, a screen that renders empty, or a query that fails against real
 * data. Screenshots are written alongside so the result can be eyeballed.
 *
 *   node tools/uismoke/ui_smoke.js [baseUrl]
 *
 * Flutter web paints into a canvas, so there is normally no DOM to query.
 * Clicking Flutter's own "Enable accessibility" placeholder switches on the
 * semantics tree, which mirrors every widget into real DOM nodes with aria
 * labels — that is what makes assertions here possible.
 */

const fs = require('node:fs');
const path = require('node:path');
const puppeteer = require('puppeteer');

const BASE = process.argv[2] || 'http://127.0.0.1:8777';
// The development-only selector starts on Maya, the seeded account with the
// broadest buyer, seller and review coverage.
const EMAIL = 'm.robles.100001@umindanao.edu.ph';
const SHOTS = path.join(__dirname, 'screenshots');
// `SMOKE_VIEWPORT=390x844` runs the walkthrough at phone width. Overflow
// stripes are only reported by a debug build (`flutter build web --debug`),
// which logs "A RenderFlex overflowed" to the console; the release bundle
// paints them silently.
const [VIEW_W, VIEW_H] = (process.env.SMOKE_VIEWPORT || '1280x900')
  .split('x')
  .map(Number);

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// The Firestore emulator's REST surface, with its owner token, hands back a
// published listing's id so the walkthrough can open routes that need one.
// Flutter's hash router does not surface pushes in `page.url()`.
const FIRESTORE_EMULATOR = process.env.FIRESTORE_EMULATOR_HOST || '127.0.0.1:8080';
const PROJECT = process.env.SMOKE_PROJECT || 'student-freelance-services';
async function publishedServiceId() {
  try {
    const url =
      `http://${FIRESTORE_EMULATOR}/v1/projects/${PROJECT}/databases/(default)/documents` +
      `:runQuery`;
    const res = await fetch(url, {
      method: 'POST',
      headers: { Authorization: 'Bearer owner', 'Content-Type': 'application/json' },
      body: JSON.stringify({
        structuredQuery: {
          from: [{ collectionId: 'services' }],
          where: {
            fieldFilter: {
              field: { fieldPath: 'status' },
              op: 'EQUAL',
              value: { stringValue: 'published' },
            },
          },
          limit: 1,
        },
      }),
    });
    const rows = await res.json();
    const name = rows.find((r) => r.document)?.document?.name || '';
    return name.split('/').pop() || null;
  } catch {
    return null;
  }
}

/** A document id matching structured-query filters, via the emulator's REST surface. */
async function firstDocId(collectionId, filters) {
  try {
    const url =
      `http://${FIRESTORE_EMULATOR}/v1/projects/${PROJECT}/databases/(default)/documents:runQuery`;
    const res = await fetch(url, {
      method: 'POST',
      headers: { Authorization: 'Bearer owner', 'Content-Type': 'application/json' },
      body: JSON.stringify({
        structuredQuery: {
          from: [{ collectionId }],
          where: {
            compositeFilter: {
              op: 'AND',
              filters: filters.map(([field, value]) => ({
                fieldFilter: { field: { fieldPath: field }, op: 'EQUAL', value: { stringValue: value } },
              })),
            },
          },
          limit: 1,
        },
      }),
    });
    const rows = await res.json();
    const name = rows.find((r) => r.document)?.document?.name || '';
    return name.split('/').pop() || null;
  } catch {
    return null;
  }
}

const failures = [];
const steps = [];

function record(name, ok, detail = '') {
  steps.push({ name, ok, detail });
  console.log(`${ok ? '  ok  ' : ' FAIL '} ${name}${detail ? ` — ${detail}` : ''}`);
  if (!ok) failures.push(`${name}${detail ? `: ${detail}` : ''}`);
}

async function shot(page, name) {
  fs.mkdirSync(SHOTS, { recursive: true });
  const file = path.join(SHOTS, `${name}.png`);
  await page.screenshot({ path: file });
  return file;
}

/** Every aria-label currently in the semantics tree. */
function labels(page) {
  return page.evaluate(() =>
    Array.from(
      document.querySelectorAll('[aria-label], flt-semantics, button, [role="button"]'),
    )
      .map((el) => el.getAttribute('aria-label') || (el.textContent || '').trim())
      .filter(Boolean),
  );
}

/** Waits until some label satisfies `match`, then returns the labels. */
async function waitForLabel(page, match, { timeout = 20000, label = '' } = {}) {
  const started = Date.now();
  let seen = [];
  while (Date.now() - started < timeout) {
    seen = await labels(page);
    if (seen.some(match)) return seen;
    await sleep(400);
  }
  throw new Error(
    `timed out waiting for ${label || 'label'}; saw ${seen.length} labels: ` +
      seen.slice(0, 25).join(' | '),
  );
}

/**
 * Clicks the first node whose aria-label OR visible text matches.
 *
 * Flutter's semantics tree does not always put a button's caption in
 * aria-label — sometimes it is the node's text content — so both are checked
 * before giving up, and the failure names what was actually on screen.
 */
async function clickLabel(page, match, description) {
  // The Auth emulator pins a "Running in emulator mode" banner over the
  // bottom of the page; a DOM click on anything under it hits the banner.
  await page.evaluate(() => {
    document.querySelectorAll('.firebase-emulator-warning').forEach((e) => e.remove());
  });
  const handle = await page.evaluateHandle((patternSource) => {
    const re = new RegExp(patternSource, 'i');
    const nodes = Array.from(
      document.querySelectorAll('[aria-label], flt-semantics, button, [role="button"]'),
    );
    const matches = nodes.filter((n) => {
      const aria = n.getAttribute('aria-label') || '';
      const text = (n.textContent || '').trim();
      return re.test(aria) || re.test(text);
    });
    // A container's textContent includes its children's, so an ancestor
    // panel matches before the button inside it. Click the innermost match:
    // the one that contains no other match.
    const el = matches.find((n) => !matches.some((m) => m !== n && n.contains(m)));
    if (!el) return null;
    // Flutter turns a DOM click on a semantics node into a tap action on
    // that node, so a label-only node (a tooltip, a caption) swallows the
    // click. Prefer the tappable node it wraps or sits inside.
    const tappable = '[flt-tappable], [role="button"]';
    return el.matches(tappable) ? el : el.querySelector(tappable) || el.closest(tappable) || el;
  }, match.source);

  const element = handle.asElement();
  if (!element) {
    const seen = await page.evaluate(() =>
      Array.from(
        document.querySelectorAll('[aria-label], flt-semantics, button, [role="button"]'),
      )
        .map((n) => n.getAttribute('aria-label') || (n.textContent || '').trim())
        .filter(Boolean)
        .slice(0, 30),
    );
    throw new Error(
      `no element matching ${description}; on screen: ${seen.join(' | ') || '(nothing)'}`,
    );
  }
  await element.click();
  return true;
}

(async () => {
  console.log(`UI smoke against ${BASE}\n`);

  const browser = await puppeteer.launch({
    headless: 'new',
    args: ['--no-sandbox', '--disable-dev-shm-usage', `--window-size=${VIEW_W},${VIEW_H}`],
  });
  const page = await browser.newPage();
  await page.setViewport({ width: VIEW_W, height: VIEW_H });

  // The point of the exercise: anything thrown at runtime is a real defect,
  // whether it comes from Dart or from the JS bootstrap.
  const consoleErrors = [];
  page.on('pageerror', (error) => consoleErrors.push(`pageerror: ${error.message}`));
  page.on('console', (msg) => {
    if (msg.type() === 'error') consoleErrors.push(`console: ${msg.text()}`);
    // Debug builds report layout overflow as a warning; treat it as a defect.
    if (/overflowed by/i.test(msg.text())) consoleErrors.push(`overflow: ${msg.text().split('\n')[0]}`);
  });
  page.on('requestfailed', (req) => {
    // Favicon and other cosmetic misses are noise, not failures.
    if (/favicon/.test(req.url())) return;
    // Firestore holds long-poll Listen and Write channels open; navigating
    // away, closing the page, or the SDK idling a stream out aborts them.
    // That is the transport working normally, not a defect, and it fires on
    // every run.
    if (
      /Firestore\/(Listen|Write)\/channel/.test(req.url()) &&
      /ERR_ABORTED/.test(req.failure()?.errorText || '')
    ) {
      return;
    }
    consoleErrors.push(`request failed: ${req.url()} ${req.failure()?.errorText}`);
  });

  try {
    await page.goto(BASE, { waitUntil: 'networkidle2', timeout: 60000 });
    record('app served', true);

    // Flutter boots asynchronously; wait for its host element.
    await page.waitForSelector('flt-glass-pane, flutter-view, flt-scene-host', {
      timeout: 60000,
    });
    await sleep(2500);
    record('flutter engine booted', true);

    // Switch on the semantics tree so widgets become queryable DOM.
    const enabled = await page.evaluate(() => {
      const el = document.querySelector('flt-semantics-placeholder')
        || document.querySelector('[aria-label="Enable accessibility"]');
      if (!el) return false;
      el.click();
      return true;
    });
    await sleep(2000);
    record('semantics enabled', enabled, enabled ? '' : 'placeholder not found');

    await waitForLabel(page, (l) => /email|sign in|log in/i.test(l), {
      label: 'the login screen',
    });
    record('login screen rendered', true);
    await shot(page, '01-login');

    await clickLabel(page, /sign in as maya/i, 'the demo sign-in button');

    // The marketplace is the post-login landing screen; seeded services prove
    // both that auth worked and that the published-services query returned.
    //
    // Match a card's price, not a category name: the filter chips are named
    // after categories and render before any data arrives, so matching those
    // reported success while the list was still spinning.
    const seen = await waitForLabel(page, (l) => /₱\s?\d/.test(l), {
      timeout: 60000,
      label: 'a service card price',
    });
    record('signed in and marketplace loaded', true, `${seen.length} labels`);

    // Ratings arrive in a second query after the page itself, so re-read the
    // labels rather than reusing the snapshot taken on first paint.
    await sleep(3000);
    const withRatings = await labels(page);
    await shot(page, '02-marketplace');
    const hasRating = withRatings.some((l) => /\b[1-5]\.\d\b/.test(l));
    record('service card ratings rendered', hasRating,
      hasRating ? '' : 'no x.y rating found on any card');

    // Scroll to exercise pagination past the first page of 20.
    await page.mouse.move(VIEW_W / 2, VIEW_H * 0.6);
    for (let i = 0; i < 12; i++) {
      await page.mouse.wheel({ deltaY: 600 });
      await sleep(250);
    }
    await sleep(1500);
    await shot(page, '03-marketplace-scrolled');
    record('marketplace scrolled without error', true);

    // Open the first service to check the detail screen and seller identity.
    // A card's price sits inside the card, so the tap lands on it; a title
    // word would match a category tile in the strip first.
    await clickLabel(page, /₱\s?\d/, 'a service card');
    await sleep(2500);
    const detail = await labels(page);
    await shot(page, '04-service-detail');
    record('service detail opened', detail.length > 0, `${detail.length} labels`);
    // The seller is named in the header (a link to their profile) and the
    // decision sits in the action bar: order, or message to get an offer.
    const hasSeller = detail.some((l) => /Robles|Cruz|Lim|Marquez|Aquino|Santos|Reyes|Garcia/.test(l));
    record('seller name shown on service detail', hasSeller,
      hasSeller ? '' : 'no seller name label found');
    const hasAction = detail.some((l) => /Order now|Message to get an offer|Edit listing|Ordering is paused/i.test(l));
    record('service detail action bar rendered', hasAction,
      hasAction ? '' : 'no order/message action found');
    const hasReviews = detail.some((l) => /^Reviews$/i.test(l));
    record('review overview rendered', hasReviews,
      hasReviews ? '' : 'no Reviews section found');

    // Chat, end to end: open the thread with this seller (a transaction that
    // reads a conversation which may not exist yet, then creates it), send
    // a line, and see it come back on the realtime stream. Skipped when the
    // opened listing is the signed-in student's own.
    const canMessage = detail.some((l) => /^Message seller$|^Message to get an offer$/i.test(l));
    if (canMessage) {
      try {
        await clickLabel(page, /^Message seller$|^Message to get an offer$/i, 'the message button');
        await waitForLabel(page, (l) => /^Message$|Say hello|View profile/i.test(l), {
          label: 'the chat screen',
        });
        await sleep(1500);
        // The first keystroke after focusing a Flutter field can be spent on
        // the focus itself, so the assertion is on the stamp, not the word.
        const stamp = `${Date.now()}`;
        const boxes = await page.$$('input, textarea');
        if (!boxes.length) throw new Error('no message input');
        await boxes[boxes.length - 1].click();
        await sleep(400);
        await page.keyboard.type(`smoke ${stamp}`, { delay: 10 });
        await clickLabel(page, /^Send$/i, 'the send button');
        // A bubble's words are selectable text, which the semantics tree
        // does not label; the day divider and the bubble's time stamp are.
        await waitForLabel(page, (l) => /\d{1,2}:\d{2}\s?[AP]M/i.test(l), {
          timeout: 15000,
          label: 'the sent message',
        });
        await shot(page, '04c-chat');
        record('chat message sent and received', true);
        // The app's own back button, as on a phone. Browser history back
        // while a text field holds focus trips a framework assertion in
        // `didChangeViewFocus` (Flutter 3.47, web) that is not the app's.
        await clickLabel(page, /^Back$/i, 'the back button');
        await sleep(1500);
      } catch (error) {
        await shot(page, '04c-chat').catch(() => {});
        record('chat message sent and received', false, error.message);
      }
    }

    // The order form for this listing: the brief, the terms, and a pinned
    // bar with the price and the send button. The bar must not swallow the
    // body, which it once did.
    const serviceId = await publishedServiceId();
    if (serviceId) {
      await page.goto(`${BASE}/#/order/new/${serviceId}`, { waitUntil: 'domcontentloaded' });
      await sleep(3500);
      const form = await labels(page);
      await shot(page, '04b-create-order');
      const hasForm = form.some((l) => /What do you need/.test(l)) && form.some((l) => /What happens next/.test(l));
      record('create order form rendered', hasForm,
        hasForm ? '' : `no brief/next-steps sections among ${form.length} labels`);
      await page.goto(`${BASE}/#/service/${serviceId}`, { waitUntil: 'domcontentloaded' });
      await sleep(2000);
    }

    await page.goBack().catch(() => {});
    await sleep(1500);

    // The palette has to hold in both themes, and every screenshot so far has
    // been dark: category tints in particular are defined per brightness, so a
    // light-mode capture is the only way to see half of them.
    await page.emulateMediaFeatures([
      { name: 'prefers-color-scheme', value: 'light' },
    ]);
    await page.goto(`${BASE}/#/`, { waitUntil: 'domcontentloaded' });
    await sleep(4000);
    const light = await labels(page);
    await shot(page, '07-marketplace-light');
    record('light theme renders', light.length > 0, `${light.length} labels`);
    await page.emulateMediaFeatures([
      { name: 'prefers-color-scheme', value: 'dark' },
    ]);

    // Public profile: the seller name on a service page is now a link.
    await page.goto(`${BASE}/#/`, { waitUntil: 'domcontentloaded' });
    await sleep(4000);
    const sellerUid = process.env.SMOKE_SELLER_UID;
    if (sellerUid) {
      await page.goto(`${BASE}/#/user/${sellerUid}`, {
        waitUntil: 'domcontentloaded',
      });
      await sleep(4000);
      const seen = await labels(page);
      await shot(page, '08-public-profile');
      const named = seen.some((l) => /Robles|Cruz|Lim|Marquez|Aquino/.test(l));
      record('public profile renders', named,
        named ? '' : `no student name among ${seen.length} labels`);
    }

    // Admin console. Maya is granted staff by the seeder, so the figures
    // should load rather than erroring on permission.
    await page.goto(`${BASE}/#/admin`, { waitUntil: 'domcontentloaded' });
    await sleep(5000);
    const adminLabels = await labels(page);
    await shot(page, '09-admin');
    const hasFigures = adminLabels.some((l) => /Commission earned|Revenue/i.test(l));
    record('admin console renders', hasFigures,
      hasFigures ? '' : `no revenue figures among ${adminLabels.length} labels`);

    // Orders and profile are the other two screens changed this round.
    for (const [tab, name] of [['orders', '05-orders'], ['profile', '06-profile']]) {
      await page.goto(`${BASE}/#/${tab}`, { waitUntil: 'domcontentloaded' });
      await sleep(3000);
      const found = await labels(page);
      await shot(page, name);
      record(`${tab} screen rendered`, found.length > 0, `${found.length} labels`);
      if (tab === 'orders') {
        // Open the first order card: the detail page has the step tracker,
        // the terms and the action bar, all of which must fit the viewport.
        try {
          await clickLabel(page, /^All$/, 'the All filter chip');
          await sleep(800);
          await clickLabel(page, /₱\s?\d/, 'an order card');
          await sleep(3000);
          const detail = await labels(page);
          await shot(page, '05b-order-detail');
          const ok = detail.some((l) => /^Terms$|^Requirements$/.test(l));
          record('order detail rendered', ok, ok ? '' : `no Terms/Requirements among ${detail.length} labels`);
        } catch (error) {
          record('order detail rendered', false, error.message);
        }
      }
      if (tab === 'profile') {
        // The Me hub: the stat row and the doors to wallet and Pro.
        const hasStats = found.some((l) => /^Earned|^Rating|^Available/i.test(l));
        record('profile stats rendered', hasStats,
          hasStats ? '' : 'no Earned/Rating/Available tiles found');
        const hasDoors = found.some((l) => /^Wallet/i.test(l)) && found.some((l) => /Pro/.test(l));
        record('profile hub links rendered', hasDoors,
          hasDoors ? '' : 'no Wallet/Pro tiles found');
      }
    }

    // Paying for an order, in the emulator's manual mode: the buyer records
    // a reference, the panel flips to "awaiting the seller", and the action
    // bar stops offering to pay. The seeded data has one accepted, unpaid
    // order with the smoke account as buyer.
    const myUid = await firstDocId('users', [['email', EMAIL]]);
    const unpaid = myUid && (await firstDocId('orders', [['clientId', myUid], ['status', 'accepted']]));
    if (unpaid) {
      try {
        await page.goto(`${BASE}/#/order/${unpaid}`, { waitUntil: 'domcontentloaded' });
        await waitForLabel(page, (l) => /^Pay ₱/.test(l), { label: 'the Pay button' });
        await clickLabel(page, /^Pay ₱/, 'the Pay button');
        await waitForLabel(page, (l) => /Record ₱/.test(l), { label: 'the reference dialog' });
        const fields = await page.$$('input');
        await fields[fields.length - 1].click();
        await sleep(300);
        await page.keyboard.type('GCash ref 1234567', { delay: 10 });
        await clickLabel(page, /^Record payment$/i, 'the record button');
        await waitForLabel(page, (l) => /Payment recorded/.test(l), { label: 'the confirmation' });
        await clickLabel(page, /^Done$/i, 'the Done button');
        await sleep(1500);
        const after = await labels(page);
        await shot(page, '05c-order-paid-manual');
        const awaiting = after.some((l) => /Awaiting confirmation|Update payment details/.test(l));
        const noPay = !after.some((l) => /^Pay ₱/.test(l));
        record('manual payment recorded and the bar stops offering to pay', awaiting && noPay,
          awaiting && noPay ? '' : `awaiting=${awaiting} noPayButton=${noPay}`);
      } catch (error) {
        await shot(page, '05c-order-paid-manual').catch(() => {});
        record('manual payment recorded and the bar stops offering to pay', false, error.message);
      }
    } else {
      record('manual payment flow', false, 'no accepted unpaid order for the smoke account');
    }

    // The pages split out of the profile this round, plus the seller's and
    // the buyer's own pages; every route is visited so a layout that only
    // overflows at this viewport is seen.
    for (const [path, name, pattern] of [
      ['wallet', '10-wallet', /Available|Activity|Earnings so far/i],
      ['wallet/account', '10b-payout-account', /Where should we send|Switch to another method/i],
      ['transactions', '10c-transactions', /Transactions|No transactions yet|Order payment|Payment for your work/i],
      ['pro', '11-pro', /What you get|Subscription/i],
      ['notifications', '12-notifications', /Notifications|All quiet/i],
      ['my-services', '13-my-services', /My services/i],
      ['service/new', '14-new-service', /New service/i],
      ['profile/edit', '15-edit-profile', /Edit profile/i],
      ['chats', '16-chats', /Messages/i],
      [`user/${process.env.SMOKE_SELLER_UID || 'me'}/reviews`, '17-reviews', /Reviews/i],
    ]) {
      await page.goto(`${BASE}/#/${path}`, { waitUntil: 'domcontentloaded' });
      await sleep(3500);
      const found = await labels(page);
      await shot(page, name);
      const ok = found.some((l) => pattern.test(l));
      record(`${path} screen rendered`, ok, ok ? '' : `no match among ${found.length} labels`);
    }
  } catch (error) {
    record('walkthrough', false, error.message);
    await shot(page, '99-failure').catch(() => {});
  } finally {
    await browser.close();
  }

  console.log('');
  if (consoleErrors.length) {
    console.log('Runtime errors observed:');
    for (const e of [...new Set(consoleErrors)].slice(0, 20)) console.log(`  ${e}`);
    failures.push(`${consoleErrors.length} runtime error(s)`);
  } else {
    console.log('No runtime errors observed.');
  }

  const passed = steps.filter((s) => s.ok).length;
  console.log(`\n${passed}/${steps.length} steps passed. Screenshots: ${SHOTS}`);
  process.exit(failures.length ? 1 : 0);
})();
