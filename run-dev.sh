#!/bin/sh
# Runs Mull against the live Supabase project.
#
# The anon key is meant to ship inside the client — row-level security is what
# protects the data, not the secrecy of this string. The database password is
# the secret, and it is not here and never should be.
#
#   ./run-dev.sh                  the simulator
#   ./run-dev.sh -d <device-id>   somewhere else
#   ./run-dev.sh --sample         seed the mockup data first
#
# --sample used to be on by default, which was a mistake worth remembering:
# loadSample() sets `onboarded = true` and writes itself into mull.json, so one
# run left every later launch opening on somebody else's groups with no
# onboarding and no sign-in. It looked like a broken app rather than leftover
# state.
#
# Running plain `flutter run` with no defines is also supported: Mull skips the
# sign-in gate and stays local-only, with groups on the phone.

set -e

SAMPLE=""
ARGS=""
for arg in "$@"; do
  case "$arg" in
    --sample) SAMPLE="--dart-define=MULL_SAMPLE=true" ;;
    *) ARGS="$ARGS $arg" ;;
  esac
done

# shellcheck disable=SC2086
exec flutter run \
  --dart-define=SUPABASE_URL=https://nfuujjyscybqdcfryiwk.supabase.co \
  --dart-define=SUPABASE_ANON_KEY=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im5mdXVqanlzY3licWRjZnJ5aXdrIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODk1NjkzNDcsImV4cCI6MjEwNTE0NTM0N30.TVpPThLe_P5LVgbwa_QnRBlfyIXcJli95cFM7NBvh2M \
  $SAMPLE \
  $ARGS
