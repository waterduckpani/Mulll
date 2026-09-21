#!/bin/sh
# Builds a TestFlight / App Store upload.
#
#   ./tool/testflight.sh
#
# Then, in Xcode's Organizer window (it opens on the archive this makes):
#   Distribute App -> App Store Connect -> Upload
# The build shows up in App Store Connect -> TestFlight after processing,
# usually 10-30 minutes.
#
# The build number is the commit count, so it only goes up and two uploads
# never collide. Commit before running: the same commit cannot be uploaded
# twice.
#
# Errors from this build land in the error_reports table, tagged with its
# version and build number.

set -e
cd "$(dirname "$0")/.."

if [ -n "$(git status --porcelain)" ]; then
  echo "Uncommitted changes. Commit first, so this build is a commit you can find again."
  exit 1
fi

# The typefaces are not in git (see tool/fetch-fonts.sh).
[ -f assets/fonts/Ranade-Regular.otf ] || ./tool/fetch-fonts.sh

BUILD=$(git rev-list --count HEAD)
VERSION=$(sed -n 's/^version: \([0-9.]*\).*/\1/p' pubspec.yaml)

echo "Building Mull $VERSION ($BUILD)"
flutter build ipa --release \
  --build-name="$VERSION" --build-number="$BUILD" \
  --dart-define=SUPABASE_URL=https://nfuujjyscybqdcfryiwk.supabase.co \
  --dart-define=SUPABASE_ANON_KEY=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im5mdXVqanlzY3licWRjZnJ5aXdrIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODk1NjkzNDcsImV4cCI6MjEwNTE0NTM0N30.TVpPThLe_P5LVgbwa_QnRBlfyIXcJli95cFM7NBvh2M \
  --dart-define="MULL_BUILD=$VERSION ($BUILD)"

# Never ship the sample data: it is not in this build unless MULL_SAMPLE is
# defined, and it is not, above. Said here because it has leaked before.
open build/ios/archive/Runner.xcarchive
