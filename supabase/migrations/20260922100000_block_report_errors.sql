-- Blocking, reporting, and crash reports that stay in India.
--
--   1. Block: a person you block can no longer reach you. Their friend
--      requests, notices and reminders to you are dropped without a word,
--      so blocking cannot be probed for. Ledgers you already share stay:
--      they are other people's records too, and you can leave the group.
--   2. Report: a reason and a note, for whoever runs Mull to read. Only
--      about someone you are actually connected to, and ten a day.
--   3. Error reports: what went wrong in the app, deduplicated by
--      fingerprint and scrubbed of emails and ids, stored here in Mumbai
--      instead of with a crash-reporting company abroad.
--   4. keepalive(): something a scheduled job can call, because a free
--      project with no requests for a week is paused.

-- ================================================================ 1. block

create table if not exists public.blocks (
  blocker_id uuid not null references public.profiles(id) on delete cascade,
  blocked_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (blocker_id, blocked_id),
  check (blocker_id <> blocked_id)
);

create index if not exists blocks_blocked_idx on public.blocks (blocked_id);

alter table public.blocks enable row level security;
revoke all on public.blocks from authenticated, anon;

-- Either direction. Used by the triggers below.
create or replace function public.is_blocked_between(a uuid, b uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.blocks
     where (blocker_id = a and blocked_id = b) or (blocker_id = b and blocked_id = a)
  );
$$;

create or replace function public.block_user(target uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'sign in first' using errcode = '42501';
  end if;
  if target is null or target = auth.uid() then
    raise exception 'nobody to block' using errcode = '22023';
  end if;

  insert into public.blocks (blocker_id, blocked_id) values (auth.uid(), target)
  on conflict do nothing;

  -- A friendship is what lets someone seat you in a new group, so it goes.
  delete from public.friendships f
   where (f.requester_id = auth.uid() and f.addressee_id = target)
      or (f.requester_id = target and f.addressee_id = auth.uid());
end;
$$;

create or replace function public.unblock_user(target uuid)
returns void
language sql
security definer
set search_path = public
as $$
  delete from public.blocks where blocker_id = auth.uid() and blocked_id = target;
$$;

-- Who you have blocked, by name, so they can be unblocked.
create or replace function public.my_blocks()
returns table (user_id uuid, name text, blocked_at timestamptz)
language sql
stable
security definer
set search_path = public
as $$
  select b.blocked_id, coalesce(nullif(trim(p.name), ''), 'Someone'), b.created_at
    from public.blocks b
    join public.profiles p on p.id = b.blocked_id
   where b.blocker_id = auth.uid()
   order by b.created_at desc;
$$;

-- A request between two people with a block between them never lands, and
-- neither does accepting an old one. Dropped rather than refused: an error
-- would tell the blocked person they had been blocked.
create or replace function public.drop_blocked_friendship()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.addressee_id is not null and public.is_blocked_between(new.requester_id, new.addressee_id) then
    return null;
  end if;
  return new;
end;
$$;

drop trigger if exists drop_blocked_friendship on public.friendships;
create trigger drop_blocked_friendship
  before insert or update on public.friendships
  for each row execute function public.drop_blocked_friendship();

-- Nothing from someone you blocked reaches your inbox, or your lock screen:
-- a row dropped here, before insert, never fires broadcast_notice or
-- push_notice, which run after.
create or replace function public.drop_blocked_notice()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.actor_id is not null and exists (
    select 1 from public.blocks
     where blocker_id = new.recipient_id and blocked_id = new.actor_id
  ) then
    return null;
  end if;
  return new;
end;
$$;

drop trigger if exists drop_blocked_notice on public.notices;
create trigger drop_blocked_notice
  before insert on public.notices
  for each row execute function public.drop_blocked_notice();

-- =============================================================== 2. report

create table if not exists public.reports (
  id          uuid primary key default gen_random_uuid(),
  reporter_id uuid references public.profiles(id) on delete set null,
  reported_id uuid references public.profiles(id) on delete set null,
  reason      text not null check (reason in ('spam', 'harassment', 'impersonation', 'other')),
  note        text not null default '',
  created_at  timestamptz not null default now(),
  -- For whoever handles it: open until someone has looked.
  status      text not null default 'open' check (status in ('open', 'actioned', 'dismissed'))
);

create index if not exists reports_open_idx on public.reports (created_at) where status = 'open';
create index if not exists reports_reporter_idx on public.reports (reporter_id, created_at);

-- Read in the dashboard only. Nobody's report is visible to anybody in the app.
alter table public.reports enable row level security;
revoke all on public.reports from authenticated, anon;

create or replace function public.report_user(target uuid, reason text, note text default '', also_block boolean default false)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'sign in first' using errcode = '42501';
  end if;
  if target is null or target = auth.uid() then
    raise exception 'nobody to report' using errcode = '22023';
  end if;
  -- Only someone you are connected to: a friendship in any state, or a
  -- shared group. Otherwise a report is a way to harass a stranger's account.
  if not (
    public.shares_a_group(target)
    or exists (select 1 from public.friendships f
                where (f.requester_id = auth.uid() and f.addressee_id = target)
                   or (f.requester_id = target and f.addressee_id = auth.uid()))
    or exists (select 1 from public.blocks b where b.blocker_id = auth.uid() and b.blocked_id = target)
  ) then
    raise exception 'you can only report someone you know on Mull' using errcode = '42501';
  end if;
  if (select count(*) from public.reports r
       where r.reporter_id = auth.uid() and r.created_at > now() - interval '1 day') >= 10 then
    raise exception 'too many reports today' using errcode = '54000';
  end if;

  insert into public.reports (reporter_id, reported_id, reason, note)
  values (auth.uid(), target, reason, left(coalesce(note, ''), 500));

  if also_block then
    perform public.block_user(target);
  end if;
end;
$$;

-- ======================================================== 3. error reports

create table if not exists public.error_reports (
  fingerprint text primary key,
  kind        text not null default '',
  message     text not null default '',
  stack       text not null default '',
  context     text not null default '',
  app_version text not null default '',
  os          text not null default '',
  count       integer not null default 1,
  first_seen  timestamptz not null default now(),
  last_seen   timestamptz not null default now()
);

create index if not exists error_reports_recent_idx on public.error_reports (last_seen desc);

alter table public.error_reports enable row level security;
revoke all on public.error_reports from authenticated, anon;

-- Emails and uuids out, so a report says what broke and not whose it was.
create or replace function public.scrub(t text, max_len integer)
returns text
language sql
immutable
as $$
  select left(
    regexp_replace(
      regexp_replace(coalesce(t, ''), '[^\s@<>"'']+@[^\s@<>"'']+', '[email]', 'g'),
      '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}', '[id]', 'g'
    ),
    max_len
  );
$$;

-- Callable signed out, because onboarding is where a new user's first
-- errors happen. Bounded so it cannot be used to fill the database: one row
-- per distinct error, at most 300 new ones a day, and everything capped.
create or replace function public.report_error(
  kind text,
  message text,
  stack text default '',
  context text default '',
  app_version text default '',
  os text default ''
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  k text := public.scrub(kind, 120);
  m text := public.scrub(message, 1000);
  s text := public.scrub(stack, 6000);
  fp text := md5(k || '|' || left(m, 200) || '|' || left(s, 800));
begin
  if not exists (select 1 from public.error_reports where fingerprint = fp)
     and (select count(*) from public.error_reports where first_seen > now() - interval '1 day') >= 300 then
    return;
  end if;

  insert into public.error_reports as e (fingerprint, kind, message, stack, context, app_version, os)
  values (fp, k, m, s, public.scrub(context, 500), left(coalesce(app_version, ''), 40), left(coalesce(os, ''), 80))
  on conflict (fingerprint) do update
     set count = least(e.count + 1, 1000000000),
         last_seen = now(),
         app_version = excluded.app_version,
         os = excluded.os;
end;
$$;

-- ============================================================ 4. keepalive

create or replace function public.keepalive()
returns text
language sql
stable
as $$ select 'ok'::text $$;

-- ================================================================ grants

revoke execute on function public.is_blocked_between(uuid, uuid) from public, anon, authenticated;
revoke execute on function public.drop_blocked_friendship() from public, anon, authenticated;
revoke execute on function public.drop_blocked_notice() from public, anon, authenticated;
revoke execute on function public.scrub(text, integer) from public, anon, authenticated;

revoke execute on function public.block_user(uuid) from public, anon;
revoke execute on function public.unblock_user(uuid) from public, anon;
revoke execute on function public.my_blocks() from public, anon;
revoke execute on function public.report_user(uuid, text, text, boolean) from public, anon;
grant execute on function public.block_user(uuid) to authenticated;
grant execute on function public.unblock_user(uuid) to authenticated;
grant execute on function public.my_blocks() to authenticated;
grant execute on function public.report_user(uuid, text, text, boolean) to authenticated;

-- The two things anon may do.
grant execute on function public.report_error(text, text, text, text, text, text) to anon, authenticated;
grant execute on function public.keepalive() to anon, authenticated;

-- Old error reports go after 90 days, with the notices job.
select cron.unschedule(jobid) from cron.job where jobname = 'mull-prune-errors';
select cron.schedule(
  'mull-prune-errors',
  '10 22 * * *',
  $$delete from public.error_reports where last_seen < now() - interval '90 days'$$
);

-- Reports are kept while they are dealt with, and never past a year (the
-- privacy policy says so).
select cron.unschedule(jobid) from cron.job where jobname = 'mull-prune-reports';
select cron.schedule(
  'mull-prune-reports',
  '20 22 * * *',
  $$delete from public.reports where created_at < now() - interval '365 days'$$
);
