#!/bin/sh
# Copies every Mull table to this Mac, because the free Supabase plan keeps
# no backups at all.
#
#   ./tool/backup.sh
#
# Writes ~/Documents/Mull backups/<date>/<table>.json and deletes copies
# older than 30 days (the privacy policy promises no longer). Run it weekly,
# or before any migration. Uses the logged-in Supabase CLI, so no database
# password and no Docker.
#
# These files are people's personal data. Keep them on this Mac, and out of
# git, chats and shared drives.
#
# Restoring is by hand: each file is a JSON array of rows for that table.

set -e
cd "$(dirname "$0")/../supabase"

DEST="$HOME/Documents/Mull backups/$(date +%Y-%m-%d)"
mkdir -p "$DEST"
chmod 700 "$HOME/Documents/Mull backups"

for t in profiles friendships groups group_revs members expenses expense_shares settlements \
         recurring_expenses recurring_shares notices push_tokens blocks reports; do
  TMP=$(mktemp)
  echo "select coalesce(json_agg(t), '[]'::json) as rows from public.$t t;" > "$TMP"
  supabase db query --linked -f "$TMP" 2>/dev/null \
    | python3 -c 'import json,sys; json.dump(json.load(sys.stdin)["rows"][0]["rows"], sys.stdout)' \
    > "$DEST/$t.json"
  rm -f "$TMP"
  echo "  $t: $(python3 -c "import json; print(len(json.load(open('$DEST/$t.json'))))" ) rows"
done

find "$HOME/Documents/Mull backups" -mindepth 1 -maxdepth 1 -type d -mtime +30 -exec rm -rf {} +
echo "Saved to $DEST"
