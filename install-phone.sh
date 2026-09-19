#!/bin/sh
# Puts Mull on a real iPhone, standalone.
#
# Why this exists rather than `flutter run -d <phone>`:
#
#   A debug build is JIT, and iOS will not let a JIT app run without a debugger
#   attached. It installs fine and then sits there when you open it from the
#   home screen — which looks like a broken app and is really just the wrong
#   build mode. Anything you want to actually *use* on a phone has to be
#   --release.
#
#   And `flutter install` rejects --dart-define, so the Supabase keys cannot be
#   passed through it. Build first with the defines, install the artefact
#   second.
#
#   devicectl uses its own device identifier, not the UDID `flutter devices`
#   prints. `xcrun devicectl list devices` has the one it wants.
#
# Usage:
#   ./install-phone.sh                 first paired device
#   ./install-phone.sh <device-id>     a specific one

set -e

DEVICE="$1"
if [ -z "$DEVICE" ]; then
  DEVICE=$(xcrun devicectl list devices 2>/dev/null \
    | awk 'NR>2 && $0 !~ /^-/ && NF {print $3; exit}')
fi
if [ -z "$DEVICE" ]; then
  echo "No paired device. Plug the phone in, unlock it, and trust this Mac."
  exit 1
fi

echo "Building release…"
flutter build ios --release \
  --dart-define=SUPABASE_URL=https://nfuujjyscybqdcfryiwk.supabase.co \
  --dart-define=SUPABASE_ANON_KEY=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im5mdXVqanlzY3licWRjZnJ5aXdrIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODk1NjkzNDcsImV4cCI6MjEwNTE0NTM0N30.TVpPThLe_P5LVgbwa_QnRBlfyIXcJli95cFM7NBvh2M

echo "Installing to $DEVICE…"
xcrun devicectl device install app --device "$DEVICE" build/ios/iphoneos/Runner.app

echo "Done. Open Mull on the phone."
