// Sends one notice to its recipient's phones through APNs.
//
// Called by the database, not by the app: the `push_notice` trigger on
// public.notices posts `{ notice_id }` here through pg_net after the insert
// commits, with a shared secret in `x-mull-push-secret`. JWT verification is
// off for this function (supabase/config.toml) because the caller is
// Postgres, and the secret is what stands in for it.
//
// What the push says is built here from rows only the server can vouch for.
// The notice's own text is written by the sender's app, so it is only ever
// the body: the bold line on the lock screen is the group's name, or the
// sender's account name for a one-to-one ledger. A modified client can put
// what it likes in a notice, but it cannot make it look like it came from
// anyone else.
//
// Secrets (supabase secrets set ...):
//   APNS_KEY_ID          the key's id, from developer.apple.com → Keys
//   APNS_TEAM_ID         B3F76H2UHH
//   APNS_PRIVATE_KEY     the .p8 file's contents, BEGIN/END lines included
//   APNS_TOPIC           in.mull.app
//   PUSH_WEBHOOK_SECRET  the same value as the `push_webhook_secret` Vault entry

import { createClient } from "npm:@supabase/supabase-js@2";
import { importPKCS8, SignJWT } from "npm:jose@5";

const db = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  { auth: { persistSession: false } },
);

const HOSTS = {
  production: "https://api.push.apple.com",
  sandbox: "https://api.sandbox.push.apple.com",
} as const;

// APNs wants a fresh token at most every 20 minutes and refuses one older
// than an hour. A warm function instance reuses it for 40.
let cached: { jwt: string; at: number } | null = null;

async function apnsToken(): Promise<string> {
  if (cached && Date.now() - cached.at < 40 * 60 * 1000) return cached.jwt;
  const key = await importPKCS8(Deno.env.get("APNS_PRIVATE_KEY")!.trim(), "ES256");
  const jwt = await new SignJWT({})
    .setProtectedHeader({ alg: "ES256", kid: Deno.env.get("APNS_KEY_ID")! })
    .setIssuer(Deno.env.get("APNS_TEAM_ID")!)
    .setIssuedAt()
    .sign(key);
  cached = { jwt, at: Date.now() };
  return jwt;
}

function clip(text: string, max: number): string {
  return text.length <= max ? text : text.slice(0, max - 1) + "…";
}

Deno.serve(async (req) => {
  if (req.headers.get("x-mull-push-secret") !== Deno.env.get("PUSH_WEBHOOK_SECRET")) {
    return new Response("forbidden", { status: 403 });
  }
  if (!Deno.env.get("APNS_PRIVATE_KEY")) {
    // Deployed before the key exists. Nothing to do, and not an error.
    return Response.json({ skipped: "no APNs key configured" });
  }

  const { notice_id } = await req.json().catch(() => ({}));
  if (typeof notice_id !== "string") return new Response("bad request", { status: 400 });

  const { data: notice } = await db
    .from("notices")
    .select("id, recipient_id, actor_id, kind, group_id, title, body")
    .eq("id", notice_id)
    .maybeSingle();
  if (!notice) return Response.json({ skipped: "no such notice" });

  const [{ data: tokens }, { data: group }, { data: actor }, { count: unread }] = await Promise.all([
    db.from("push_tokens").select("token, environment").eq("user_id", notice.recipient_id),
    notice.group_id
      ? db.from("groups").select("name, kind").eq("id", notice.group_id).maybeSingle()
      : Promise.resolve({ data: null }),
    notice.actor_id
      ? db.from("profiles").select("name").eq("id", notice.actor_id).maybeSingle()
      : Promise.resolve({ data: null }),
    db.from("notices").select("id", { count: "exact", head: true })
      .eq("recipient_id", notice.recipient_id).is("read_at", null),
  ]);
  if (!tokens?.length) return Response.json({ sent: 0 });

  const actorName = (actor?.name ?? "").trim();
  const heading = group && group.kind !== "direct" && group.name?.trim()
    ? group.name.trim()
    : actorName || "Mull";
  const text = [notice.title, notice.body].filter((s: string) => s && s.trim()).join(" · ");

  const payload = JSON.stringify({
    aps: {
      alert: { title: clip(heading, 60), body: clip(text, 180) },
      badge: unread ?? undefined,
      sound: "default",
      // Stacks one group's notifications together in Notification Centre.
      "thread-id": notice.group_id ?? notice.actor_id ?? "mull",
    },
    notice_id: notice.id,
    group_id: notice.group_id,
    kind: notice.kind,
  });

  const jwt = await apnsToken();
  const topic = Deno.env.get("APNS_TOPIC") ?? "in.mull.app";
  const dead: string[] = [];
  let sent = 0;

  await Promise.all(tokens.map(async ({ token, environment }) => {
    const host = HOSTS[environment as keyof typeof HOSTS] ?? HOSTS.production;
    const res = await fetch(`${host}/3/device/${token}`, {
      method: "POST",
      headers: {
        authorization: `bearer ${jwt}`,
        "apns-topic": topic,
        "apns-push-type": "alert",
        "apns-priority": "10",
        // A day. A notice older than that is in the inbox, and a buzz for it
        // would only be confusing.
        "apns-expiration": String(Math.floor(Date.now() / 1000) + 86400),
      },
      body: payload,
    });
    if (res.ok) {
      sent++;
      return;
    }
    const reason = (await res.json().catch(() => ({}))).reason ?? res.status;
    // Gone for good: uninstalled, or a token for the other environment. The
    // app registers again on its next launch if it is still there.
    if (res.status === 410 || reason === "BadDeviceToken" || reason === "Unregistered" ||
        reason === "DeviceTokenNotForTopic") {
      dead.push(token);
    } else {
      console.error(`apns ${res.status} ${reason}`);
    }
  }));

  if (dead.length) await db.from("push_tokens").delete().in("token", dead);
  return Response.json({ sent, removed: dead.length });
});
