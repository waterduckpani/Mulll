-- Authorship and ownership columns become the server's, not the payload's.
--
-- The previous approach was: give created_by a default of auth.uid(), and have
-- the client leave it out. That does not survive PostgREST. Its default write
-- semantics are `missing=null` — a column absent from the payload is written as
-- an explicit NULL rather than falling back to the column default. So every
-- group arrived with created_by = null, failed `with check (created_by =
-- auth.uid())`, and the whole push aborted with a 42501. Groups looked like
-- they simply were not saving.
--
-- `Prefer: missing=default` fixes the insert and breaks the update: the column
-- then joins the `on conflict do update set` list, and updating it is exactly
-- what the grants forbid. Either way the client's payload shape is deciding
-- something it should not.
--
-- So stop negotiating with the payload. A BEFORE trigger stamps these columns
-- on insert and restores them on update, whatever arrived. The client can send
-- them, omit them or get them wrong; the answer is the same. Columns that
-- decide *who someone is* should never be settled by what a client happened to
-- serialise.

-- ------------------------------------------------------- authorship stamping

-- One function per table, spelled out. A single generic version driven by
-- tg_argv and jsonb_populate_record does work, but this file has already cost
-- an evening to a piece of cleverness (a DECLARE default that read OLD on
-- INSERT), and three obvious functions are worth more than one smart one.

create or replace function public.stamp_group_author()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'INSERT' then
    new.created_by := auth.uid();
  else
    new.created_by := old.created_by;   -- authorship never moves
  end if;
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
  if tg_op = 'INSERT' then
    new.created_by := auth.uid();
  else
    new.created_by := old.created_by;
  end if;
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
  if tg_op = 'INSERT' then
    new.claimed_by := auth.uid();
  else
    new.claimed_by := old.claimed_by;
  end if;
  return new;
end;
$$;

create trigger stamp_groups_author
  before insert or update on public.groups
  for each row execute function public.stamp_group_author();

create trigger stamp_expenses_author
  before insert or update on public.expenses
  for each row execute function public.stamp_expense_author();

create trigger stamp_settlements_author
  before insert or update on public.settlements
  for each row execute function public.stamp_settlement_claimer();

-- With the trigger in charge, the column grants no longer have to do the
-- policing — and they must not, because an upsert that mentions the column at
-- all would otherwise fail on privileges before the trigger ever runs.
grant update (created_by) on public.groups to authenticated;
grant update (created_by) on public.expenses to authenticated;
grant update (claimed_by) on public.settlements to authenticated;

-- ------------------------------------------------------------ seat ownership
--
-- Same problem, worse consequence. members.user_id is who a seat belongs to,
-- and the client cannot reliably omit it either — so a device whose copy still
-- says null (because someone claimed their seat after our last pull) would
-- write that null over a real owner and evict them.
--
-- coalesce states the rule directly: a null from a client is not a claim that
-- the seat is unowned, it is the absence of an opinion. Only a non-null value
-- can change anything, and only under the rules below.

create or replace function public.guard_member_identity()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'INSERT' then
    if new.user_id is null then
      return new;                                   -- a placeholder seat
    end if;
    if new.user_id = auth.uid() then
      return new;                                   -- your own seat
    end if;
    if public.is_friend(new.user_id) then
      return new;                                   -- seating a friend, agreed
    end if;
    raise exception 'you can only add someone to a group if you are friends'
      using errcode = '42501';
  end if;

  -- Silence is not an instruction: keep the owner we already have.
  new.user_id := coalesce(new.user_id, old.user_id);

  if new.user_id is distinct from old.user_id then
    if old.user_id is not null then
      raise exception 'this seat is already claimed'
        using errcode = '42501';
    end if;
    if new.user_id is distinct from auth.uid() then
      raise exception 'a seat may only be claimed by the person it belongs to'
        using errcode = '42501';
    end if;
  end if;

  return new;
end;
$$;

-- ------------------------------------------------- settlement guard, adjusted
--
-- guard_settlement_facts rejected any change to claimed_by. That now fights the
-- stamp trigger rather than the client: triggers fire in alphabetical order, so
-- `guard_settlement_facts` runs before `stamp_settlements_author` puts the
-- column back, and it would see the NULL the client's payload carries and
-- refuse the write.
--
-- claimed_by is no longer the guard's business — the stamp owns it outright,
-- and owning it is strictly stronger than checking it.

create or replace function public.guard_settlement_facts()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  is_payee boolean;
begin
  select exists (
    select 1 from public.members m
     where m.id = old.to_member_id and m.user_id = auth.uid()
  ) into is_payee;

  if new.status is distinct from old.status
     or new.confirmed_at is distinct from old.confirmed_at then
    if not is_payee then
      raise exception 'only the person being paid can confirm a settlement'
        using errcode = '42501';
    end if;
  end if;

  if new.group_id          is distinct from old.group_id
     or new.from_member_id is distinct from old.from_member_id
     or new.to_member_id   is distinct from old.to_member_id
     or new.amount         is distinct from old.amount
     or new.utr            is distinct from old.utr then
    if old.status <> 'pending' or auth.uid() is distinct from old.claimed_by then
      raise exception 'a settlement''s facts cannot be changed once confirmed'
        using errcode = '42501';
    end if;
  end if;

  return new;
end;
$$;
