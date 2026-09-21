-- Standing expenses, one-to-one ledgers, and a note on an expense.
--
-- Everything here is additive. Nothing is dropped and nothing changes meaning,
-- because a client that has not been updated yet is still pushing to this
-- schema and must keep working: the app applies edits locally and syncs
-- afterwards, so a column that starts rejecting an older payload does not show
-- up as an error, it shows up weeks later as "my group disappeared".
--
-- `expenses.repeats_monthly` is deliberately left alone for the same reason. It
-- is now derived — true exactly when an expense came off a schedule — but it
-- keeps its NOT NULL DEFAULT false so an older client's payload still satisfies
-- it. PostgREST writes an absent column as NULL rather than applying the
-- default, so a NOT NULL column that stops being sent is a failed push.

-- ------------------------------------------------------------------- groups

-- A trip and the flat are groups. "What I owe Ritu" is not — and inventing a
-- group called "Me and Ritu" is the thing people dislike about split apps. It
-- is the same two-seat ledger underneath, so this is presentation, not
-- arithmetic: nothing in the balance maths reads it.
create type public.group_kind as enum ('group', 'direct');

alter table public.groups
  add column kind public.group_kind not null default 'group';

-- ----------------------------------------------------------------- expenses

alter table public.expenses
  -- "includes Dev's half of the deposit". Free text, no meaning to the ledger.
  add column note text,
  -- Which schedule produced this, if any. An id rather than the old flag,
  -- because "has this period already been added?" has to be answerable
  -- exactly; matching on the description said yes to any expense someone
  -- happened to name "Rent".
  --
  -- ON DELETE SET NULL, never cascade: stopping a schedule must not delete the
  -- rent everyone actually paid. Those were real payments and they stay.
  add column recurring_id uuid;

-- --------------------------------------------------------- recurring expenses

-- The schedule is a separate thing from the expenses it produces, and that
-- separation is the whole design. Rent changes, people move out, and the month
-- somebody was away is a month the split was different — so each occurrence is
-- an ordinary row in `expenses`, editable and deletable on its own, and this
-- table only ever says "this is due again".
--
-- Note there is no server-side scheduler. Nothing in Postgres creates an
-- expense: the client asks the person when a schedule comes round, and what
-- they confirm is what gets written. A cron job here would post last year's
-- rent every month until somebody noticed.
create table public.recurring_expenses (
  id              uuid primary key default gen_random_uuid(),
  group_id        uuid not null references public.groups(id) on delete cascade,
  description     text not null,
  amount          integer not null check (amount > 0),
  payer_member_id uuid not null references public.members(id),
  method          public.split_method not null default 'equal',
  frequency       text not null default 'monthly'
                    check (frequency in ('weekly', 'fortnightly', 'monthly', 'quarterly', 'yearly')),
  -- Plain dates, not timestamps. "The 1st" has to mean the 1st as the person
  -- experiences it; a timestamptz here would put rent on the 31st for anyone
  -- west of the group that set it up.
  next_due        date not null,
  ends_on         date,
  paused          boolean not null default false,
  -- Off by default, and the client still announces what it added. An expense
  -- nobody was told about is an expense nobody checked, and it is moving real
  -- money between real people.
  auto_add        boolean not null default false,
  last_added_on   date,
  created_by      uuid not null references public.profiles(id),
  created_at      timestamptz not null default now(),
  deleted_at      timestamptz,
  check (ends_on is null or ends_on >= next_due)
);

create index recurring_group_idx on public.recurring_expenses (group_id) where deleted_at is null;

-- The resolved split for the schedule, same shape as expense_shares. Worked
-- out on the client so the rounding matches lib/core/split.dart exactly.
create table public.recurring_shares (
  recurring_id  uuid not null references public.recurring_expenses(id) on delete cascade,
  member_id     uuid not null references public.members(id),
  amount        integer not null check (amount >= 0),
  primary key (recurring_id, member_id)
);

alter table public.expenses
  add constraint expenses_recurring_fk
  foreign key (recurring_id) references public.recurring_expenses(id) on delete set null;

-- ---------------------------------------------------------------------- RLS

alter table public.recurring_expenses enable row level security;
alter table public.recurring_shares   enable row level security;

-- The group's business, all of it — same as expenses.
create policy recurring_read on public.recurring_expenses
  for select to authenticated using (public.is_member(group_id));

create policy recurring_insert on public.recurring_expenses
  for insert to authenticated
  with check (public.is_member(group_id) and created_by = auth.uid());

create policy recurring_update on public.recurring_expenses
  for update to authenticated
  using (public.is_member(group_id)) with check (public.is_member(group_id));

create policy recurring_shares_read on public.recurring_shares
  for select to authenticated
  using (
    exists (
      select 1 from public.recurring_expenses r
       where r.id = recurring_id and public.is_member(r.group_id)
    )
  );

create policy recurring_shares_write on public.recurring_shares
  for all to authenticated
  using (
    exists (
      select 1 from public.recurring_expenses r
       where r.id = recurring_id and public.is_member(r.group_id)
    )
  )
  with check (
    exists (
      select 1 from public.recurring_expenses r
       where r.id = recurring_id and public.is_member(r.group_id)
    )
  );

-- ------------------------------------------------------------------- grants
--
-- RLS cannot say "this column is off limits", so the grants do. These lists
-- have to name every column the client legitimately sends: an upsert that
-- touches a column it has not been granted fails the whole batch, and the
-- failure names the statement rather than the column.

-- `kind` joins the list groups already had.
--
-- `created_by` has to stay on both lists, and leaving it off is a trap worth
-- naming. It is the server's column — a trigger restores it on every update —
-- but the client still *sends* it, so PostgREST puts it in the `on conflict do
-- update set` list, and privileges are checked per column before any trigger
-- runs. A revoke that drops it does not quietly ignore the column; it fails
-- the whole upsert with a permission error, which for Mull means every group
-- silently stops syncing.
revoke update on public.groups from authenticated;
grant update (id, name, kind, created_by, deleted_at) on public.groups to authenticated;

revoke update on public.expenses from authenticated;
grant update (id, group_id, description, amount, payer_member_id, method,
              repeats_monthly, recurring_id, note, spent_on, created_by, deleted_at)
  on public.expenses to authenticated;

revoke update on public.recurring_expenses from authenticated;
grant update (id, group_id, description, amount, payer_member_id, method,
              frequency, next_due, ends_on, paused, auto_add, last_added_on,
              created_by, deleted_at)
  on public.recurring_expenses to authenticated;

-- ---------------------------------------------------- authorship, stamped

-- Same rule as groups, expenses and settlements: Mull pushes a whole group at
-- a time, so re-sending one would otherwise stamp this device's id onto every
-- row in it, including schedules somebody else set up. Insert is left alone —
-- the insert policy already checks created_by = auth.uid(), and a check that
-- fails is a clear error, while a trigger that overwrites is a silent one.
create or replace function public.keep_recurring_author()
returns trigger
language plpgsql
as $$
begin
  new.created_by := old.created_by;
  return new;
end;
$$;

create trigger keep_recurring_author
  before update on public.recurring_expenses
  for each row execute function public.keep_recurring_author();

-- ----------------------------------------------------------------- realtime

alter publication supabase_realtime add table public.recurring_expenses;
alter publication supabase_realtime add table public.recurring_shares;
