# Mull (iOS)

Budget-aware wishlist and group shopping, built in Flutter from the Claude Design mockups ("Buy It").

## Run

```sh
flutter run                                   # fresh install → onboarding
flutter run --dart-define=MULL_SAMPLE=true    # starts with the mockup data
```

In debug builds, the profile sheet also has **Load sample data**.

> The project sits on an iCloud-synced Desktop. iCloud tags build output with Finder metadata that
> `codesign` rejects, so `build/` is a symlink to `~/Developer/.build-cache/mull`. If `build/` ever
> becomes a real folder again: `rm -rf build && mkdir -p ~/Developer/.build-cache/mull && ln -s ~/Developer/.build-cache/mull build`.

## Test

```sh
flutter test                                  # money parsing, budget cycles, reach logic, persistence
flutter drive --driver=test_driver/integration_test.dart \
  --target=integration_test/tour_test.dart    # walks every screen, writes screenshots/
```

## Layout

- `lib/core` — ₹ formatting & forgiving amount parsing (`28k`, `1.2L`), budget cycles, product link reader
- `lib/data` — models and `MullStore` (local-first, one JSON file, debounced atomic writes)
- `lib/ui` — design tokens (light/dark from the design file), glass, sheets, page scaffold, icons
- `lib/screens` — Money, Wishlist (+ quick add, need check, in reach), Groups, Lists, profile, onboarding
- `tool/make_icon.swift` — renders the app icon from the Chillax font
