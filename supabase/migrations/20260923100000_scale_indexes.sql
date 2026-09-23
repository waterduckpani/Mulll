-- What the 2026-09-23 audit found would not survive a large table.
--
-- Nothing here changes what any query returns or what any build sends. Old
-- and new app builds keep working unchanged.
--
--   1. my_group_revs() no longer reads every group to find yours.
--   2. Indexes behind every foreign key a delete has to check.
--   3. report_error() limits how many new errors one source may file a day.
--   4. The nightly notice clean-up gets an index to work from.
--   5. One call to the push function per insert, not one per notice. Deploy
--      the `push` function before applying this: it is what reads the new
--      batched body, and it still reads the old one.

-- ===================================================== 1. my_group_revs()
--
-- "In a group I have a seat in, OR a group I created" is one condition
-- Postgres cannot answer from an index: it walked the whole groups table and
-- tested each row against a hash of your seats. It runs on every pull, for
-- every open app, every two minutes. The same two questions asked separately
-- are two index lookups (members_user_idx, groups_created_by_idx), and UNION
-- removes a group that answers both. Same rows, same order.

create or replace function public.my_group_revs()
returns table (group_id uuid, rev bigint)
language sql
stable
security definer
set search_path = public
as $$
  select g.id, coalesce(r.rev, 0)
    from (
      select m.group_id as id from public.members m where m.user_id = auth.uid()
      union
      select c.id from public.groups c where c.created_by = auth.uid()
    ) mine
    join public.groups g on g.id = mine.id
    left join public.group_revs r on r.group_id = g.id
   where g.deleted_at is null
   order by g.created_at, g.id;
$$;

revoke all on function public.my_group_revs() from public, anon;
grant execute on function public.my_group_revs() to authenticated;

-- ============================================== 2. foreign-key indexes
--
-- Deleting a row makes Postgres check every column that references it. With
-- no index on that column, the check reads the whole table. Removing a seat
-- (leaving a group, taking someone out) checked all of expenses, settlements
-- (twice), schedules and schedule shares; delete_my_account() checked every
-- authorship column. leave_group() also asks "did this seat ever pay or
-- settle" with the same columns. Partial where the column is mostly null.

create index if not exists expenses_payer_idx on public.expenses (payer_member_id);
create index if not exists settlements_from_idx on public.settlements (from_member_id);
create index if not exists settlements_to_idx on public.settlements (to_member_id);
create index if not exists recurring_payer_idx on public.recurring_expenses (payer_member_id);
create index if not exists recurring_shares_member_idx on public.recurring_shares (member_id);
create index if not exists expenses_recurring_idx on public.expenses (recurring_id) where recurring_id is not null;

create index if not exists expenses_created_by_idx on public.expenses (created_by) where created_by is not null;
create index if not exists recurring_created_by_idx on public.recurring_expenses (created_by) where created_by is not null;
create index if not exists settlements_claimed_by_idx on public.settlements (claimed_by) where claimed_by is not null;
create index if not exists settlements_confirmed_by_idx on public.settlements (confirmed_by) where confirmed_by is not null;

-- ================================================== 3. report_error()
--
-- Callable signed out, with one allowance of 300 new errors a day shared by
-- everybody. One script could spend it by noon and every real crash after
-- that went nowhere. Now each source — the caller's address, stored only as a
-- hash, and only for two days — may file 30 new errors a day. Repeats of an
-- error already on file are not limited: they only bump its count. A request
-- with no address to go on falls back to the shared allowance alone.

create table if not exists public.error_report_sources (
  source text not null,
  day    date not null default current_date,
  filed  integer not null default 0,
  primary key (source, day)
);

alter table public.error_report_sources enable row level security;
revoke all on public.error_report_sources from authenticated, anon;

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
  headers json;
  address text;
  n_filed integer;
begin
  if not exists (select 1 from public.error_reports where fingerprint = fp) then
    if (select count(*) from public.error_reports where first_seen > now() - interval '1 day') >= 300 then
      return;
    end if;

    begin
      headers := nullif(current_setting('request.headers', true), '')::json;
    exception when others then
      headers := null;
    end;
    address := trim(split_part(coalesce(headers ->> 'cf-connecting-ip', headers ->> 'x-forwarded-for', ''), ',', 1));
    if address <> '' then
      insert into public.error_report_sources as x (source, day, filed)
      values (md5(address), current_date, 1)
      on conflict (source, day) do update set filed = x.filed + 1
      returning x.filed into n_filed;
      if n_filed > 30 then
        return;
      end if;
    end if;
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

revoke all on function public.report_error(text, text, text, text, text, text) from public;
grant execute on function public.report_error(text, text, text, text, text, text) to anon, authenticated;

select cron.unschedule(jobid) from cron.job where jobname = 'mull-prune-error-sources';
select cron.schedule(
  'mull-prune-error-sources',
  '15 22 * * *',
  $$delete from public.error_report_sources where day < current_date - 1$$
);

-- ============================================ 4. notice clean-up index
--
-- The nightly prune asks by age alone, which no index covered, so it read
-- the whole notices table every night.

create index if not exists notices_created_idx on public.notices (created_at);

-- ================================================ 5. one push call per insert
--
-- push_notice ran once per row, so one expense in a group of eight was eight
-- calls to the edge function. The same rules now run once per statement over
-- every notice it wrote, and hand them over in a single call: `notice_ids`,
-- which the function (deployed first) takes alongside the old `notice_id`.
-- Nothing is sent later than before: an AFTER ROW trigger also fires at the
-- end of its statement, and pg_net sends after commit either way.
--
-- The per-sender limit is the same query. At the end of the statement every
-- row it inserted is visible, exactly as it was to the row trigger; notify()
-- writes one row per recipient, so a statement never counts against itself.

create or replace function public.push_notices()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  fn_url text;
  secret text;
  ids jsonb;
begin
  select coalesce(jsonb_agg(n.id), '[]'::jsonb) into ids
    from new_notices n
   where exists (select 1 from public.push_tokens t where t.user_id = n.recipient_id)
     and (
       n.kind = 'reminder'
       or (select count(*)
             from public.notices o
            where o.recipient_id = n.recipient_id
              and o.actor_id is not distinct from n.actor_id
              and o.created_at > now() - interval '10 minutes'
              and o.id <> n.id) < 4
     );
  if jsonb_array_length(ids) = 0 then
    return null;
  end if;

  select decrypted_secret into fn_url from vault.decrypted_secrets where name = 'push_function_url';
  select decrypted_secret into secret from vault.decrypted_secrets where name = 'push_webhook_secret';
  if fn_url is null or secret is null then
    return null;
  end if;

  perform net.http_post(
    url := fn_url,
    body := jsonb_build_object('notice_ids', ids),
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-mull-push-secret', secret),
    timeout_milliseconds := 8000
  );
  return null;
exception when others then
  raise warning 'push_notices: %', sqlerrm;
  return null;
end;
$$;

revoke execute on function public.push_notices() from public, anon, authenticated;

drop trigger if exists push_notice on public.notices;
drop trigger if exists push_notices on public.notices;
create trigger push_notices
  after insert on public.notices
  referencing new table as new_notices
  for each statement execute function public.push_notices();
