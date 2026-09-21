-- Closing the gaps the first pass left open.
--
-- The original policies answer "is this person in the group?", which is the
-- right question for reading. They never ask "may this person change *this
-- column*?", and a handful of columns decide who you are rather than what the
-- ledger says. Those are the ones that need narrowing.
--
-- Two shapes of fix appear below, and which one applies depends on the client:
-- Mull pushes whole groups, re-sending every row on every sync. A plain column
-- revoke rejects those unchanged re-sends, so where the app already writes a
-- column the guard is a trigger comparing with `is distinct from` — an
-- unchanged value passes, only a real change is judged. Where the app has no
-- business writing the column at all, the grant is simply withdrawn.

-- ------------------------------------------------------------------ profiles
--
-- The hole worth fixing first.
--
-- `profiles_self` was `for all` with `using (id = auth.uid())`, so an account
-- could rewrite its own row — including `email`. And `claim_seats()` matches an
-- unclaimed seat by `profiles.email`. Chained together:
--
--   1. sign up as anyone@example.com
--   2. update profiles set email = 'victim@gmail.com'
--   3. call claim_seats()
--
-- and you hold every seat ever invited to that address, with the full expense
-- history behind it. The unique index on email stops this only once the victim
-- has an account of their own — and a seat is unclaimed precisely when they do
-- not. `for all` also covered INSERT and DELETE, so deleting the row and
-- re-inserting it was a second way to the same place.
--
-- email and phone are mirrored from auth.users by on_auth_user_created and are
-- not the client's to set. Identity comes from the token, never from a column
-- the holder of that token can write.

drop policy if exists profiles_self on public.profiles;

create policy profiles_read_self on public.profiles
  for select to authenticated
  using (id = auth.uid());

create policy profiles_update_self on public.profiles
  for update to authenticated
  using (id = auth.uid())
  with check (id = auth.uid());

-- RLS cannot say "this column is off limits", so the grants do. The signup
-- trigger is security definer and owned by the table's owner, so it still
-- writes these freely; only the client is held back. The app's saveProfile()
-- touches name and upi_id only, so this costs it nothing.
revoke insert, delete on public.profiles from authenticated;
revoke update on public.profiles from authenticated;
grant update (name, upi_id) on public.profiles to authenticated;

-- ------------------------------------------------------------------- members
--
-- `user_id` is who a seat belongs to. members_insert and members_update let
-- anyone in the group write any column, so any member could set another
-- member's user_id to null — evicting them from a group whose history they are
-- part of — or point a seat at a third party.
--
-- Claiming your own seat stays allowed, which is what claim_seats() does and
-- what the app's own push does for your seat. Everything else is refused.

create or replace function public.guard_member_identity()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  previous uuid := case when tg_op = 'UPDATE' then old.user_id else null end;
begin
  if new.user_id is not distinct from previous then
    return new;                      -- unchanged; the wholesale push lands here
  end if;
  if new.user_id is distinct from auth.uid() then
    raise exception 'a seat may only be claimed by the person it belongs to'
      using errcode = '42501';
  end if;
  if previous is not null then
    raise exception 'this seat is already claimed'
      using errcode = '42501';
  end if;
  return new;
end;
$$;

create trigger guard_member_identity
  before insert or update on public.members
  for each row execute function public.guard_member_identity();

-- --------------------------------------------------------------- settlements
--
-- settlements_confirm exists so only the payee can say the money arrived. It
-- checks *who* is updating but never *what* they change, so the payee could
-- also rewrite the amount, move the payment between members, or edit the UTR
-- that is supposed to be the evidence for it.
--
-- It was also too narrow in a way that broke the app. Mull pushes whole groups,
-- so every sync re-upserts every settlement — and `on conflict do update` runs
-- the UPDATE policy even when the values are identical. Any member who was not
-- the payee therefore failed that policy, and because a push is one try/catch
-- around the whole group, one settlement someone else was owed silently killed
-- the entire sync.
--
-- So the division of labour changes: RLS decides who may touch the table, and
-- the trigger decides which columns each person may actually move. A no-op
-- re-send passes both.

drop policy if exists settlements_confirm on public.settlements;

create policy settlements_update on public.settlements
  for update to authenticated
  using (public.is_member(group_id))
  with check (public.is_member(group_id));

create or replace function public.guard_settlement_facts()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  is_payee boolean;
begin
  -- Who is owed the money. Only they can say it arrived.
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
     or new.utr            is distinct from old.utr
     or new.claimed_by     is distinct from old.claimed_by then
    -- The person who claimed the payment may still correct it, but only while
    -- it is unconfirmed. Once the payee has agreed, the row is evidence and
    -- neither side gets to rewrite it.
    if old.status <> 'pending' or auth.uid() is distinct from old.claimed_by then
      raise exception 'a settlement''s facts cannot be changed once confirmed'
        using errcode = '42501';
    end if;
  end if;

  return new;
end;
$$;

create trigger guard_settlement_facts
  before update on public.settlements
  for each row execute function public.guard_settlement_facts();

-- -------------------------------------------------------- authorship columns
--
-- `created_by` and `claimed_by` are what the insert policies check against.
-- Left writable, a member could reassign authorship after the fact — and the
-- app was doing exactly that by accident, stamping its own id onto every row
-- it re-pushed, including expenses somebody else had added.
--
-- Defaulting them to auth.uid() lets the client stop sending them entirely:
-- the insert still satisfies its policy, and an update cannot touch a column
-- that is not in the payload.

alter table public.groups      alter column created_by set default auth.uid();
alter table public.expenses    alter column created_by set default auth.uid();
alter table public.settlements alter column claimed_by set default auth.uid();

-- The grants below list every column the client legitimately sends, which is
-- every column except the authorship ones. PostgREST's upsert writes each key
-- in the payload into the `do update set` list, so a column the app still sends
-- but is not granted fails the whole batch — the lists have to match what
-- groups_sync.dart actually pushes, not an idea of what it ought to push.

revoke update on public.groups from authenticated;
grant update (id, name, deleted_at) on public.groups to authenticated;

revoke update on public.expenses from authenticated;
grant update (id, group_id, description, amount, payer_member_id, method,
              repeats_monthly, spent_on, deleted_at)
  on public.expenses to authenticated;

revoke update on public.settlements from authenticated;
grant update (id, group_id, from_member_id, to_member_id, amount, status, utr,
              claimed_at, confirmed_at)
  on public.settlements to authenticated;

-- A note on what is deliberately NOT locked down.
--
-- Any member can still edit or delete any seat, expense or split in a group
-- they belong to. That is the intended trust model — a flat splitting rent is
-- not an adversarial system, and a ledger only one person may correct is worse
-- than one anybody can. Soft-deleted groups likewise stay readable to the
-- people who were in them; that is their history, not a leak.
--
-- The lines drawn above are narrower and different in kind: who you are
-- (profiles.email, members.user_id) and what has already been agreed
-- (a confirmed settlement). Those are not the group's to rewrite.
