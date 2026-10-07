/**
 * Demo data seeder.
 *
 * Fills the app with a marketplace that looks lived-in: student accounts,
 * services across every category, orders spread over the whole lifecycle,
 * settled payments, reviews, and chat history. Useful for screenshots, for a
 * demo, and for seeing how screens behave with real quantities of data rather
 * than one hand-made row.
 *
 * Runs against the EMULATOR by default, so it can never touch real data by
 * accident. Seeding the real project (for `APP_ENV=development` builds)
 * requires --live plus GOOGLE_APPLICATION_CREDENTIALS; --wipe is refused
 * there and --unseed --live removes exactly what this script added.
 *
 *   node tools/seed/seed.js                 # emulator (safe default)
 *   node tools/seed/seed.js --wipe          # clear seeded data first
 *   node tools/seed/seed.js --live          # real project, for development builds
 *   node tools/seed/seed.js --unseed --live # undo the live seed
 *
 * Every account uses the password below, so you can sign in as anyone.
 */

const admin = require('firebase-admin');
const {
  refreshFeaturedRotations,
  seedFeaturedFixtures,
} = require('./featured-fixtures');

const DEMO_PASSWORD = 'Password123';
const PROJECT_ID = process.env.SEED_PROJECT || 'student-freelance-services';

const args = process.argv.slice(2);
const wipe = args.includes('--wipe');
const live = args.includes('--live');
const unseed = args.includes('--unseed');

// Everything this script creates is recorded here so `--unseed` can remove
// exactly that and nothing else. Kept per project so an emulator run and a
// live run never delete each other's records.
// The target is part of the filename, not just the project id. An emulator run
// and a live run share a project id, so a single name let the emulator's
// manifest overwrite the live one — and a later --unseed --live then deleted
// emulator document ids that do not exist in production, leaving the real
// seeded data orphaned and duplicated on the next seed.
const MANIFEST = require('node:path').join(
  __dirname,
  `.seeded-${process.env.SEED_PROJECT || 'student-freelance-services'}` +
    `-${live ? 'live' : 'emulator'}.json`,
);

// Wiping whole collections is fine on a throwaway emulator and reckless on a
// real project, where it would also delete documents this script never made.
if (wipe && live) {
  console.error(
    'Refusing --wipe against a live project: it deletes every service, order, ' +
      'payment, review and conversation, including ones you created yourself. ' +
      'Use --unseed to remove only what this seeder added.',
  );
  process.exit(1);
}

if (!live) {
  // Point the Admin SDK at the emulators unless --live was passed.
  process.env.FIRESTORE_EMULATOR_HOST ||= '127.0.0.1:8080';
  process.env.FIREBASE_AUTH_EMULATOR_HOST ||= '127.0.0.1:9099';
} else if (!process.env.GOOGLE_APPLICATION_CREDENTIALS) {
  console.error(
    'Refusing to seed a live project without GOOGLE_APPLICATION_CREDENTIALS.',
  );
  process.exit(1);
}

admin.initializeApp({ projectId: PROJECT_ID });
const db = admin.firestore();
const auth = admin.auth();
const fsSync = require('node:fs');

/** Documents and accounts this run created, for a precise `--unseed`. */
const created = { docs: [], uids: [], project: PROJECT_ID, at: null };
const track = (collection, id) => {
  created.docs.push(`${collection}/${id}`);
  return id;
};

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

const PEOPLE = [
  {
    key: 'maya',
    studentId: '100001',
    collegeId: 'cce',
    program: 'BS Computer Science',
    name: 'Maya Robles',
    bio: 'BS Computer Science, 3rd year. I tutor data structures and build small Flutter apps on the side.',
    skills: ['Flutter', 'Dart', 'Data Structures', 'Python'],
  },
  {
    key: 'ivan',
    studentId: '100002',
    collegeId: 'cce',
    program: 'BS Entertainment and Multimedia Computing',
    name: 'Ivan Cruz',
    bio: 'Graphic design major. Posters, logos and event kits for student orgs — fast turnaround during event season.',
    skills: ['Illustrator', 'Figma', 'Branding', 'Layout'],
  },
  {
    key: 'sam',
    studentId: '100003',
    collegeId: 'case',
    program: 'AB Communication',
    name: 'Samantha Lim',
    bio: 'Communications student. I proofread theses and polish scholarship essays.',
    skills: ['Proofreading', 'APA', 'Copywriting'],
  },
  {
    key: 'noel',
    studentId: '100004',
    collegeId: 'case',
    program: 'AB English',
    name: 'Noel Bautista',
    bio: 'Film and multimedia. Defense videos, reels, and event coverage.',
    skills: ['Premiere Pro', 'Color Grading', 'Motion Graphics'],
  },
  {
    key: 'rina',
    studentId: '100005',
    collegeId: 'case',
    program: 'BS Mathematics',
    name: 'Rina Delos Santos',
    bio: 'Math major who genuinely likes calculus. Patient with people who do not.',
    skills: ['Calculus', 'Statistics', 'Linear Algebra'],
  },
  {
    key: 'jomar',
    studentId: '100006',
    collegeId: 'cce',
    program: 'BS Information Technology',
    name: 'Jomar Aquino',
    bio: 'Music production student. Mixing, mastering, and jingles for org videos.',
    skills: ['Ableton', 'Mixing', 'Sound Design'],
  },
  {
    key: 'thea',
    studentId: '100007',
    collegeId: 'case',
    program: 'AB Political Science',
    name: 'Thea Marquez',
    bio: 'Photography for org events, portraits and graduation shoots.',
    skills: ['Portraits', 'Event Coverage', 'Lightroom'],
  },
];

const SERVICES = [
  ['maya', 'tutoring', 'One-on-one data structures tutoring', 'Stuck on linked lists, trees, or Big-O? I walk through problems with you on a call and leave you with annotated notes and practice sets. Sessions run about an hour and we go at your pace.', 450, 2, 2, ['Data Structures', 'Python']],
  ['maya', 'programming', 'Flutter app for your capstone demo', 'I build a small, working Flutter app for your capstone or class project — clean state management, real navigation, and comments you can actually defend. Includes a walkthrough call so it is genuinely yours.', 3500, 10, 2, ['Flutter', 'Dart', 'Firebase']],
  ['maya', 'programming', 'Debug my code (Python or Dart)', 'Send the repo and the error. I find the cause, fix it, and explain what went wrong so it does not happen again.', 350, 1, 1, ['Python', 'Dart', 'Debugging']],
  ['ivan', 'design', 'Event poster for your student org', 'Print-ready poster in your org colours, delivered as PDF and PNG. Two concepts, then we refine the one you like.', 600, 3, 2, ['Illustrator', 'Layout']],
  ['ivan', 'design', 'Logo and brand kit for a new org', 'Logo, colour palette, type choices, and a one-page usage guide so your officers stay consistent after you graduate.', 2200, 7, 3, ['Branding', 'Figma']],
  ['ivan', 'design', 'Certificate and tarpaulin set', 'Matching certificate template and tarpaulin layout for your event. Editable files included.', 850, 4, 2, ['Layout', 'Illustrator']],
  ['sam', 'writing', 'Thesis proofreading, per chapter', 'Grammar, consistency, and citation formatting in APA or MLA. Tracked changes plus a short summary of recurring issues so your next chapter is cleaner.', 500, 3, 1, ['Proofreading', 'APA']],
  ['sam', 'writing', 'Scholarship essay polish', 'I keep your voice and fix the structure — the essay still sounds like you, just clearer. Includes one revision after your feedback.', 400, 2, 2, ['Copywriting']],
  ['noel', 'video', 'Thesis defense video edit', 'Clean cuts, captions, background music, and your school intro. Send raw clips and a rough script.', 1200, 5, 2, ['Premiere Pro']],
  ['noel', 'video', 'Org recap reel for social media', 'Vertical recap reel from your event footage, cut for Reels and TikTok with captions.', 700, 3, 2, ['Motion Graphics']],
  ['rina', 'tutoring', 'Calculus 1 and 2 exam review', 'Limits, derivatives, integrals — we work through past exams together until the patterns click.', 400, 2, 2, ['Calculus']],
  ['rina', 'tutoring', 'Statistics for research papers', 'I help you choose the right test, run it, and explain the output so you can defend it.', 550, 3, 2, ['Statistics', 'SPSS']],
  ['jomar', 'music', 'Mix and master your track', 'Send your stems and references. You get a balanced mix and a mastered file ready to upload.', 900, 4, 2, ['Mixing', 'Ableton']],
  ['jomar', 'music', 'Custom jingle for your org video', 'Short original jingle written to your brief. Royalty-free for your org to reuse.', 750, 5, 2, ['Sound Design']],
  ['thea', 'photography', 'Graduation portrait session', 'One-hour shoot on campus, 20 edited photos delivered through a shared album.', 1500, 5, 1, ['Portraits', 'Lightroom']],
  ['thea', 'photography', 'Event coverage for org activities', 'Half-day coverage of your event with same-week turnaround on edited highlights.', 1800, 6, 1, ['Event Coverage']],
  ['maya', 'other', 'Study plan for finals week', 'We map your subjects, deadlines, and weak spots into a realistic week-by-week plan you will actually follow.', 300, 2, 1, ['Planning']],
  ['maya', 'programming', 'Code review before you submit', 'I read your project like your professor will: naming, structure, dead code, and the parts that will get questioned in the defense. You get comments inline plus a summary.', 500, 2, 1, ['Code Review', 'Dart', 'Python']],
  ['maya', 'tutoring', 'Intro to programming, from scratch', 'For first years who feel lost. We start where you actually are, not where the syllabus assumes you are.', 380, 2, 2, ['Python', 'Beginner']],
  ['ivan', 'design', 'Social media kit for your event', 'Countdown posts, speaker cards, and a cover photo, sized for Facebook and Instagram.', 950, 4, 2, ['Figma', 'Layout']],
  ['ivan', 'design', 'Infographic for your research poster', 'I turn your data into something readable from two metres away, which is where your panel will be standing.', 800, 4, 2, ['Illustrator', 'Data Viz']],
  ['sam', 'writing', 'Resume and cover letter for OJT', 'Formatted cleanly, written for the role you are actually applying to, no filler adjectives.', 450, 2, 2, ['Copywriting']],
  ['sam', 'writing', 'Abstract and conclusion rewrite', 'The two sections everyone reads and nobody has time to fix by submission week.', 350, 2, 2, ['Proofreading', 'APA']],
  ['sam', 'other', 'Presentation script and speaker notes', 'A script you can actually say out loud, timed to your slide count.', 400, 3, 2, ['Copywriting']],
  ['noel', 'video', 'Wedding-style highlight for org anniversaries', 'Cinematic cut with licensed music, colour graded, delivered in 1080p and 4K.', 2500, 8, 2, ['Premiere Pro', 'Color Grading']],
  ['noel', 'video', 'Subtitle and caption pass', 'Accurate captions burned in or as a separate SRT, in English or Filipino.', 400, 2, 1, ['Captions']],
  ['rina', 'tutoring', 'Physics 1 problem sets', 'Kinematics through rotational motion. We work problems, I do not just give answers.', 420, 2, 2, ['Physics']],
  ['rina', 'other', 'Excel and Sheets for your data', 'Formulas, pivot tables, and charts that will not embarrass you in front of a panel.', 500, 3, 2, ['Excel', 'Sheets']],
  ['jomar', 'music', 'Podcast episode cleanup', 'Noise removal, levelling, and edits for your org podcast. Send the raw recording.', 600, 3, 2, ['Mixing', 'Audio Repair']],
  ['jomar', 'video', 'Sound design for short films', 'Foley, ambience, and a final mix that holds up on laptop speakers.', 1100, 6, 2, ['Sound Design']],
  ['thea', 'photography', 'Product photos for your small business', 'Clean white-background shots for your online shop, ten products included.', 1200, 4, 2, ['Product', 'Lightroom']],
  ['thea', 'design', 'Photo retouching, per batch', 'Colour correction and blemish removal for up to 30 images.', 600, 3, 2, ['Lightroom', 'Retouching']],
  ['maya', 'other', 'Set up Git and GitHub for your group', 'Branches, a sane workflow, and a walkthrough so your groupmates stop emailing zip files.', 350, 2, 1, ['Git', 'GitHub']],
  ['ivan', 'other', 'Slide deck redesign', 'Same content, but it stops looking like the default template.', 700, 3, 2, ['Figma', 'Layout']],
];

/** Orders across the whole lifecycle so every screen has something to show. */
const ORDERS = [
  { seller: 'maya', buyer: 'sam', service: 0, status: 'completed', paid: true, review: [5, 'Explained recursion better than three lectures did. Came in with annotated notes and stayed until it clicked.'] },
  { seller: 'ivan', buyer: 'rina', service: 3, status: 'completed', paid: true, review: [5, 'Poster looked great and the print shop had no issues with the file. Two concepts on the first day.'] },
  { seller: 'sam', buyer: 'noel', service: 6, status: 'completed', paid: true, review: [4, 'Caught citation errors my adviser missed. Would have liked slightly faster turnaround, but the work was solid.'] },
  { seller: 'rina', buyer: 'maya', service: 10, status: 'completed', paid: true, review: [5, 'Went through four past exams with me. I passed.'] },
  { seller: 'thea', buyer: 'ivan', service: 14, status: 'completed', paid: true, review: [5, 'Photos came back in three days and the shared album made it easy to send to family.'] },
  { seller: 'noel', buyer: 'thea', service: 8, status: 'completed', paid: true, review: [4, 'Good cuts and captions. Needed one revision for the intro but it was handled quickly.'] },
  { seller: 'jomar', buyer: 'sam', service: 12, status: 'completed', paid: true, review: [5, 'Mix sounded far more professional than what I sent him.'] },
  { seller: 'ivan', buyer: 'thea', service: 4, status: 'submitted', paid: true },
  { seller: 'maya', buyer: 'noel', service: 1, status: 'inProgress', paid: true },
  { seller: 'rina', buyer: 'jomar', service: 11, status: 'inProgress', paid: true },
  { seller: 'noel', buyer: 'maya', service: 9, status: 'accepted', paid: false },
  { seller: 'sam', buyer: 'rina', service: 7, status: 'accepted', paid: true },
  { seller: 'thea', buyer: 'sam', service: 15, status: 'pending', paid: false },
  { seller: 'jomar', buyer: 'ivan', service: 13, status: 'pending', paid: false },
  { seller: 'maya', buyer: 'thea', service: 2, status: 'revisionRequested', paid: true },
  { seller: 'ivan', buyer: 'noel', service: 5, status: 'cancelled', paid: false },
  { seller: 'rina', buyer: 'thea', service: 10, status: 'rejected', paid: false },
  { seller: 'maya', buyer: 'jomar', service: 17, status: 'completed', paid: true, review: [5, 'Pointed out three things my panel would have asked about. Worth it.'] },
  { seller: 'sam', buyer: 'thea', service: 21, status: 'completed', paid: true, review: [4, 'Resume reads much better. Turnaround was quick.'] },
  { seller: 'ivan', buyer: 'maya', service: 19, status: 'completed', paid: true, review: [5, 'The infographic was readable from the back of the room, which was exactly the problem I had.'] },
  { seller: 'thea', buyer: 'noel', service: 30, status: 'completed', paid: true, review: [5, 'Product shots looked professional and arrived early.'] },
  { seller: 'jomar', buyer: 'rina', service: 28, status: 'completed', paid: true, review: [4, 'Podcast audio is much cleaner. Some background hiss remained in one segment.'] },
  { seller: 'rina', buyer: 'sam', service: 26, status: 'submitted', paid: true },
  { seller: 'noel', buyer: 'ivan', service: 25, status: 'inProgress', paid: true },
  { seller: 'maya', buyer: 'rina', service: 18, status: 'accepted', paid: false },
  { seller: 'maya', buyer: 'jomar', service: 32, status: 'pending', paid: false },
  { seller: 'thea', buyer: 'maya', service: 31, status: 'disputed', paid: true },
];

const REQUIREMENTS = [
  'Our midterm covers trees and graphs. I can do the basics but I lose track on traversals — can we start there?',
  'Event is on the 24th, colours are maroon and white, and the theme is "Bridges". Org logo attached in the chat.',
  'Chapters 1 to 3, about 40 pages, APA 7th. My adviser flagged inconsistent citations.',
  'Finals are in two weeks. I need integration by parts and partial fractions especially.',
  'Shoot around the old campus gate in late afternoon if the weather holds.',
  'Raw clips are about 25 minutes total. I need it cut to under 8 with captions.',
  'Four stems, reference track linked in chat. Aiming for something warm rather than bright.',
];

/** Keeps seeded orders payable: their freelancer must own the linked service. */
function validateOrderFixtures() {
  for (const [index, order] of ORDERS.entries()) {
    const service = SERVICES[order.service];
    if (!service) {
      throw new Error(`Seed order ${index} references missing service ${order.service}.`);
    }
    if (service[0] !== order.seller) {
      throw new Error(
        `Seed order ${index} assigns ${order.seller} as freelancer, but ` +
          `service ${order.service} belongs to ${service[0]}.`,
      );
    }
  }
}

const CHATS = [
  ['maya', 'sam', ['Hi! Saw your tutoring listing — are you free this Saturday morning?', 'Yes, 9am works. Which topics are giving you trouble?', 'Mostly traversals and Big-O.', 'Perfect, I will prepare practice problems for both.']],
  ['ivan', 'rina', ['Sent the org logo and our colour codes.', 'Got them. I will have two concepts by Thursday.', 'Thank you! No rush before then.']],
  ['noel', 'thea', ['Uploaded the raw clips to the drive link.', 'Downloaded, thanks. The audio is a bit low in the middle section — I will lift it.', 'Perfect.']],
  ['sam', 'noel', ['Chapter 2 is ready whenever you are.', 'Starting on it tonight, expect it back Wednesday.']],
];

// ---------------------------------------------------------------------------

/** Mirrors FreelanceService.keywordsFor in the Dart model. */
function keywordsFor(title, skills) {
  const tokens = new Set();
  for (const source of [title, ...skills]) {
    for (const word of source.toLowerCase().split(/[^a-z0-9]+/)) {
      if (word.length >= 2) tokens.add(word);
    }
  }
  return [...tokens].slice(0, 40);
}

const daysAgo = (n) =>
  admin.firestore.Timestamp.fromMillis(Date.now() - n * 86400000);
const daysFromNow = (n) =>
  admin.firestore.Timestamp.fromMillis(Date.now() + n * 86400000);

// Two accounts intentionally model the full paid-and-verified state. This
// gives the development build an honest, visible example of the blue badge;
// it does not change the rule that ordinary users need both conditions.
const PRO_DEMO_KEYS = new Set(['maya', 'ivan']);

const COMMISSION_BASIS_POINTS = 500;
const splitOf = (gross) => {
  const commission = Math.floor((gross * COMMISSION_BASIS_POINTS + 5000) / 10000);
  return { commission, netToFreelancer: gross - commission };
};

async function ensureUser(person) {
  const email = umEmailFor(person);
  try {
    const existing = await auth.getUserByEmail(email);
    await auth.updateUser(existing.uid, { displayName: person.name });
    // Pre-existing account: adopted, not created, so unseed leaves it alone.
    return { uid: existing.uid, isNew: false };
  } catch {
    const account = await auth.createUser({
      email,
      password: DEMO_PASSWORD,
      displayName: person.name,
      emailVerified: true,
    });
    return { uid: account.uid, isNew: true };
  }
}

/**
 * Demo accounts carry University of Mindanao student addresses because the
 * rules refuse any other identity: first initial, surname, six-digit student
 * number, e.g. maya.robles.100001 → m.robles.100001@umindanao.edu.ph.
 */
function umEmailFor(person) {
  const [first, ...rest] = person.name.toLowerCase().split(' ');
  const surname = (rest.length ? rest[rest.length - 1] : first).replace(/[^a-z]/g, '');
  return `${first[0]}.${surname}.${person.studentId}@umindanao.edu.ph`;
}

/** Deletes a document and any subcollections this seeder puts under it. */
async function deleteDocDeep(ref) {
  for (const sub of ['messages', 'deliveries']) {
    const kids = await ref.collection(sub).get();
    for (const kid of kids.docs) await kid.ref.delete();
  }
  await ref.delete();
}

/** Removes exactly what a previous run recorded, and nothing else. */
async function unseedFromManifest() {
  if (!fsSync.existsSync(MANIFEST)) {
    console.error(
      `No manifest at ${MANIFEST} — nothing recorded for ${PROJECT_ID}. ` +
        'Unseed only removes what this seeder wrote, so there is nothing to do.',
    );
    process.exit(1);
  }
  const manifest = JSON.parse(fsSync.readFileSync(MANIFEST, 'utf8'));
  console.log(
    `Removing ${manifest.docs.length} documents and ${manifest.uids.length} ` +
      `accounts recorded on ${manifest.at}`,
  );

  let removed = 0;
  for (const path of manifest.docs) {
    try {
      await deleteDocDeep(db.doc(path));
      removed++;
    } catch (error) {
      console.error(`  could not delete ${path}: ${error.message}`);
    }
  }
  let accounts = 0;
  for (const uid of manifest.uids) {
    try {
      await auth.deleteUser(uid);
      accounts++;
    } catch (error) {
      console.error(`  could not delete account ${uid}: ${error.message}`);
    }
  }
  await refreshFeaturedRotations(db, admin);
  fsSync.unlinkSync(MANIFEST);
  console.log(`Removed ${removed} documents and ${accounts} accounts.`);
}

async function wipeSeeded() {
  for (const collection of ['payments', 'reviews', 'orders', 'services', 'conversations']) {
    const snap = await db.collection(collection).get();
    let batch = db.batch();
    let n = 0;
    for (const doc of snap.docs) {
      // Conversations and orders carry subcollections; clear those first.
      for (const sub of ['messages', 'deliveries']) {
        const kids = await doc.ref.collection(sub).get();
        for (const kid of kids.docs) batch.delete(kid.ref);
      }
      batch.delete(doc.ref);
      if (++n % 100 === 0) {
        await batch.commit();
        batch = db.batch();
      }
    }
    await batch.commit();
  }
  console.log('  cleared existing marketplace data');
}

/// Grants staff access to the account with [email].
async function grantAdmin(email) {
  let user;
  try {
    user = await auth.getUserByEmail(email);
  } catch {
    console.error(`No account for ${email}. Sign up first, then grant.`);
    process.exit(1);
  }
  await db.doc(`admins/${user.uid}`).set({
    // The main admin: every permission, and the only role a service-account
    // key ever writes. Staff are granted from the admin console.
    role: 'admin',
    permissions: [],
    grantedAt: admin.firestore.FieldValue.serverTimestamp(),
    email,
  });
  console.log(`${email} is now the main admin (admins/${user.uid}).`);
  console.log('Revoke by deleting that document.');
}

async function main() {
  if (unseed) return unseedFromManifest();

  const adminFlag = args.indexOf('--admin');
  if (adminFlag !== -1) {
    const email = args[adminFlag + 1];
    if (!email) {
      console.error('Usage: node tools/seed/seed.js --admin <email> [--live]');
      process.exit(1);
    }
    return grantAdmin(email);
  }

  validateOrderFixtures();

  console.log(
    live
      ? `Seeding LIVE project ${PROJECT_ID}`
      : `Seeding emulator (${process.env.FIRESTORE_EMULATOR_HOST})`,
  );

  if (wipe) await wipeSeeded();

  // --- accounts + profiles -------------------------------------------------
  const uid = {};
  for (const person of PEOPLE) {
    const account = await ensureUser(person);
    uid[person.key] = account.uid;
    if (account.isNew) created.uids.push(account.uid);
    track('users', account.uid);
    await db.doc(`users/${uid[person.key]}`).set({
      uid: uid[person.key],
      displayName: person.name,
      bio: person.bio,
      skills: person.skills,
      collegeId: person.collegeId,
      program: person.program,
      email: umEmailFor(person),
      studentId: person.studentId,
      // The institutional sign-in is the identity check.
      identityVerified: true,
      ...(PRO_DEMO_KEYS.has(person.key) ? { proUntil: daysFromNow(21) } : {}),
      // Selling and payouts are age-gated; every demo student is an adult.
      birthDate: new Date('2003-06-15T00:00:00Z'),
      createdAt: daysAgo(120),
    });
  }
  console.log(`  ${PEOPLE.length} students`);

  // --- services ------------------------------------------------------------
  const serviceIds = [];
  for (const [i, s] of SERVICES.entries()) {
    const [owner, categoryId, title, description, price, days, revisions, skills] = s;
    const ref = db.collection('services').doc();
    serviceIds.push(track('services', ref.id));
    await ref.set({
      sellerId: uid[owner],
      title,
      titleLower: title.toLowerCase(),
      description,
      categoryId,
      skills,
      keywords: keywordsFor(title, skills),
      startingPrice: price,
      // Bigger jobs are quoted: programming and video listings carry a
      // starting price and are ordered through an offer card; every third
      // design listing asks to be contacted first at its fixed price.
      pricingMode: ['programming', 'video'].includes(categoryId) ? 'negotiable' : 'fixed',
      requiresContact: categoryId === 'design' && i % 3 === 0,
      currency: 'PHP',
      deliveryDays: days,
      revisionCount: revisions,
      status: 'published',
      // Counters are recomputed from the seeded reviews further down.
      ratingSum: 0,
      ratingCount: 0,
      createdAt: daysAgo(90 - i),
      updatedAt: daysAgo(30 - (i % 30)),
    });
  }
  console.log(`  ${SERVICES.length} published services`);

  // --- orders, payments, reviews ------------------------------------------
  let payments = 0;
  let reviews = 0;
  for (const [i, o] of ORDERS.entries()) {
    const service = SERVICES[o.service];
    const price = service[4];
    const sellerUid = uid[o.seller];
    const buyerUid = uid[o.buyer];
    const orderRef = db.collection('orders').doc();
    track('orders', orderRef.id);
    const created = 60 - i * 3;

    await orderRef.set({
      serviceId: serviceIds[o.service],
      serviceTitle: service[2],
      clientId: buyerUid,
      freelancerId: sellerUid,
      participantIds: [buyerUid, sellerUid].sort(),
      price,
      currency: 'PHP',
      deliveryDays: service[5],
      revisionCount: service[6],
      requirements: REQUIREMENTS[i % REQUIREMENTS.length],
      status: o.status,
      createdAt: daysAgo(created),
      updatedAt: daysAgo(Math.max(1, created - 5)),
      ...(o.status === 'pending' ? {} : { deadline: daysAgo(created - service[5]) }),
    });

    if (o.paid) {
      const split = splitOf(price);
      track('payments', orderRef.id);
      await db.doc(`payments/${orderRef.id}`).set({
        orderId: orderRef.id,
        clientId: buyerUid,
        freelancerId: sellerUid,
        participantIds: [buyerUid, sellerUid].sort(),
        amount: price,
        currency: 'PHP',
        commission: split.commission,
        netToFreelancer: split.netToFreelancer,
        status: 'paid',
        method: 'manual',
        verified: false,
        reference: `GCash ${1000000000 + i * 7919}`,
        createdAt: daysAgo(created - 1),
        updatedAt: daysAgo(created - 1),
        paidAt: daysAgo(created - 1),
      });
      payments++;
    }

    if (o.status === 'submitted' || o.status === 'completed' || o.status === 'revisionRequested') {
      await orderRef.collection('deliveries').add({
        senderId: sellerUid,
        note: 'Uploaded the finished files to the shared link and summarised the changes in chat. Let me know if anything needs adjusting.',
        createdAt: daysAgo(Math.max(1, created - 4)),
      });
    }

    if (o.review) {
      const [rating, comment] = o.review;
      track('reviews', orderRef.id);
      await db.doc(`reviews/${orderRef.id}`).set({
        orderId: orderRef.id,
        serviceId: serviceIds[o.service],
        reviewerId: buyerUid,
        revieweeId: sellerUid,
        rating,
        comment,
        createdAt: daysAgo(Math.max(1, created - 6)),
      });
      reviews++;
    }
  }
  console.log(`  ${ORDERS.length} orders, ${payments} settled payments, ${reviews} reviews`);

  // Denormalised rating totals. In the app these are maintained atomically by
  // the reviewer; here the seeder writes the equivalent end state so the
  // marketplace shows scores without any extra reads.
  const totals = {};
  for (const o of ORDERS) {
    if (!o.review) continue;
    const id = serviceIds[o.service];
    totals[id] ??= { sum: 0, count: 0 };
    totals[id].sum += o.review[0];
    totals[id].count += 1;
  }
  for (const [id, t] of Object.entries(totals)) {
    await db.doc(`services/${id}`).update({
      ratingSum: t.sum,
      ratingCount: t.count,
    });
  }
  console.log(`  rating counters on ${Object.keys(totals).length} services`);

  // --- conversations -------------------------------------------------------
  for (const [a, b, lines] of CHATS) {
    const ids = [uid[a], uid[b]].sort();
    const conversationId = ids.join('_');
    const ref = db.doc(`conversations/${conversationId}`);
    track('conversations', conversationId);
    await ref.set({
      participantIds: ids,
      lastMessagePreview: lines[lines.length - 1].slice(0, 80),
      lastMessageSenderId: lines.length % 2 === 0 ? uid[b] : uid[a],
      lastMessageAt: daysAgo(2),
      createdAt: daysAgo(20),
      [`unreadCount.${uid[a]}`]: 0,
      [`unreadCount.${uid[b]}`]: 0,
    });
    for (const [i, text] of lines.entries()) {
      await ref.collection('messages').add({
        senderId: i % 2 === 0 ? uid[a] : uid[b],
        text,
        sentAt: daysAgo(20 - i),
      });
    }
  }
  console.log(`  ${CHATS.length} conversations`);

  // --- featured showcase and fair rotation -------------------------------
  await seedFeaturedFixtures(db, admin, track);
  await refreshFeaturedRotations(db, admin);

  created.at = new Date().toISOString();
  fsSync.writeFileSync(MANIFEST, JSON.stringify(created, null, 2));
  console.log(
    `\nManifest: ${MANIFEST}\n` +
      '  Remove exactly this data later with:\n' +
      `    node tools/seed/seed.js --unseed${live ? ' --live' : ''}`,
  );

  console.log('\nDone. Sign in as any of:');
  for (const person of PEOPLE) {
    console.log(`  ${umEmailFor(person)}  /  ${DEMO_PASSWORD}   (${person.name})`);
  }
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
