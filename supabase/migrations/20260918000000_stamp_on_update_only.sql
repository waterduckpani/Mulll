-- The stamp triggers should never have touched INSERT.
--
-- Two problems were being solved and they needed different answers:
--
--   1. On INSERT, created_by must equal the person inserting. The insert policy
--      already says exactly that — `with check (created_by = auth.uid())` — and
--      the client has always supplied it correctly. Nothing was broken here
--      until I "fixed" it: first by removing it from the payload and leaning on
--      a column default that PostgREST overrides with null, then by having a
--      trigger overwrite it. Each attempt replaced a working mechanism with one
--      more thing that could return null.
--
--   2. On UPDATE, created_by must not move. That one is real: Mull pushes whole
--      groups, so re-sending a group stamps this device's id onto every row in
--      it, including expenses somebody else added.
--
-- So: insert is left alone, and the trigger guards only the case that needed
-- guarding. The rule for anything this sensitive is to let the policy check
-- what the client sends rather than to compute it somewhere the client cannot
-- see — a check that fails is a clear error, while a silent overwrite that
-- produces null is a policy violation with no explanation attached.

drop trigger if exists stamp_groups_author on public.groups;
drop trigger if exists stamp_expenses_author on public.expenses;
drop trigger if exists stamp_settlements_author on public.settlements;

create or replace function public.stamp_group_author()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  new.created_by := old.created_by;
  return new;
end;
$$;

create or replace function public.stamp_expense_author()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  new.created_by := old.created_by;
  return new;
end;
$$;

create or replace function public.stamp_settlement_claimer()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  new.claimed_by := old.claimed_by;
  return new;
end;
$$;

create trigger stamp_groups_author
  before update on public.groups
  for each row execute function public.stamp_group_author();

create trigger stamp_expenses_author
  before update on public.expenses
  for each row execute function public.stamp_expense_author();

create trigger stamp_settlements_author
  before update on public.settlements
  for each row execute function public.stamp_settlement_claimer();
