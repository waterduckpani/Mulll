#!/bin/sh
# Creates (or resets) the account Apple's reviewers sign in with.
#
#   ./tool/review-account.sh
#
# Sign-in is by emailed code, and App Review cannot read mail sent to an
# address it does not own. So review@mull.oblunestudio.com signs in with a
# password instead (see AuthService.reviewEmail), typed where the code goes.
#
# The password is made once and kept in .secrets/review-account, which git
# ignores. Paste it into App Store Connect -> App Review Information -> Notes.
# Re-running keeps the password and rebuilds the demo groups, which is also
# the fix if a reviewer deletes the account: it is created again.
#
# Needs the Supabase CLI logged in and linked (it reads the service key from
# it, and the key is never written anywhere).

set -e
cd "$(dirname "$0")/.."

REF=nfuujjyscybqdcfryiwk
URL="https://$REF.supabase.co"
EMAIL=review@mull.oblunestudio.com
SECRET_FILE=.secrets/review-account

mkdir -p .secrets
if [ ! -s "$SECRET_FILE" ]; then
  # Letters and digits only, so it survives being pasted into anything.
  openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 20 > "$SECRET_FILE"
  chmod 600 "$SECRET_FILE"
fi
PASSWORD=$(cat "$SECRET_FILE")

KEY=$(supabase projects api-keys --project-ref "$REF" -o json \
  | python3 -c 'import json,sys; print(next(k["api_key"] for k in json.load(sys.stdin) if k["name"] == "service_role"))')

TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT
printf "select id::text as id from auth.users where email = '%s';" "$EMAIL" > "$TMP"
ID=$(cd supabase && supabase db query --linked -f "$TMP" 2>/dev/null \
  | python3 -c 'import json,sys; r=json.load(sys.stdin)["rows"]; print(r[0]["id"] if r else "")')

if [ -z "$ID" ]; then
  echo "Creating $EMAIL"
  curl -sf -X POST "$URL/auth/v1/admin/users" \
    -H "apikey: $KEY" -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
    -d "{\"email\":\"$EMAIL\",\"password\":\"$PASSWORD\",\"email_confirm\":true,\"user_metadata\":{\"name\":\"App Review\"}}" \
    > /dev/null
else
  echo "Resetting $EMAIL ($ID)"
  curl -sf -X PUT "$URL/auth/v1/admin/users/$ID" \
    -H "apikey: $KEY" -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
    -d "{\"password\":\"$PASSWORD\",\"email_confirm\":true}" \
    > /dev/null
fi

echo "Seeding the demo groups"
(cd supabase && supabase db query --linked -f seed/review_account.sql > /dev/null)

# Proves the sign-in the reviewer will do, end to end, with the public key.
ANON=$(supabase projects api-keys --project-ref "$REF" -o json \
  | python3 -c 'import json,sys; print(next(k["api_key"] for k in json.load(sys.stdin) if k["name"] == "anon"))')
curl -sf -X POST "$URL/auth/v1/token?grant_type=password" \
  -H "apikey: $ANON" -H "Content-Type: application/json" \
  -d "{\"email\":\"$EMAIL\",\"password\":\"$PASSWORD\"}" > /dev/null \
  && echo "Password sign-in works."

echo
echo "For App Store Connect -> App Review Information:"
echo "  Sign-in required: yes"
echo "  User name: $EMAIL"
echo "  Password:  $PASSWORD"
echo "  Notes: Enter the email on the sign-in screen, then enter the password"
echo "         where it asks for the review code. No email is sent."
