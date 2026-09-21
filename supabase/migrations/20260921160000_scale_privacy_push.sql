-- Getting ready for strangers: privacy, scale and push, before TestFlight.
--
-- Nine sections, each standing on its own:
--
--   1. Who sees your email and phone: nobody who is not your friend.
--   2. A linked seat forgets the contact details it was invited with.
--   3. Friendship policies stop reading profiles.email directly.
--   4. auth.uid() is evaluated once per statement, not once per row.
--   5. Indexes the pull actually needs.
--   6. notify() gets a ceiling, like send_reminder already has.
--   7. Group revisions and per-user broadcast, replacing postgres_changes.
--   8. Push: device tokens, and a trigger that hands each notice to the
--      `push` edge function.
--   9. Old notices are cleared out, and anon loses everything it never used.
--
-- Nothing here changes what the current app sends. A phone on an older build
-- keeps syncing: the pull it makes still works, it just stops getting live
-- updates once section 7 empties the publication, and its two-minute poll
-- covers that.

-- ============================================================ 1. profiles
--
-- Anyone who shared a group with you could read your email and phone, because
-- profiles_shared_groups exposed the whole row. What a group-mate needs is
-- your name and the UPI ID they pay you on, and nothing else.
--
-- Column grants are per role, not per row, so the only way to show email to
-- friends and not to group-mates is to take it out of the table's reach
-- entirely and hand it over through friend_list(), which decides row by row.

revoke select on public.profiles from authenticated, anon;
grant select (id, name, upi_id, created_at) on public.profiles to authenticated;

-- The caller's own address, for policies that used to read it off profiles.
create or replace function public.my_email()
returns text
language sql
stable
security definer
set search_path = public
as $$
  select email from public.profiles where id = auth.uid();
$$;

-- Your friendships, with what each side may know about the other.
--
-- Either side of a request sees the other's name and email: the requester
-- typed the address, and the person being asked needs to know who is asking.
-- A UPI ID only crosses once the request is accepted. Phone never crosses.
create or replace function public.friend_list()
returns table (
  friendship_id   uuid,
  requester_id    uuid,
  addressee_id    uuid,
  addressee_email text,
  status          public.friendship_status,
  other_id        uuid,
  other_name      text,
  other_email     text,
  other_upi_id    text
)
language sql
stable
security definer
set search_path = public
as $$
  select f.id,
         f.requester_id,
         f.addressee_id,
         f.addressee_email,
         f.status,
         p.id,
         p.name,
         p.email,
         case when f.status = 'accepted' then p.upi_id end
    from public.friendships f
    left join public.profiles p
      on p.id = case when f.requester_id = auth.uid() then f.addressee_id else f.requester_id end
   where f.requester_id = auth.uid()
      or f.addressee_id = auth.uid()
      or (f.addressee_id is null and f.addressee_email = public.my_email());
$$;

revoke all on function public.friend_list() from public, anon;
grant execute on function public.friend_list() to authenticated;

-- ======================================================= 2. linked seats
--
-- A seat invited by email keeps that email after its owner claims it, and
-- every member of the group can read seats. So the address you were invited
-- on stayed visible to the whole group for good, next to your real account.
-- Once a seat has an owner it is reached through the account, exactly as its
-- UPI ID already is, and the invite details have done their job.
--
-- Named to sort after guard_member_identity and guard_member_role: triggers
-- fire in name order, and the owner has to be settled before this looks.

create or replace function public.strip_linked_contact()
returns trigger
language plpgsql
as $$
begin
  if new.user_id is not null then
    new.upi_id := null;
    new.email := null;
    new.phone := null;
  end if;
  return new;
end;
$$;

drop trigger if exists strip_linked_vpa on public.members;
drop function if exists public.strip_linked_vpa();
create trigger strip_linked_contact
  before insert or update on public.members
  for each row execute function public.strip_linked_contact();

update public.members
   set email = null, phone = null, upi_id = null
 where user_id is not null
   and (email is not null or phone is not null or upi_id is not null);

-- ================================================= 3. friendship policies
--
-- Both read profiles.email as the caller, which section 1 just revoked.

drop policy if exists friendships_read on public.friendships;
create policy friendships_read on public.friendships
  for select to authenticated
  using (
    requester_id = (select auth.uid())
    or addressee_id = (select auth.uid())
    or addressee_email = (select public.my_email())
  );

drop policy if exists friendships_decline_invite on public.friendships;
create policy friendships_decline_invite on public.friendships
  for delete to authenticated
  using (addressee_id is null and addressee_email = (select public.my_email()));

-- ================================================== 4. auth.uid() per row
--
-- A bare auth.uid() in a policy is re-evaluated for every row the query
-- touches. Wrapped in a select, Postgres runs it once and reuses the answer.
-- Same meaning, and at a few thousand notices per inbox it is the difference
-- that shows. Done by rewriting whatever policies exist rather than restating
-- them, so nothing about who may do what can drift in the copying.

do $$
declare
  p record;
  q text;
  c text;
begin
  for p in
    select policyname, tablename, qual, with_check
      from pg_policies
     where schemaname = 'public'
       and (qual ~ 'auth\.uid\(\)' or with_check ~ 'auth\.uid\(\)')
  loop
    q := p.qual;
    c := p.with_check;
    -- Leave alone anything already wrapped (section 3 above, for one).
    if coalesce(q, '') ~ 'SELECT auth\.uid\(\)' or coalesce(c, '') ~ 'SELECT auth\.uid\(\)' then
      continue;
    end if;
    execute format(
      'alter policy %I on public.%I %s %s',
      p.policyname,
      p.tablename,
      case when q is not null then 'using (' || replace(q, 'auth.uid()', '(select auth.uid())') || ')' else '' end,
      case when c is not null then 'with check (' || replace(c, 'auth.uid()', '(select auth.uid())') || ')' else '' end
    );
  end loop;
end;
$$;

-- ============================================================= 5. indexes
--
-- expenses_group_idx and recurring_group_idx are partial (deleted_at is
-- null), and the pull used to ask for deleted rows too, so neither could be
-- used: every group in a pull meant a scan of every expense in the database.
-- The pull now filters deleted rows out, which the partial indexes serve; the
-- full ones cover the triggers and anything else that looks by group.

create index if not exists expenses_group_all_idx on public.expenses (group_id);
create index if not exists recurring_group_all_idx on public.recurring_expenses (group_id);
create index if not exists expense_shares_member_idx on public.expense_shares (member_id);
create index if not exists notices_actor_idx on public.notices (actor_id, created_at);
create index if not exists groups_created_by_idx on public.groups (created_by);

-- =========================================================== 6. notify()
--
-- send_reminder was counted from day one; notify() was not, so any member
-- could write as many notices as they liked into the group's inboxes. Once
-- those reach a lock screen that is a spam channel. 300 an hour is far past
-- a real evening of adding a trip's expenses for a group of eight, and a
-- sender past it gets nothing delivered rather than an error, because the app
-- fires these and forgets them.

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
  if target_group is not null
     and not (public.is_member(target_group) or public.is_group_creator(target_group)) then
    raise exception 'you are not in that group' using errcode = '42501';
  end if;
  if notice = 'reminder' then
    raise exception 'reminders go through send_reminder, which counts them'
      using errcode = '42501';
  end if;
  if coalesce(array_length(recipients, 1), 0) > 50 then
    raise exception 'too many recipients' using errcode = '22023';
  end if;

  if (select count(*) from public.notices n
       where n.actor_id = auth.uid()
         and n.created_at > now() - interval '1 hour') >= 300 then
    return 0;
  end if;

  with delivered as (
    insert into public.notices (recipient_id, actor_id, kind, group_id, title, body, amount)
    select distinct r, auth.uid(), notice, target_group, left(title, 140), left(coalesce(body, ''), 280), amount
      from unnest(recipients) as r
     where r is distinct from auth.uid()
       and (
         (target_group is not null and exists (
            select 1 from public.members m
             where m.group_id = target_group and m.user_id = r
         ))
         or (target_group is null and public.shares_a_group(r))
       )
    returning 1
  )
  select count(*) into sent from delivered;
  return sent;
end;
$$;

revoke all on function public.notify(uuid, uuid[], public.notice_kind, text, text, integer) from public, anon;
grant execute on function public.notify(uuid, uuid[], public.notice_kind, text, text, integer) to authenticated;

-- ================================================ 7. revisions + broadcast
--
-- How the app used to stay current: six tables in the realtime publication,
-- every change to any row in the database checked against every connected
-- user's RLS, and any hit meaning "download every group you are in, whole".
-- Fine for two phones. At a few thousand it is the thing that falls over:
-- the change stream is single-threaded and each change costs a read per
-- subscriber.
--
-- Instead, each group has a revision that goes up when anything in it
-- changes. A pull asks for the list of (group, revision) — a few bytes a
-- group — and fetches only groups whose revision moved. And instead of the
-- change stream, the trigger that bumps the revision sends one small
-- broadcast to each person in the group, on a private topic only they can
-- join. Nothing about the rows travels over the socket; it only says "look".

create table if not exists public.group_revs (
  group_id   uuid primary key references public.groups(id) on delete cascade,
  rev        bigint not null default 1,
  -- The transaction that last bumped it. One request writing twenty rows is
  -- one revision and one broadcast, not twenty.
  tx         bigint,
  changed_at timestamptz not null default now()
);

alter table public.group_revs enable row level security;

create policy group_revs_read on public.group_revs
  for select to authenticated
  using (public.is_member(group_id) or public.is_group_creator(group_id));

revoke all on public.group_revs from authenticated, anon;
grant select on public.group_revs to authenticated;

insert into public.group_revs (group_id)
select id from public.groups
on conflict (group_id) do nothing;

-- Tells one person something changed. Never lets a broadcast problem reach
-- the write that caused it: a ledger edit must not fail because a socket
-- message could not be queued.
create or replace function public.tell_user(target uuid, event text, payload jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if target is null then
    return;
  end if;
  perform realtime.send(payload, event, 'user:' || target::text, true);
exception when others then
  raise warning 'tell_user(%): %', event, sqlerrm;
end;
$$;

create or replace function public.touch_group(target_group uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  bumped bigint;
  u uuid;
begin
  -- Null, or a group already gone: a cascade from groups deletes the parent
  -- first, and a revision row for it would fail its foreign key at the end of
  -- the statement, taking the delete down with it.
  if target_group is null or not exists (select 1 from public.groups where id = target_group) then
    return;
  end if;

  insert into public.group_revs as r (group_id, rev, tx, changed_at)
  values (target_group, 1, txid_current(), now())
  on conflict (group_id) do update
     set rev = r.rev + 1, tx = excluded.tx, changed_at = excluded.changed_at
   where r.tx is distinct from excluded.tx
  returning rev into bumped;

  -- Already bumped (and told) in this transaction.
  if bumped is null then
    return;
  end if;

  for u in
    select m.user_id from public.members m
     where m.group_id = target_group and m.user_id is not null
  loop
    perform public.tell_user(u, 'group_changed', jsonb_build_object('group_id', target_group, 'rev', bumped));
  end loop;
end;
$$;

create or replace function public.bump_group_rev()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  r jsonb := case when tg_op = 'DELETE' then to_jsonb(old) else to_jsonb(new) end;
  g uuid;
begin
  g := case tg_table_name
         when 'groups' then (r ->> 'id')::uuid
         when 'expense_shares' then (select e.group_id from public.expenses e where e.id = (r ->> 'expense_id')::uuid)
         when 'recurring_shares' then (select x.group_id from public.recurring_expenses x where x.id = (r ->> 'recurring_id')::uuid)
         else (r ->> 'group_id')::uuid
       end;

  perform public.touch_group(g);

  -- Someone losing their seat has to hear about it too, or the group sits on
  -- their phone until the next poll. After the delete they are no longer in
  -- the fan-out above.
  --
  -- Read through jsonb: this trigger runs on seven tables and only members
  -- has user_id, and PL/pgSQL resolves old.user_id even behind a false guard.
  if tg_table_name = 'members' and tg_op <> 'INSERT' then
    if (to_jsonb(old) ->> 'user_id') is not null
       and (tg_op = 'DELETE' or (to_jsonb(new) ->> 'user_id') is distinct from (to_jsonb(old) ->> 'user_id')) then
      perform public.tell_user((to_jsonb(old) ->> 'user_id')::uuid, 'group_changed', jsonb_build_object('group_id', g));
    end if;
  end if;

  return null;
end;
$$;

do $$
declare
  t text;
begin
  foreach t in array array['groups', 'members', 'expenses', 'expense_shares',
                           'settlements', 'recurring_expenses', 'recurring_shares']
  loop
    execute format('drop trigger if exists bump_group_rev on public.%I', t);
    execute format(
      'create trigger bump_group_rev after insert or update or delete on public.%I
         for each row execute function public.bump_group_rev()', t);
  end loop;
end;
$$;

-- The pull's first question: which groups can I see, and at what revision.
-- Driven from members_user_idx, so it costs the same with ten groups in the
-- database or ten million.
create or replace function public.my_group_revs()
returns table (group_id uuid, rev bigint)
language sql
stable
security definer
set search_path = public
as $$
  select g.id, coalesce(r.rev, 0)
    from public.groups g
    left join public.group_revs r on r.group_id = g.id
   where g.deleted_at is null
     and (
       g.id in (select m.group_id from public.members m where m.user_id = auth.uid())
       or g.created_by = auth.uid()
     )
   order by g.created_at, g.id;
$$;

revoke all on function public.my_group_revs() from public, anon;
grant execute on function public.my_group_revs() to authenticated;

-- A new notice goes to its recipient on the same private topic, whole, so
-- the in-app banner needs no second fetch.
create or replace function public.broadcast_notice()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.tell_user(
    new.recipient_id,
    'notice',
    jsonb_build_object(
      'id', new.id, 'kind', new.kind, 'title', new.title, 'body', new.body,
      'amount', new.amount, 'group_id', new.group_id,
      'created_at', new.created_at, 'read_at', new.read_at
    )
  );
  return null;
end;
$$;

drop trigger if exists broadcast_notice on public.notices;
create trigger broadcast_notice
  after insert on public.notices
  for each row execute function public.broadcast_notice();

-- Who may listen on which topic. Only your own, and nobody may send: every
-- message on these topics comes from the triggers above.
drop policy if exists mull_own_topic on realtime.messages;
create policy mull_own_topic on realtime.messages
  for select to authenticated
  using (
    realtime.messages.extension = 'broadcast'
    and (select realtime.topic()) = 'user:' || (select auth.uid())::text
  );

-- The change stream is no longer how anyone hears about anything.
do $$
declare
  t text;
begin
  foreach t in array array['groups', 'members', 'expenses', 'expense_shares', 'settlements',
                           'friendships', 'recurring_expenses', 'recurring_shares', 'notices']
  loop
    if exists (select 1 from pg_publication_tables
                where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
      execute format('alter publication supabase_realtime drop table public.%I', t);
    end if;
  end loop;
end;
$$;

-- ================================================================ 8. push
--
-- A notice already reaches an open app. To reach a locked phone, each notice
-- insert hands its id to the `push` edge function, which looks up the
-- recipient's devices and sends to APNs. pg_net queues the request and sends
-- it after commit, so a rolled-back write never buzzes anyone.
--
-- The function's URL and the secret it checks live in Vault, set once by
-- hand (see supabase/README.md). Until both exist this does nothing, so the
-- migration is safe to apply before the APNs key is.

create extension if not exists pg_net with schema extensions;

create table if not exists public.push_tokens (
  token       text primary key,
  user_id     uuid not null references public.profiles(id) on delete cascade,
  -- Which APNs host takes this token. A build from Xcode talks to the
  -- sandbox; TestFlight and the App Store talk to production.
  environment text not null default 'production' check (environment in ('sandbox', 'production')),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create index if not exists push_tokens_user_idx on public.push_tokens (user_id);

-- No policies and no grants: a device token is only touched through the two
-- functions below, and only the edge function (service role) reads it.
alter table public.push_tokens enable row level security;
revoke all on public.push_tokens from authenticated, anon;

-- Upsert by token, taking ownership. A phone that signs out of one account
-- and into another keeps its token, and the old account must stop getting
-- that phone's pushes.
create or replace function public.register_push_token(device_token text, apns_env text default 'production')
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'sign in first' using errcode = '42501';
  end if;
  if device_token is null or length(device_token) not between 32 and 200 or device_token !~ '^[0-9a-f]+$' then
    raise exception 'not a device token' using errcode = '22023';
  end if;
  if apns_env not in ('sandbox', 'production') then
    raise exception 'unknown APNs environment' using errcode = '22023';
  end if;

  insert into public.push_tokens as p (token, user_id, environment, updated_at)
  values (device_token, auth.uid(), apns_env, now())
  on conflict (token) do update
     set user_id = excluded.user_id, environment = excluded.environment, updated_at = now();

  -- Ten devices is generous; past it the oldest go.
  delete from public.push_tokens p
   where p.user_id = auth.uid()
     and p.token in (
       select t.token from public.push_tokens t
        where t.user_id = auth.uid()
        order by t.updated_at desc
       offset 10
     );
end;
$$;

create or replace function public.unregister_push_token(device_token text)
returns void
language sql
security definer
set search_path = public
as $$
  delete from public.push_tokens p where p.token = device_token and p.user_id = auth.uid();
$$;

revoke all on function public.register_push_token(text, text) from public, anon;
revoke all on function public.unregister_push_token(text) from public, anon;
grant execute on function public.register_push_token(text, text) to authenticated;
grant execute on function public.unregister_push_token(text) to authenticated;

-- Hands a notice to the push function.
--
-- A burst from one person — a trip's worth of expenses added in one sitting —
-- buzzes at most four times in ten minutes; the rest wait in the inbox, and
-- the badge still counts them. Reminders are already capped at two a day and
-- always go.
create or replace function public.push_notice()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  fn_url text;
  secret text;
  recent integer;
begin
  if not exists (select 1 from public.push_tokens t where t.user_id = new.recipient_id) then
    return null;
  end if;

  if new.kind <> 'reminder' then
    select count(*) into recent
      from public.notices n
     where n.recipient_id = new.recipient_id
       and n.actor_id is not distinct from new.actor_id
       and n.created_at > now() - interval '10 minutes'
       and n.id <> new.id;
    if recent >= 4 then
      return null;
    end if;
  end if;

  select decrypted_secret into fn_url from vault.decrypted_secrets where name = 'push_function_url';
  select decrypted_secret into secret from vault.decrypted_secrets where name = 'push_webhook_secret';
  if fn_url is null or secret is null then
    return null;
  end if;

  perform net.http_post(
    url := fn_url,
    body := jsonb_build_object('notice_id', new.id),
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-mull-push-secret', secret),
    timeout_milliseconds := 8000
  );
  return null;
exception when others then
  raise warning 'push_notice: %', sqlerrm;
  return null;
end;
$$;

drop trigger if exists push_notice on public.notices;
create trigger push_notice
  after insert on public.notices
  for each row execute function public.push_notice();

-- ====================================================== 9. housekeeping
--
-- Notices are the one table that only grows. A read notice older than 90
-- days has done its job, and nothing is kept past a year. pg_cron runs it
-- nightly at 03:30 IST.

create extension if not exists pg_cron;

select cron.unschedule(jobid) from cron.job where jobname = 'mull-prune-notices';
select cron.schedule(
  'mull-prune-notices',
  '0 22 * * *',
  $$delete from public.notices
     where (read_at is not null and created_at < now() - interval '90 days')
        or created_at < now() - interval '365 days'$$
);

-- delete_my_account() predates push tokens; they cascade from profiles, so
-- nothing to add there.

-- anon: Supabase grants it everything by default, and Mull never uses it.
-- Every request the app makes is signed in; sign-in itself is GoTrue, not
-- PostgREST. RLS already kept anon out of every row, and each function
-- already refused a null auth.uid(), so this closes nothing that was open.
-- It removes the need for every future table and function to get that right.
--
-- Functions first get an explicit grant to authenticated, because revoking
-- from PUBLIC would otherwise take away what authenticated only had through
-- it. Internal helpers are then taken back from authenticated as well: a
-- client calling touch_group() could broadcast into any group.

grant execute on all functions in schema public to authenticated, service_role;
revoke execute on all functions in schema public from public, anon;
revoke execute on function public.touch_group(uuid) from authenticated;
revoke execute on function public.tell_user(uuid, text, jsonb) from authenticated;
revoke execute on function public.bump_group_rev() from authenticated;
revoke execute on function public.broadcast_notice() from authenticated;
revoke execute on function public.push_notice() from authenticated;

revoke all on all tables in schema public from anon;
revoke all on all sequences in schema public from anon;
-- TRUNCATE ignores RLS entirely. PostgREST cannot issue it, but nothing
-- should be able to.
revoke truncate, trigger, references on all tables in schema public from authenticated;

alter default privileges in schema public revoke all on tables from anon;
alter default privileges in schema public revoke all on sequences from anon;
alter default privileges in schema public revoke execute on functions from public, anon;
alter default privileges in schema public grant execute on functions to authenticated, service_role;
