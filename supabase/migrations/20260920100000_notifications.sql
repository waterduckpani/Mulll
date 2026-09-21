-- Telling the right people that something happened.
--
-- Mull's whole pitch is that the ledger stops living in a WhatsApp group, and
-- until now the app kept handing the important moments straight back to
-- WhatsApp: a reminder opened a chat with a pre-written message in it. That is
-- the one feature that guarantees people keep the chat open, and it means the
-- app has no idea whether anyone was told.
--
-- Two rules shape this table, and they are the reasons it is not a broadcast:
--
--   1. **Only the parties.** An expense reaches the people in the split, a
--      settlement reaches the two people involved, a reminder reaches one
--      person. A group of eight is not eight buzzes every time somebody adds a
--      chai.
--   2. **A reminder has a ceiling.** Twice a day, per pair, counted here rather
--      than on the phone that is doing the reminding. A limit the sender's own
--      app enforces is a limit the sender can lift by reinstalling, and nagging
--      is the failure mode that gets a split app deleted.
--
-- There is no push here and no device tokens. A notification is a row; the
-- recipient's app is subscribed to its own rows and shows them. Bolting APNs on
-- later means reading this table from an edge function, not reshaping it.

create type public.notice_kind as enum (
  'expense_added',
  'expense_removed',
  'settlement_claimed',
  'settlement_confirmed',
  'settlement_disputed',
  'reminder',
  'added_to_group'
);

create table public.notices (
  id           uuid primary key default gen_random_uuid(),
  -- Who is being told. Always exactly one person: a row per recipient rather
  -- than a row per event with an audience attached, so "have I read this" is a
  -- column and not a join.
  recipient_id uuid not null references public.profiles(id) on delete cascade,
  -- Who did it. Null once that account is gone; the notice still makes sense.
  actor_id     uuid references public.profiles(id) on delete set null,
  kind         public.notice_kind not null,
  group_id     uuid references public.groups(id) on delete cascade,
  -- Written by the sender, in the sender's words, because only the sending app
  -- knows the context: which group, whose share, what it was for. Storing the
  -- sentence rather than the ingredients also means an older app can display a
  -- notice about something it does not have a template for.
  title        text not null,
  body         text not null default '',
  -- Whole rupees, like everywhere else. Null when the notice is not about an
  -- amount.
  amount       integer,
  created_at   timestamptz not null default now(),
  read_at      timestamptz
);

create index notices_inbox_idx
  on public.notices (recipient_id, created_at desc);

create index notices_unread_idx
  on public.notices (recipient_id) where read_at is null;

-- Reminders are counted, so they are looked up by pair and day.
create index notices_reminder_rate_idx
  on public.notices (actor_id, recipient_id, created_at)
  where kind = 'reminder';

-- ---------------------------------------------------------------------- RLS

alter table public.notices enable row level security;

-- Your inbox is yours. Nobody reads anybody else's — not even someone in the
-- same group, who can already see the underlying expense but has no business
-- knowing who has been reminded and how often.
create policy notices_read on public.notices
  for select to authenticated
  using (recipient_id = auth.uid());

-- Marking one read is the only thing a client may change, and only on its own.
create policy notices_update on public.notices
  for update to authenticated
  using (recipient_id = auth.uid())
  with check (recipient_id = auth.uid());

create policy notices_delete on public.notices
  for delete to authenticated
  using (recipient_id = auth.uid());

-- Deliberately no insert policy.
--
-- Writing into someone else's inbox is not a thing a client gets to do
-- directly. Every notice goes through one of the functions below, which decide
-- who is allowed to tell whom, and how often. Without this the rate limit is
-- decoration: anyone could insert twenty reminder rows in a loop.
revoke insert on public.notices from authenticated;
revoke update on public.notices from authenticated;
-- Spelled out rather than left to whatever the project's default privileges
-- happen to be. `read_at` is the only column a client may move: the text, the
-- amount and who sent it are the record of what was said, and a recipient who
-- could edit them could rewrite a reminder into something nobody sent.
grant select, delete on public.notices to authenticated;
grant update (read_at) on public.notices to authenticated;

-- --------------------------------------------------------------- who may tell

-- Two people who share a group. The reach of a notification is exactly this:
-- if you can already see someone's share of a bill, you can tell them about it.
create or replace function public.shares_a_group(other uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
      from public.members mine
      join public.members theirs on theirs.group_id = mine.group_id
     where mine.user_id = auth.uid()
       and theirs.user_id = other
  );
$$;

revoke all on function public.shares_a_group(uuid) from public;
grant execute on function public.shares_a_group(uuid) to authenticated;

-- ------------------------------------------------------------------- sending

-- The ordinary case: something happened in a group, tell the people it
-- happened to.
--
-- The recipient list comes from the client because only the client knows who
-- the parties were — who is in this split, who is on the other end of this
-- payment. What the client does *not* get to decide is whether it may reach
-- them, which is what the membership check is for. Anyone not in the group is
-- dropped silently rather than failing the call: a stale member id on one
-- phone should not stop the other four people being told.
create or replace function public.notify(
  target_group uuid,
  recipients   uuid[],
  notice       public.notice_kind,
  title        text,
  body         text default '',
  amount       integer default null
)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  sent integer;
begin
  if auth.uid() is null then
    raise exception 'sign in first' using errcode = '42501';
  end if;

  -- You may only announce things in a group you are in. Without this, knowing
  -- a group's uuid would be enough to write into every member's inbox.
  if target_group is not null and not public.is_member(target_group) then
    raise exception 'you are not in that group' using errcode = '42501';
  end if;

  if notice = 'reminder' then
    raise exception 'reminders go through send_reminder, which counts them'
      using errcode = '42501';
  end if;

  with delivered as (
    insert into public.notices (recipient_id, actor_id, kind, group_id, title, body, amount)
    select r, auth.uid(), notice, target_group, title, body, amount
      from unnest(recipients) as r
      -- Never tell someone what they just did themselves.
     where r is distinct from auth.uid()
       and (
         target_group is null
         or exists (
           select 1 from public.members m
            where m.group_id = target_group and m.user_id = r
         )
       )
    returning 1
  )
  select count(*) into sent from delivered;

  return sent;
end;
$$;

revoke all on function public.notify(uuid, uuid[], public.notice_kind, text, text, integer) from public;
grant execute on function public.notify(uuid, uuid[], public.notice_kind, text, text, integer) to authenticated;

-- How many reminders one person may send another in a day.
--
-- Two. One is a favour; the second is a fair "did you see this?"; the third is
-- nagging, and the app should not be the thing that makes nagging effortless.
create or replace function public.reminder_allowance()
returns integer
language sql
immutable
as $$ select 2 $$;

-- A reminder, counted.
--
-- Returns 'sent' when it went, or 'limit' when today's allowance is used up.
-- A rolling 24 hours rather than a calendar day, because midnight is not a
-- reset anyone experiences: two at 11pm and two more at 12:05am is four
-- buzzes inside ten minutes, and technically within the rules.
create or replace function public.send_reminder(
  target uuid,
  target_group uuid,
  title text,
  body text default '',
  amount integer default null
)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  already integer;
begin
  if auth.uid() is null then
    raise exception 'sign in first' using errcode = '42501';
  end if;
  if target = auth.uid() then
    raise exception 'you cannot remind yourself' using errcode = '22023';
  end if;
  if not public.shares_a_group(target) then
    raise exception 'you can only remind someone you share a group with'
      using errcode = '42501';
  end if;

  select count(*) into already
    from public.notices n
   where n.kind = 'reminder'
     and n.actor_id = auth.uid()
     and n.recipient_id = target
     and n.created_at > now() - interval '24 hours';

  if already >= public.reminder_allowance() then
    return 'limit';
  end if;

  insert into public.notices (recipient_id, actor_id, kind, group_id, title, body, amount)
  values (target, auth.uid(), 'reminder', target_group, title, body, amount);

  return 'sent';
end;
$$;

revoke all on function public.send_reminder(uuid, uuid, text, text, integer) from public;
grant execute on function public.send_reminder(uuid, uuid, text, text, integer) to authenticated;

-- What is left of today's allowance, so the button can say so before it is
-- pressed. A "Remind" that fails after the tap teaches people to tap it twice.
create or replace function public.reminders_left(target uuid)
returns integer
language sql
stable
security definer
set search_path = public
as $$
  select greatest(
    0,
    public.reminder_allowance() - (
      select count(*)
        from public.notices n
       where n.kind = 'reminder'
         and n.actor_id = auth.uid()
         and n.recipient_id = target
         and n.created_at > now() - interval '24 hours'
    )
  )::integer;
$$;

revoke all on function public.reminders_left(uuid) from public;
grant execute on function public.reminders_left(uuid) to authenticated;

-- ----------------------------------------------------------------- realtime

-- This is the delivery mechanism, not a nicety: the recipient's app subscribes
-- to its own rows and a notice lands while they are looking at the screen.
alter publication supabase_realtime add table public.notices;
