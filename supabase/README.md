# Mull's backend

Only shared ledgers live here. Mull is local-first: everything applies to
`mull.json` on the phone first and goes up afterwards, so the app never waits on
a network call to feel like it worked, and a phone with no signal is a working
Mull. What syncs is what other people can see.

(An earlier Mull also had a wishlist, named lists and a monthly budget. Those
were private to one phone and never had tables here. The app dropped them on
2026-09-19; nothing in this schema changed as a result.)

Money is **whole rupees** everywhere, matching `lib/core/split.dart`. A paise
column would reintroduce exactly the rounding drift those tests exist to
prevent.

## Wiring it up

Nothing here has been run yet — the migration is written but unapplied, because
creating the project is your call, not mine.

**1. Create the project** at [dashboard.supabase.com](https://dashboard.supabase.com).
Region `ap-south-1` (Mumbai) if the users are in India; it is roughly 20–40ms
versus ~180ms from the US.

**2. Push the schema:**

```sh
cd /Users/bharat/Desktop/PROJECTS/Mull
supabase link --project-ref <your-project-ref>
supabase db push
```

**3. Attach custom SMTP.** Supabase will not let you edit email templates on the
built-in mailer, and the templates are what turn a magic link into a code — so
this comes first. Mull uses Resend on `mull.oblunestudio.com`. Authentication →
Emails → SMTP Settings. (Set up and working as of 2026-09-17; this is the
recipe, not a to-do.)

| Field    | Value                           |
| -------- | ------------------------------- |
| Sender   | `noreply@mull.oblunestudio.com` |
| Host     | `smtp.resend.com`               |
| Port     | `465`                           |
| Username | `resend` — the literal word     |
| Password | the Resend API key, `re_…`      |

The API key goes in **Password**; a key in the Username field gives you
`535 authentication failed` and no other clue. The domain must read *Verified*
in Resend first — its DNS names are shown fully-qualified but most panels want
them relative, so `send.mull.oblunestudio.com` is entered as `send.mull`.

Then Authentication → Rate Limits → *emails*: the built-in cap of a couple per
hour does not lift by itself when SMTP is attached. 30/hour is sane; Resend's
free tier caps at 100/day anyway.

**4. Turn on email codes.** Authentication → Providers → Email: enable it,
**turn off "Confirm email"** so a first sign-in does not need a separate click,
and set **Email OTP Length** to `6` — the hosted default is not always six, and
the app hardcodes six in `auth_sheet.dart` and `auth_service.dart`. An 8-digit
code there fails in the cruellest way: the button enables at six characters, so
the user submits the first six digits and is told "That code didn't match."
Then Authentication → Email Templates, and put `{{ .Token }}` in the body of
*both* **Magic Link** and **Confirm signup** — that is what makes Supabase send
a six-digit code instead of a link. Both matter: `signInWithOtp` sends *Confirm
signup* to an address it has never seen and *Magic Link* to one it has, so
fixing only the second gives you a sign-in that works for you and fails for the
first person you hand the app to. Mull asks for a code on purpose: a link has to
leave the app, come back through a URL scheme and land on the right screen, and
every step of that is somewhere a login can get lost.

**5. Run the app with the keys:**

```sh
flutter run \
  --dart-define=SUPABASE_URL=https://xxxx.supabase.co \
  --dart-define=SUPABASE_ANON_KEY=eyJhbGciOi...
```

The anon key is meant to ship in the client. Row-level security is what protects
the data, not the secrecy of that string — which is why every table has policies
and none of them trust the client.

Built without those defines, Mull runs exactly as it does today: groups stay on
the phone and the sign-in sheet says so.

## What the schema does

| Table            | Holds                                                        |
| ---------------- | ------------------------------------------------------------ |
| `profiles`       | one row per account; email or phone can be the identity      |
| `groups`         | a shared ledger, soft-deleted                                 |
| `members`        | a **seat**, not a user — see below                            |
| `expenses`       | who paid, how much, how it was split, soft-deleted            |
| `expense_shares` | the resolved rupee split, summing to the expense              |
| `settlements`    | a claimed payment and whether it has been confirmed, soft-deleted |
| `recurring_expenses` | a standing expense — rent, wifi — and when it is next due |
| `recurring_shares`   | the resolved split for one, same shape as `expense_shares` |

**A schedule is not an expense.** `recurring_expenses` only ever says "this is
due again". Nothing in Postgres creates a row in `expenses` from it — the client
asks the person when it comes round and writes what they confirm. A cron job
here would post last year's rent every month until somebody noticed, and a
schedule that fires while a landlord is putting the rent up is a schedule that
is quietly wrong. Each occurrence is an ordinary expense, editable and deletable
on its own, pointing back with `expenses.recurring_id`.

**`groups.kind`.** `direct` is a two-seat ledger with no name of its own: what
you owe one person, outside any trip or flat. It is presentation, not
arithmetic — nothing in the balance maths reads it — and making it a separate
concept would have meant writing the same ledger, settlement loop and sync
twice.

**Seats, not users.** You add "Ritu" tonight; Ritu may sign up next week, or
never. Until she does, `members.user_id` is null and the seat carries a name, a
way to reach her and maybe a VPA. `claim_invitations()` runs after sign-in and
takes any seat invited by that email or phone — but only into a group where she
has accepted somebody as a friend. Giving a seat an address sends that address a
friend request; accepting it is her consent, and without it anyone who knew her
email could hand her a debt. Everything references `member_id`, never
`user_id`, so a claim never rewrites the ledger. A seat that becomes linked loses
any VPA typed onto it: a linked seat is paid at its owner's own UPI ID and
nowhere else.

**Two-sided settlement.** `status` is `pending` until the person owed confirms.
A single unverified "mark as settled" is what makes other split apps rot: one
side taps it, the other never sees the money, and the balance is wrong forever.
Only `confirmed` moves a balance, and only the payee can confirm — on update
(`guard_settlement_facts`) and on insert (`guard_settlement_insert`). A new row
may arrive confirmed only from the payee, for a payee seat nobody has claimed,
or as an offset written by one of its two parties; anything else is pulled back
to `pending`.

**Offsets.** `settlements.is_offset` marks a row where no money moved: it
cancels an equal debt pointing the other way in another ledger. Owing Ananya
₹2,000 on the trip while she owes you ₹3,000 on the flat is settled by writing
₹2,000 into both, not by anybody sending ₹5,000 in two directions. It is fixed
at insert — an offset that could later be relabelled a real payment would be a
way to claim money was sent — and it is why "You paid Ananya ₹2,000" is never
shown for one.

**Only what changed goes up.** Each group on the phone keeps a print of every
row as the server last had it (`Group.acked`). A push sends only rows that
differ, and a pull keeps any row changed locally and not yet accepted. That is
the offline queue: an edit that fails to push stays marked unsent and is retried
after every successful pull. Shares are replaced, not merged, so taking someone
out of a split removes their share row.

**Deletions have to be said out loud.** An upsert can only ever say "this row
exists". So a row deleted on a phone
used to survive here and come back on that phone's next pull, taking everyone's
balance with it. The client now keeps a tombstone per deletion until the server
has acted on it, and `_applyTombstones` in `groups_sync.dart` turns each one
into a soft delete — or, for a seat, a real one. `members` is the exception
because a seat is not history; the expenses referencing it keep its id.

Removing a settlement is limited to the two people it is between: a confirmed
one is the evidence a debt was cleared, and a third party reopening money
between two others was one long-press away.

**Non-recursive RLS.** A policy on `members` asking "are you a member?" would
consult `members` and run itself again. `is_member()` is `security definer`, so
it reads with the policy suspended, and every other policy asks it rather than
re-deriving the answer.

## Applying a migration

```sh
cd /Users/bharat/Desktop/PROJECTS/Mull
supabase db push
```

`20260919120000_recurring_and_direct.sql` is the one that adds schedules,
one-to-one ledgers and expense notes. It is additive — nothing is dropped and
nothing changes meaning — and the app probes for it once per launch: without it,
groups still sync and schedules simply stay on the phone. That degradation is
deliberate. An upsert naming a column that does not exist fails the *whole*
batch, so a phone that updated ahead of the database would otherwise stop
syncing groups entirely, and the symptom would read as "my expenses vanished on
my other phone" rather than as a pending migration.

`20260920140000_settlement_offsets_and_removal.sql` adds `settlements.is_offset`
and `settlements.deleted_at`, and rewrites `guard_settlement_facts` so removal
is possible without opening a hole in the rule that a confirmed settlement's
facts are frozen. It has its own probe in the client for the same reason as the
one above, so a project sitting between the two migrations keeps everything the
earlier one gave it.

`expenses.repeats_monthly` is deliberately left in place, still `not null
default false`, and the client still sends it. PostgREST writes an absent column
as NULL rather than applying its default, so a NOT NULL column that stops being
sent is a failed push.

## Known gaps

- **No local stack.** No Docker on this machine, so nothing here is tested
  against a local Postgres — the schema was verified by applying it to the live
  project (2026-09-16) and checking each table, the nested select the sync layer
  uses, `claim_seats`, and that RLS genuinely refuses an anon insert. Sign-in
  end-to-end was verified on device 2026-09-17. Future migrations get the same
  treatment: they land on the real project first and are checked by hand.
- **Deleting an account** is `delete_my_account()`: the account, profile,
  friendships and inbox go; the ledgers stay for everyone else, with your seats
  left under your name and no email, phone or VPA. Authorship columns become
  null.
- **Conflict resolution is last-write-wins per row.** Enough for flatmates
  adding expenses minutes apart, not enough for two people editing the same
  expense in the same second.
- **No push notifications yet** — "you owe ₹2,400", "Ritu says she paid", a
  schedule coming due. That is the next piece, and it needs an Edge Function
  plus APNs. Until then a due schedule is only noticed when the app is opened,
  and a reminder is a WhatsApp message the user sends by hand.
- **No pay-by-link yet.** The public page that lets someone pay their share
  without installing Mull is still to build; it is the growth loop.
