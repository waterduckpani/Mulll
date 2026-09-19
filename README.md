# Mull (iOS)

Splitting money with people, built in Flutter from the Claude Design mockups.

Who paid, who owes, and the fewest payments that clear it — settled over UPI,
which Mull never touches. Groups for a trip or a flat, one-to-one ledgers for
everything that is not a group, and schedules for the things that come round
every month on their own.

The two things it does that other split apps do not:

- **A payment is claimed and then confirmed.** "Mark as settled" being a single
  unverified tap is what makes a shared ledger rot — one side taps it, the other
  never sees the money, and the balance is quietly wrong forever. Here the payer
  claims and the payee confirms, and a UPI receipt shared into Mull carries the
  amount and the reference as evidence.
- **A schedule asks.** Rent goes up and people move out, so a due schedule
  surfaces as a card with the amount in an editable field. What you confirm is
  what gets recorded, and it becomes the new normal.

## Run

```sh
./run-dev.sh                                  # against the live Supabase project
./run-dev.sh --sample                         # …seeded with the mockup data
flutter run                                   # no keys: local-only, groups stay on the phone
./install-phone.sh                            # release build, installed on a paired iPhone
```

A build with no Supabase keys has no account to make, so onboarding skips the email and code steps
and asks only for a name and a UPI ID.

In debug builds, the profile sheet also has **Load sample data**.

> The project sits on an iCloud-synced Desktop. iCloud tags build output with Finder metadata that
> `codesign` rejects, so `build/` is a symlink to `~/Developer/.build-cache/mull`. If `build/` ever
> becomes a real folder again: `rm -rf build && mkdir -p ~/Developer/.build-cache/mull && ln -s ~/Developer/.build-cache/mull build`.

## Test

```sh
flutter test                                  # money, splitting, the ledger, schedules, reminders, persistence

# Walks every screen and writes screenshots/. A target that fails to compile makes `flutter drive`
# silently run the previous build, so check `flutter analyze` is clean before trusting a green run.
flutter drive --driver=test_driver/integration_test.dart --target=integration_test/tour_test.dart
flutter drive --driver=test_driver/integration_test.dart --target=integration_test/onboarding_test.dart
```

## Layout

- `lib/core` — ₹ formatting and forgiving amount parsing (`28k`, `1.2L`), date and recurrence maths,
  splitting and debt simplification, UPI payment links, UPI receipt reading
- `lib/data` — models and `MullStore` (local-first, one JSON file, debounced atomic writes),
  plus `remote/` for Supabase auth, friends and group sync
- `lib/ui` — design tokens, surfaces, sheets, page scaffold, icons
- `lib/screens` — onboarding, home, and under `groups/` the create flow, the group hub and its three
  destinations (settle up, ledger, recurring), plus the sheets

## The design

Built from `Mull UI spec.pdf` and the eight exported screens (4A–4H). Four rules carry it, and
`lib/ui/tokens.dart` is where they live:

- **No colour, ever.** Owing and being owed are told apart by the words and the weight, never by
  hue. There is no accent and no red/green.
- **No borders, no glass.** Hierarchy is only how high a surface floats: a gradient fill and a
  shadow. `Lift.focal` / `card` / `low` / `flat`, and **exactly one focal object per screen**.
- **Two gutters.** Text and titles at 30, cards and buttons at 20, so cards break outboard of the
  copy above them. `Gutter.text` and `Gutter.card`.
- **Numbers are Excon and always tabular; words are Ranade.** `MullType` names every role.

Dark is primary; the paper theme is an option in the profile sheet rather than half of a pair.
There are no em dashes in anything the app shows you.
- `ios/Shared` — Swift the app and its share extension both compile: Vision OCR, the receipt guess,
  the App Group queue, the palette

## The share extension

Share a UPI payment screen into Mull and the debt it pays off settles itself.
The extension runs Vision on device to show you what it read — it has no Flutter
engine and never will, because you are two taps from the back button — but it
decides nothing. `UpiReceiptReader` in Dart, which has the tests, is what matches
a receipt to a debt when the app next opens.

Needs the **App Group** (`group.in.mull.app`) enabled on both targets, and the
extension embedded *before* the Thin Binary phase or the Flutter iOS build
deadlocks.

## Where the wishlist went

Mull used to be a budget-aware wishlist with groups bolted on. It is now only
the groups. The wishlist, the named lists and the budget-as-ruler are in git at
the `wishlist-era` tag, and a `mull.json` written by that version still opens —
groups carry over untouched, and an expense flagged `repeatsMonthly` becomes the
schedule it was always trying to be.
