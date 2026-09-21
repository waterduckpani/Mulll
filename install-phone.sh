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
#   ./install-phone.sh                 first available device
#   ./install-phone.sh <device-id>     a specific one
#   ./install-phone.sh --wait          wait for the phone to come back, then install
#   ./install-phone.sh --install-only  skip the build and install what is already there

set -e

WAIT=0
BUILD=1
DEVICE=""
for arg in "$@"; do
  case "$arg" in
    --wait) WAIT=1 ;;
    --install-only) BUILD=0 ;;
    *) DEVICE="$arg" ;;
  esac
done

# Only a device in the "available" state can be installed to. Picking the first
# row regardless of state is how this used to fail: a phone that has gone off
# the network still lists, and devicectl then spends a minute failing to find
# an ECID it was never going to reach.
find_device() {
  xcrun devicectl list devices 2>/dev/null \
    | awk 'NR>2 && $0 !~ /^-/ && NF && $0 ~ /[[:space:]]available/ {print $3; exit}'
}

if [ -z "$DEVICE" ]; then
  DEVICE=$(find_device)
fi

if [ -z "$DEVICE" ] && [ "$WAIT" = "1" ]; then
  echo "Waiting for the phone. Unlock it and keep it on the same Wi-Fi..."
  while [ -z "$DEVICE" ]; do
    sleep 5
    DEVICE=$(find_device)
  done
fi

if [ -z "$DEVICE" ]; then
  echo "No device available. Unlock the phone, keep it on the same Wi-Fi as this"
  echo "Mac, and make sure it is still trusted. Then:"
  echo
  echo "  ./install-phone.sh --wait          build (if needed) and install when it appears"
  echo "  ./install-phone.sh --install-only  install the build that is already made"
  echo
  xcrun devicectl list devices 2>/dev/null || true
  exit 1
fi

if [ "$BUILD" = "1" ]; then
  echo "Building release..."
  flutter build ios --release --dart-define="MULL_BUILD=dev $(git rev-parse --short HEAD)" \
    --dart-define=SUPABASE_URL=https://nfuujjyscybqdcfryiwk.supabase.co \
    --dart-define=SUPABASE_ANON_KEY=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im5mdXVqanlzY3licWRjZnJ5aXdrIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODk1NjkzNDcsImV4cCI6MjEwNTE0NTM0N30.TVpPThLe_P5LVgbwa_QnRBlfyIXcJli95cFM7NBvh2M
else
  echo "Using the existing build in build/ios/iphoneos/Runner.app"
fi

# Wireless installs drop. "Connection reset by peer" mid-transfer is not a
# broken build and not a broken pairing, it is Wi-Fi, and the next attempt
# usually goes straight through.
echo "Installing to $DEVICE"
ATTEMPT=1
until xcrun devicectl device install app --device "$DEVICE" build/ios/iphoneos/Runner.app; do
  if [ "$ATTEMPT" -ge 5 ]; then
    echo
    echo "Gave up after $ATTEMPT attempts. Plug the phone in over USB and run:"
    echo "  ./install-phone.sh --install-only"
    exit 1
  fi
  ATTEMPT=$((ATTEMPT + 1))
  echo "Connection dropped. Attempt $ATTEMPT..."
  sleep 3
  DEVICE=$(find_device)
  if [ -z "$DEVICE" ]; then
    echo "Waiting for the phone to come back..."
    while [ -z "$DEVICE" ]; do
      sleep 5
      DEVICE=$(find_device)
    done
  fi
done

echo "Done. Open Mull on the phone."
