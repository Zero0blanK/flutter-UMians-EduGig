# Demo data seeder

Fills the app with a marketplace that looks lived-in — 7 students, 34 published
services across every category, 27 orders spread over the whole lifecycle,
settled payments, reviews, and chat history, plus 100 verified Pro featured
sellers for the marketplace rotation and launch showcase. Featured demo
profiles are Firestore-only fixtures; they are not sign-in accounts.

Useful for screenshots and demos, and for seeing how screens behave with real
quantities of data rather than one hand-made row. There are more services than
fit on a page, so infinite scroll actually gets exercised.

## Run it against the emulator (recommended)

The emulator is the default target, so the seeder can never touch real data by
accident.

```sh
cd tools/seed && npm install && cd ../..

# Terminal 1 — emulators
firebase emulators:start --only firestore,auth,storage

# Terminal 2 — seed, then point the app at the emulator
node tools/seed/seed.js
flutter run --dart-define=APP_ENV=emulator
```

On an Android emulator the host machine is not `localhost`, so add:

```sh
flutter run --dart-define=APP_ENV=emulator --dart-define=EMULATOR_HOST=10.0.2.2
```

Re-running is safe; `--wipe` clears the previous marketplace first:

```sh
node tools/seed/seed.js --wipe
```

## Run it against the real project (development)

The same demo students can live in the real Firebase project, so day-to-day
development talks to Firebase directly instead of the emulator. `--live`
needs a service-account key (never committed) and refuses `--wipe`;
`--unseed --live` removes exactly what the seeder added and nothing else.

```sh
GOOGLE_APPLICATION_CREDENTIALS=path/to/key.json node tools/seed/seed.js --live
flutter run --dart-define=APP_ENV=development     # real project + demo account selector
```

On Windows, from the project root, the equivalent commands are:

```powershell
$env:GOOGLE_APPLICATION_CREDENTIALS = 'C:\path\to\service-account.json'
npm.cmd --prefix tools/seed run seed:live
npm.cmd --prefix tools/seed run grant-admin -- a.nerosa.545679@umindanao.edu.ph --live
```

The regular seed command targets the emulator. Use `seed:live` only when the
service-account credential is configured and you intend to write to the real
project. `grant-admin` only grants the role; it does not seed marketplace data.

Enable the **Email/Password** provider once in the Firebase console
(Authentication → Sign-in method); the seeded accounts are created verified,
so the Identity Platform gate lets them through. A production build (the
default `APP_ENV`) never shows the demo-account selector.

## Sign in as anyone

The real project accepts only University of Mindanao Google accounts, so the
seeded students carry UM student addresses (`initial.surname.number`) and
`identityVerified: true`. Emulator and development builds show a
**Demo accounts** selector under the Google button, so a presenter can switch
between seeded students without entering Google or a password. Every seeded
account uses the password **`Password123`** internally:

| Email | Student | Sells |
| --- | --- | --- |
| `m.robles.100001@umindanao.edu.ph` | Maya Robles | Tutoring, Flutter development |
| `i.cruz.100002@umindanao.edu.ph` | Ivan Cruz | Posters, branding, layout |
| `s.lim.100003@umindanao.edu.ph` | Samantha Lim | Proofreading, essays |
| `n.bautista.100004@umindanao.edu.ph` | Noel Bautista | Video editing |
| `r.santos.100005@umindanao.edu.ph` | Rina Delos Santos | Calculus, statistics |
| `j.aquino.100006@umindanao.edu.ph` | Jomar Aquino | Mixing, sound design |
| `t.marquez.100007@umindanao.edu.ph` | Thea Marquez | Photography |

Maya is the fullest account — services in three categories, orders on both the
buying and selling side, settled payments, and reviews received. Start there.

### Admin scenario

The picker does not grant privileges itself: staff access is still enforced by
the `admins/{uid}` document and Firestore rules. To demonstrate the admin
console, grant Maya the seeded main-admin role once, then select **Maya
Robles** in the picker:

```sh
node tools/seed/seed.js --admin m.robles.100001@umindanao.edu.ph
```

The selector is compiled only with `APP_ENV=emulator` or
`APP_ENV=development`; the default production build contains neither the
selector nor the email/password demo sign-in form.

## What each account demonstrates

- **Orders in every state** — pending, accepted, in progress, submitted,
  revision requested, completed, cancelled, rejected, and disputed — so each
  branch of the order screen has something to show.
- **Settled payments** with the 5% commission split already applied, which
  populates the earnings card on the profile.
- **Reviews** attached to completed orders, which drive the star ratings on
  marketplace cards and on service pages.
- **Conversations** with message history and realistic unread state.

## Seeding a real project

This writes with the Admin SDK and bypasses security rules, so it needs a
service-account key — the Firebase CLI login is not enough.

1. Firebase Console → **Project settings → Service accounts → Generate new
   private key**. A JSON file downloads.
2. Point at it and run:

```sh
export GOOGLE_APPLICATION_CREDENTIALS=/path/to/service-account.json
node tools/seed/seed.js --live
```

Keep that key out of the repo; it grants full admin access to the project.

### Removing it again

Every document and account a run creates is recorded in
`.seeded-<project>.json`. Undo removes exactly those and nothing else:

```sh
node tools/seed/seed.js --unseed --live
```

Accounts are only deleted if this seeder created them — an address that already
existed is adopted, not claimed, so unseed leaves it alone.

**`--wipe` is refused against a live project.** It clears whole collections,
which on a real project would also delete documents you created by hand. Use
`--unseed` there instead.

## Keeping it honest

The commission split in `seed.js` mirrors `CommissionPolicy.standard`
(5%, integer arithmetic). Seeded payments are written as `verified: false`
because no gateway confirmed them — exactly as a real manual settlement would
be recorded, so the UI shows "Confirmed by the freelancer" rather than implying
a gateway receipt that never existed.
