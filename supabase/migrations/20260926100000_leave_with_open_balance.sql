-- Leaving a group with money still open, and payments between other people.
--
-- 1. leave_group() refused anyone who owed or was owed anything, which trapped
-- people in groups they wanted out of. Leaving now detaches the seat as it
-- always did for a settled one: user_id goes to null and the seat keeps your
-- name, so every expense and the balance itself stay on the record for the
-- people still in the group. Only a claim waiting on you to confirm it still
-- blocks, because nobody else can ever answer it.
--
-- 2. guard_settlement_insert() let any member write a payment between two
--    other people — and confirmed it outright when the payee had no account.
--    The app offered exactly that as "Mark as settled" on someone else's debt.
--    A new payment must now come from one of the two people in it. The one
--    exception is two seats that are both placeholders: nobody on either side
--    could ever record it, so whoever keeps the group's books may.
--
--    A bystander's row is skipped (the trigger returns null), not raised: a
--    raise takes down the whole group's push over one row.

-- ====================================================== 1. leave_group()

-- Returns 'deleted' when the seat had no history and could simply go, and
-- 'detached' when it stays in the ledger without you.
create or replace function public.leave_group(target_group uuid)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  me uuid := auth.uid();
  seat public.members%rowtype;
  admins_left integer;
begin
  if me is null then
    raise exception 'sign in first' using errcode = '42501';
  end if;

  select * into seat from public.members
   where group_id = target_group and user_id = me
   for update;
  if not found then
    return 'not_member';
  end if;

  if exists (select 1 from public.groups g where g.id = target_group and g.kind = 'direct') then
    raise exception 'a one-to-one ledger is deleted, not left' using errcode = '22023';
  end if;

  -- An open balance no longer stops anybody leaving. Refusing trapped people
  -- in a group they wanted out of, and it never made the money any more
  -- likely to move. The seat stays in the ledger under their name, so the
  -- debt stays on the record for everyone else; the app tells each person it
  -- is between.
  --
  -- A payment waiting on *you* to confirm still has to be answered first: you
  -- are the only one who can, it is one tap, and once you have gone nobody
  -- could. Claims you sent are fine — the person you paid can still confirm.
  if exists (
    select 1 from public.settlements t
     where t.group_id = target_group and t.deleted_at is null and t.status = 'pending'
       and t.to_member_id = seat.id
  ) then
    raise exception 'a payment to you is still waiting for you to confirm it' using errcode = '23514';
  end if;

  select count(*) into admins_left from public.members m
   where m.group_id = target_group and m.role = 'admin' and m.id <> seat.id;
  if seat.role = 'admin' and admins_left = 0 and exists (
    select 1 from public.members m
     where m.group_id = target_group and m.id <> seat.id and m.user_id is not null
  ) then
    raise exception 'make someone else an admin before leaving' using errcode = '23514';
  end if;

  if not exists (select 1 from public.expenses e where e.payer_member_id = seat.id)
     and not exists (select 1 from public.expense_shares s where s.member_id = seat.id)
     and not exists (select 1 from public.settlements t where t.from_member_id = seat.id or t.to_member_id = seat.id)
     and not exists (select 1 from public.recurring_expenses r where r.payer_member_id = seat.id)
     and not exists (select 1 from public.recurring_shares r where r.member_id = seat.id) then
    delete from public.members where id = seat.id;
    return 'deleted';
  end if;

  perform set_config('mull.leaving', seat.id::text, true);
  update public.members m
     set user_id = null,
         -- The name the others knew you by, fixed at the moment you left.
         name = coalesce(nullif(trim((select p.name from public.profiles p where p.id = me)), ''), m.name),
         -- A linked seat reads its UPI ID from the account, which this seat
         -- stops pointing at. Anyone you leave owing you still needs it, and
         -- everyone in the group could already see it.
         upi_id = (select p.upi_id from public.profiles p where p.id = me),
         role = case when admins_left > 0 then 'member'::public.member_role else m.role end
   where m.id = seat.id;
  perform set_config('mull.leaving', '', true);
  return 'detached';
end;
$$;

revoke all on function public.leave_group(uuid) from public, anon;
grant execute on function public.leave_group(uuid) to authenticated;

-- =========================================== 2. guard_settlement_insert()

create or replace function public.guard_settlement_insert()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  is_payee        boolean;
  is_party        boolean;
  payee_unclaimed boolean;
  both_unclaimed  boolean;
begin
  if exists (select 1 from public.settlements s where s.id = new.id) then
    return new;
  end if;

  select exists (
    select 1 from public.members m
     where m.id = new.to_member_id and m.user_id = auth.uid()
  ) into is_payee;
  select exists (
    select 1 from public.members m
     where m.id in (new.from_member_id, new.to_member_id) and m.user_id = auth.uid()
  ) into is_party;
  select exists (
    select 1 from public.members m
     where m.id = new.to_member_id and m.user_id is null
  ) into payee_unclaimed;
  select not exists (
    select 1 from public.members m
     where m.id in (new.from_member_id, new.to_member_id) and m.user_id is not null
  ) into both_unclaimed;

  -- Somebody else's money. Nothing to write.
  if not is_party and not both_unclaimed then
    return null;
  end if;

  -- An offset from a bystander is not an offset. Relabelled as the ordinary
  -- claim it is, and judged as one below.
  if new.is_offset and not is_party then
    new.is_offset := false;
  end if;

  if new.status <> 'pending' or new.confirmed_at is not null then
    if not (is_payee or payee_unclaimed or (new.is_offset and is_party)) then
      new.status := 'pending';
      new.confirmed_at := null;
    end if;
  end if;

  if new.status = 'confirmed' then
    new.confirmed_by := coalesce(new.confirmed_by, auth.uid());
  end if;
  return new;
end;
$$;
