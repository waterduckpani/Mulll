-- Netting off between people, and taking a payment back off the record.
--
-- Two things the app could not say before.
--
-- `is_offset` marks a settlement where no money moved: it cancels an equal
-- debt pointing the other way in another ledger. Owing Ananya 2,000 on the
-- trip while she owes you 3,000 on the flat is one fact, and it is settled by
-- writing 2,000 into both ledgers rather than by anybody sending 5,000 in two
-- directions. A row that says "You paid Ananya 2,000" when nothing left your
-- account is the kind of entry that makes someone stop trusting the ledger, so
-- the flag travels with it and the app says what it really is.
--
-- `deleted_at` is the other half of a push. Mull upserts whole groups, which
-- can only ever say "this row exists" — so a settlement deleted on a phone
-- lived on here and came back on that phone's next pull, quietly reopening or
-- reclosing a debt. Soft, like expenses and schedules: money that was once
-- recorded as paid should leave a trace even when it is withdrawn.

alter table public.settlements
  add column if not exists is_offset  boolean not null default false,
  add column if not exists deleted_at timestamptz;

create index if not exists settlements_open_idx
  on public.settlements (group_id) where deleted_at is null;

-- ------------------------------------------------------------------ guard
--
-- `guard_settlement_facts` refuses any change to a settlement's facts once it
-- is confirmed, which is right and would also have made removal impossible.
-- Removal is not a rewrite: the row keeps every number it had and stops
-- counting. So it gets its own rule rather than a hole in that one.
--
-- Only the two people the payment is between. A confirmed settlement is the
-- evidence a debt was cleared, and in a group of eight a third party being
-- able to reopen money between two others was one long-press away.
--
-- `is_offset` is set at insert and never moves: an offset that could be
-- relabelled a real payment afterwards is a way to claim money was sent. The
-- server pins it rather than refusing a write that disagrees, so a stale
-- client costs nothing.
--
-- This is a replacement for the body in 20260917230000, NOT the one in
-- 20260917140000 — the difference matters. The later migration deliberately
-- took `claimed_by` out of the frozen-facts check, because triggers fire in
-- alphabetical order: this one runs before `stamp_settlements_author` puts the
-- column back, so it would see the value the client's payload carries and
-- refuse an ordinary re-push. The stamp owns that column outright, which is
-- strictly stronger than checking it here. Reinstating the check would break
-- every sync that contains a settlement somebody else claimed.

create or replace function public.guard_settlement_facts()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  is_payee boolean;
  is_party boolean;
begin
  select exists (
    select 1 from public.members m
     where m.id = old.to_member_id and m.user_id = auth.uid()
  ) into is_payee;

  select exists (
    select 1 from public.members m
     where m.id in (old.from_member_id, old.to_member_id) and m.user_id = auth.uid()
  ) into is_party;

  if new.deleted_at is distinct from old.deleted_at then
    if not is_party then
      raise exception 'only the two people a payment is between can remove it'
        using errcode = '42501';
    end if;
  end if;

  -- Whether a row is an offset is fixed when it is made, and the server owns
  -- it outright rather than checking it. Refusing the write would have been
  -- the obvious thing and the wrong one: a client that probed for the column
  -- once, failed, and cached the answer pushes `false` for a row that is
  -- `true` here, and a raise would take down the whole group's sync over a
  -- field the client has no opinion about. Same rule as `guard_member_identity`
  -- and `user_id` — silence from a client is not a claim.
  new.is_offset := old.is_offset;

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

-- The grant lists every column the client sends. PostgREST's upsert writes
-- each key in the payload into the `do update set` list, so a column the app
-- sends but is not granted fails the whole batch — this list has to match what
-- groups_sync.dart actually pushes.
--
-- `claimed_by` is in it. A revoke here wipes the column-level grant that
-- 20260917230000 added in a statement of its own, and the client sends that
-- column on every settlement it pushes, so leaving it out would have made
-- every group containing a settlement fail to sync.

revoke update on public.settlements from authenticated;
grant update (id, group_id, from_member_id, to_member_id, amount, status, utr,
              is_offset, claimed_at, claimed_by, confirmed_at, deleted_at)
  on public.settlements to authenticated;
