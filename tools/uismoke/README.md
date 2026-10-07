# UI smoke test

Drives the built web app in headless Chrome against the seeded emulator, signs
in as a demo student, and walks the main screens.

Its job is to catch what `flutter analyze` and unit tests cannot: uncaught
exceptions at runtime, a screen that renders empty, or a query that works in a
rules test but is denied against real data. Screenshots land in
`tools/uismoke/screenshots/` so the result can be eyeballed.

## Run it

```sh
cd tools/uismoke && npm install && cd ../..

flutter build web --dart-define=APP_ENV=emulator

firebase emulators:start --only firestore,auth,storage # terminal 1
node tools/seed/seed.js --wipe                   # terminal 2
node tools/seed/seed.js --admin m.robles.100001@umindanao.edu.ph   # the admin step expects Maya to be staff
cd build/web && python -m http.server 8777       # terminal 3

node tools/uismoke/ui_smoke.js                   # terminal 4
```

Exits non-zero if any step fails or any runtime error is observed, so it works
in CI. It uses Maya Robles, the default demo-account selection with the
broadest seeded coverage.

Run it twice: once at the default 1280x900 and once at phone width with
`SMOKE_VIEWPORT=390x844`. Build with `flutter build web --debug` for the
phone pass: only a debug build reports "A RenderFlex overflowed" and
"Vertical viewport was given unbounded height" to the console, and the
script counts both as runtime errors. A release build paints the overflow
stripes silently and the pass would be green.

## How it can assert anything at all

Flutter web paints into a canvas, so there is normally no DOM to query. The
script clicks Flutter's own hidden "Enable accessibility" placeholder, which
switches on the semantics tree and mirrors every widget into real DOM nodes
with aria labels, which lets the test activate the selected demo account.

## What it covers

| Step | What it proves |
| --- | --- |
| Engine boot + semantics | The bundle loads and Flutter starts |
| Login | Auth against the emulator works end to end |
| Marketplace | The published-services query returns and cards render |
| Card ratings | The batched ratings query resolves and renders |
| Scroll | Pagination past the first page does not throw |
| Service detail | The detail screen and the seller's name render |
| Service detail | The action bar (order / message) and the review overview render |
| Chat | Opening a thread from a listing, sending a line, seeing it on the stream |
| Create order | The order form renders with its brief and pinned price bar |
| Manual payment | The buyer records a reference; the panel flips to awaiting and the bar stops offering to pay |
| Admin | The console renders its figures for a staff account |
| Orders | The orders query returns for both tabs |
| Profile | The Me hub renders its stat row and the Wallet / Pro doors |
| Wallet, Pro, Notifications | The pages split out of the profile render |

## Findings it has already produced

These were all invisible to the analyzer and the unit tests:

- `setState() called after dispose()` in the marketplace — the catch blocks
  around paging were unguarded, and the screen is built briefly while auth
  resolves, then disposed mid-request.
- Every earnings read denied. For a `list`, Firestore proves a query safe only
  over the fields the query constrains; the rule inspects `participantIds`
  while the query filtered on `freelancerId`, so `participantIds` was undefined
  and the read failed. The query now constrains both.
- Bottom navigation labels clipped on every screen: the theme set the
  navigation bar to 68px, and an icon, indicator and label do not fit under
  Material 3's 80px default.

## A note on assertions

An early version waited for the text "Tutoring" to decide the marketplace had
loaded — and passed, because that is also the name of a category filter chip
that renders before any data arrives. The screenshot showed a spinner. It now
waits for a card's price instead. Assert on something only the loaded state can
produce.
