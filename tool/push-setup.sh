#!/bin/sh
# Wires up push on the Supabase side. Safe to run again.
#
#   ./tool/push-setup.sh                      deploy, and link the database to it
#   ./tool/push-setup.sh AuthKey_XXXXXXXX.p8  ...and install the APNs key
#
# The key comes from developer.apple.com -> Certificates, IDs & Profiles ->
# Keys -> "+", tick Apple Push Notifications service (APNs), Sandbox &
# Production. Download the .p8 once (Apple never shows it again); the key id
# is the part of the file name after AuthKey_.
#
# The database reaches the function through pg_net with a shared secret, kept
# in Vault on one side and in the function's secrets on the other. It is made
# here, stored in .secrets/push-webhook, and never printed.

set -e
cd "$(dirname "$0")/.."
REF=nfuujjyscybqdcfryiwk

mkdir -p .secrets
if [ ! -s .secrets/push-webhook ]; then
  openssl rand -hex 32 > .secrets/push-webhook
  chmod 600 .secrets/push-webhook
fi
SECRET=$(cat .secrets/push-webhook)

cd supabase
supabase secrets set --project-ref "$REF" \
  PUSH_WEBHOOK_SECRET="$SECRET" APNS_TEAM_ID=B3F76H2UHH APNS_TOPIC=in.mull.app > /dev/null

if [ -n "$1" ]; then
  KEY_ID=$(basename "$1" .p8 | sed 's/^AuthKey_//')
  supabase secrets set --project-ref "$REF" APNS_KEY_ID="$KEY_ID" APNS_PRIVATE_KEY="$(cat "$1")" > /dev/null
  echo "APNs key $KEY_ID installed."
fi

supabase functions deploy push --project-ref "$REF" --no-verify-jwt --use-api

TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT
cat > "$TMP" <<SQL
do \$\$
begin
  perform vault.update_secret(id, 'https://$REF.supabase.co/functions/v1/push')
     from vault.secrets where name = 'push_function_url';
  if not found then
    perform vault.create_secret('https://$REF.supabase.co/functions/v1/push', 'push_function_url');
  end if;
  perform vault.update_secret(id, '$SECRET') from vault.secrets where name = 'push_webhook_secret';
  if not found then
    perform vault.create_secret('$SECRET', 'push_webhook_secret');
  end if;
end \$\$;
SQL
supabase db query --linked -f "$TMP" > /dev/null
echo "Database -> push function linked."
