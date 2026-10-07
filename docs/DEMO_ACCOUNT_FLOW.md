# Demo account flow

Use this flow to demonstrate the app without signing in through Google.

## 1. Start the local demo

Run these commands from the project root.

```sh
flutter pub get
cd tools/seed && npm install && cd ../..
```

In terminal 1, start Firebase locally:

```sh
firebase emulators:start --only firestore,auth
```

In terminal 2, create the demo data:

```sh
node tools/seed/seed.js --wipe
```

In terminal 3, run the app in demo mode:

```sh
flutter run --dart-define=APP_ENV=emulator
```

For an Android emulator, add `--dart-define=EMULATOR_HOST=10.0.2.2` to the
last command.

## 2. Sign in as a demo user

1. On the login screen, open **Demo account**.
2. Select an account.
3. Tap **Sign in as ...**.

Use **Maya Robles** first. It has the most complete seller, buyer, payment,
review, and order examples.

## 3. Change accounts during the presentation

1. Open **Me**.
2. Tap **Log out**.
3. On the login screen, choose another name from **Demo account**.
4. Tap **Sign in as ...**.

No Google account or password entry is needed.

## 4. Demonstrate the admin console

After the demo data has been seeded, run this once in another terminal:

```sh
node tools/seed/seed.js --admin m.robles.100001@umindanao.edu.ph
```

Then sign in as **Maya Robles**. Open **Me** and choose **Admin console**.

The picker does not make an account an admin. The command above creates the
required admin access record, so permissions remain enforced by Firebase.

## 5. Production builds

Build or run normally for production, without `APP_ENV=development` or
`APP_ENV=emulator`:

```sh
flutter run
```

The demo-account selector and password sign-in are not available in that
build. Use the local emulator for demonstrations; do not seed demo accounts
into production data.
