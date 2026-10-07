// One-time migration for deployments that already have user profiles.
// Run from functions/ with application-default credentials for the project.
const fs = require('node:fs');
const path = require('node:path');
const { publicIdentityKey } = require('./public-identity');
const admin = require('firebase-admin');

function projectId() {
  if (process.env.GCLOUD_PROJECT) return process.env.GCLOUD_PROJECT;
  if (process.env.GOOGLE_CLOUD_PROJECT) return process.env.GOOGLE_CLOUD_PROJECT;
  if (process.env.FIREBASE_CONFIG) {
    try {
      const config = JSON.parse(process.env.FIREBASE_CONFIG);
      if (typeof config.projectId === 'string') return config.projectId;
    } catch {
      // Firebase CLI can also set FIREBASE_CONFIG to a file path.
      try {
        const configPath = path.resolve(process.env.FIREBASE_CONFIG);
        const config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
        if (typeof config.projectId === 'string') return config.projectId;
      } catch {
        // Fall through to this repository's checked-in Firebase config.
      }
    }
  }
  const root = path.join(__dirname, '..');
  const firebaseConfig = JSON.parse(
    fs.readFileSync(path.join(root, 'firebase.json'), 'utf8'),
  );
  const dartProjects = firebaseConfig.flutter?.platforms?.dart || {};
  for (const configuration of Object.values(dartProjects)) {
    if (typeof configuration?.projectId === 'string') {
      return configuration.projectId;
    }
  }

  const firebaseAliases = JSON.parse(
    fs.readFileSync(path.join(root, '.firebaserc'), 'utf8'),
  ).projects || {};
  return firebaseAliases.default || Object.values(firebaseAliases)[0];
}

let db;

const departments = {
  cce: 'College of Computing Education',
  case: 'College of Arts and Sciences Education',
  cbae: 'College of Business Administration Education',
  cae: 'College of Accounting Education',
  cee: 'College of Engineering Education',
  cte: 'College of Teacher Education',
  chse: 'College of Health Sciences Education',
};

function normalize(value) {
  return String(value || '').normalize('NFKD').replace(/[\u0300-\u036f]/g, '')
    .toLowerCase().trim().replace(/\s+/g, ' ');
}

async function main() {
  if (!admin.apps.length) {
    const id = projectId();
    if (!id) {
      throw new Error(
        'Set GCLOUD_PROJECT or configure a Firebase project in firebase.json or .firebaserc.',
      );
    }
    admin.initializeApp({ projectId: id });
  }
  db = admin.firestore();
  let cursor = null;
  let count = 0;
  for (;;) {
    let query = db.collection('users').orderBy(admin.firestore.FieldPath.documentId()).limit(200);
    if (cursor) query = query.startAfter(cursor);
    const page = await query.get();
    if (page.empty) break;
    const batch = db.batch();
    for (const profileDoc of page.docs) {
      const profile = profileDoc.data();
      const access = await db.doc(`admins/${profileDoc.id}`).get();
      const adminData = access.exists ? access.data() : null;
      const role = adminData?.role === 'admin' ? 'Admin'
        : adminData?.role === 'staff' && (adminData.permissions || []).some((p) =>
          p === 'services.moderate' || p === 'users.manage') ? 'Moderator' : null;
      const userRef = db.doc(`users/${profileDoc.id}`);
      batch.update(userRef, { publicRole: role });
      if (profile.suspended === true) {
        batch.delete(db.doc(`publicUserSearch/${profileDoc.id}`));
      } else {
        const department = departments[profile.collegeId] || '';
        batch.set(db.doc(`publicUserSearch/${profileDoc.id}`), {
          identityKey: publicIdentityKey(profile, profileDoc.id),
          displayName: profile.displayName || 'Student',
          nameLower: normalize(profile.displayName),
          program: profile.program || '',
          programLower: normalize(profile.program),
          department,
          departmentLower: normalize(department),
          departmentCodeLower: normalize(profile.collegeId),
          photoUrl: profile.photoUrl || null,
          createdAt: profile.createdAt || admin.firestore.Timestamp.now(),
          publicRole: role,
          suspended: false,
        });
      }
    }
    await batch.commit();
    count += page.size;
    cursor = page.docs[page.docs.length - 1];
    console.log(`Indexed ${count} profiles`);
    if (page.size < 200) break;
  }
}

if (require.main === module) {
  main().catch((error) => {
    console.error('Public user search backfill failed', error.message);
    process.exitCode = 1;
  });
}

module.exports = { projectId, normalize };
