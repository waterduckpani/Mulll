-- What the 2026-09-21 audit found on the server side.
--
-- Eight separate holes, fixed in one migration because they were found
-- together and none of them makes sense applied without the rest. Every
-- function replaced here is rebuilt on its *latest* body — several of them
-- exist in two or three versions in the history, and building on an older one
-- reinstates a bug a later migration fixed.

-- ------------------------------------------------ 1. confirming on insert
--
-- guard_settlement_facts only ever ran on UPDATE. So the rule "only the payee
-- can say the money arrived" held for a claim that already existed, and not at
-- all for a new one: any member could insert a settlement that was already
-- `confirmed` and clear their own debt without the other person ever seeing
-- it. That is the one promise Mull makes that other split apps do not.
--
-- A new row may arrive confirmed in exactly three cases, which are the three
-- the app itself produces:
--   - the payee is recording money they received;
--   - the payee's seat is a placeholder nobody has claimed, so nobody exists
--     who could confirm it and waiting would leave the debt open forever;
--   - it is an offset written by one of the two people it is between. No
--     money is claimed to have moved and neither side's net position changes.
--
-- Anything else is pulled back to `pending` rather than refused. A raise would
-- take down the whole group's push over one row, and the client converges on
-- the server's answer at its next pull anyway.
--
-- BEFORE INSERT fires for every proposed row of an upsert, including re-sends
-- that are about to take the ON CONFLICT path (see the 2026-09-20 migration).
-- Those are judged by guard_settlement_facts on the update side, so they
-- return here untouched.

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

drop trigger if exists guard_settlement_insert on public.settlements;
create trigger guard_settlement_insert
  before insert on public.settlements
  for each row execute function public.guard_settlement_insert();

-- The update side, rebuilt on the 2026-09-20 body. One change: a status move
-- by someone who is not the payee is now pinned back instead of raised. The
-- raise was right in intent and wrong in effect — a phone holding a stale copy
-- (its insert was pulled back to pending above, say) would re-send the old
-- status on its next edit and lose the whole group's sync to it. The payee is
-- still the only person who can actually move it, which is the rule.

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
  if current_setting('mull.erasing', true) = 'on' then
    return new;                        -- an account being deleted; see 7
  end if;

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

  new.is_offset := old.is_offset;

  if (new.status is distinct from old.status
      or new.confirmed_at is distinct from old.confirmed_at)
     and not is_payee then
    new.status := old.status;
    new.confirmed_at := old.confirmed_at;
  end if;

  if new.status = 'confirmed' and old.status <> 'confirmed' then
    new.confirmed_by := auth.uid();
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

-- confirmed_by is now written by the triggers above. It was never in the
-- client's grant list and still is not; the grant below repeats the
-- 2026-09-20 list exactly, claimed_by included, because a revoke wipes the
-- column grant that migration relies on.
revoke update on public.settlements from authenticated;
grant update (id, group_id, from_member_id, to_member_id, amount, status, utr,
              is_offset, claimed_at, claimed_by, confirmed_at, deleted_at)
  on public.settlements to authenticated;

-- ---------------------------------------------------- 2. missing notice kinds
--
-- The app sends these three and the enum never had them, so every one failed
-- inside notify() with "invalid input value for enum" and the client logged it
-- and moved on. An expense edited from ₹500 to ₹5,000, a confirmed payment
-- taken back off the record, and a net-off were all silent.

alter type public.notice_kind add value if not exists 'expense_changed';
alter type public.notice_kind add value if not exists 'settlement_removed';
alter type public.notice_kind add value if not exists 'netted_off';

-- ------------------------------------------------------ 3. who may be told
--
-- notify() checked membership only when a group was named. With no group it
-- delivered to any account id at all, any number of times, with any text: a
-- free phishing channel into anybody's inbox. A notice with no group (a
-- net-off spans several) now needs the recipient to share at least one group
-- with the sender, and every notice is held to a length a banner can show.

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

revoke all on function public.notify(uuid, uuid[], public.notice_kind, text, text, integer) from public;
grant execute on function public.notify(uuid, uuid[], public.notice_kind, text, text, integer) to authenticated;

-- send_reminder took target_group on trust, so a reminder could be filed
-- against a group neither person is in. It now has to be one both are in.
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
  if target_group is not null and not (
    public.is_member(target_group)
    and exists (select 1 from public.members m where m.group_id = target_group and m.user_id = target)
  ) then
    raise exception 'you are not both in that group' using errcode = '42501';
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
  values (target, auth.uid(), 'reminder', target_group, left(title, 140), left(coalesce(body, ''), 280), amount);
  return 'sent';
end;
$$;

revoke all on function public.send_reminder(uuid, uuid, text, text, integer) from public;
grant execute on function public.send_reminder(uuid, uuid, text, text, integer) to authenticated;

-- ------------------------------------------- 4. being put into a group by email
--
-- Anyone who knew your address could make a placeholder seat with it, add
-- ₹50,000 of expenses, and claim_invitations() would hand you the seat the
-- next time you opened Mull — the friends gate that guards seating a *linked*
-- account (guard_member_identity) did not apply to seats claimed this way.
--
-- A seat is now only claimed into a group where somebody you have accepted as
-- a friend already sits. The app sends a friend request to the address when a
-- seat is given one, so the ordinary path — Bharat adds Ritu to the flat by
-- email, Ritu signs up — becomes: Ritu sees Bharat's request, accepts it, and
-- the flat's history is hers. The acceptance is the consent.
--
-- Also fixed: a person invited to the same group by both email and phone
-- matched two seats in one statement, the unique index on (group_id, user_id)
-- refused the second, and the whole claim failed — every group, not just that
-- one. One seat per group now, the oldest.

create or replace function public.claim_invitations()
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  my_email text;
  my_phone text;
  seats    integer := 0;
  friends  integer := 0;
begin
  select email, phone into my_email, my_phone from public.profiles where id = auth.uid();
  if my_email is null and my_phone is null then
    return json_build_object('seats', 0, 'friends', 0);
  end if;

  -- Friend requests first: a request sent to this address before the account
  -- existed is what the seat claim below looks for, once it is accepted.
  with linked as (
    update public.friendships f
       set addressee_id = auth.uid(),
           addressee_email = null
     where f.addressee_id is null
       and my_email is not null
       and f.addressee_email = my_email
       and f.requester_id <> auth.uid()
       and not exists (
         select 1 from public.friendships other
          where (other.requester_id = f.requester_id and other.addressee_id = auth.uid())
             or (other.addressee_id = f.requester_id and other.requester_id = auth.uid())
       )
    returning 1
  )
  select count(*) into friends from linked;

  with candidates as (
    select distinct on (m.group_id) m.id
      from public.members m
     where (
             (my_email is not null and m.email = my_email)
             or (my_phone is not null and m.phone = my_phone)
           )
       and m.user_id is null
       and not exists (
         select 1 from public.members other
          where other.group_id = m.group_id and other.user_id = auth.uid()
       )
       and exists (
         select 1 from public.members inviter
          where inviter.group_id = m.group_id
            and inviter.user_id is not null
            and inviter.user_id <> auth.uid()
            and public.is_friend(inviter.user_id)
       )
     order by m.group_id, m.created_at, m.id
  ), taken as (
    update public.members m
       set user_id = auth.uid()
     where m.id in (select id from candidates)
    returning 1
  )
  select count(*) into seats from taken;

  return json_build_object('seats', seats, 'friends', friends);
end;
$$;

revoke all on function public.claim_invitations() from public;
grant execute on function public.claim_invitations() to authenticated;

-- --------------------------------------------- 5. a linked seat has no VPA
--
-- members.upi_id is writable by any member, and the pull fell back to it when
-- the account behind a seat had no UPI ID of its own. So one flatmate could
-- write their own handle onto another's seat and collect the next payment
-- meant for them. A seat with an account behind it takes its VPA from that
-- account and nowhere else; the column is cleared whenever the seat is linked,
-- including at the moment it is claimed, so a handle the payer typed for a
-- placeholder does not survive the real person turning up.
--
-- Named to sort after guard_member_identity, which is what coalesces a null
-- user_id back to the owner: triggers fire in name order.

create or replace function public.strip_linked_vpa()
returns trigger
language plpgsql
as $$
begin
  if new.user_id is not null then
    new.upi_id := null;
  end if;
  return new;
end;
$$;

drop trigger if exists strip_linked_vpa on public.members;
create trigger strip_linked_vpa
  before insert or update on public.members
  for each row execute function public.strip_linked_vpa();

update public.members set upi_id = null where user_id is not null and upi_id is not null;

-- ------------------------------------------- 6. seats belong to their group
--
-- Nothing checked that an expense's payer, a share, or either end of a
-- settlement was a seat in the *same* group. The app never gets this wrong;
-- a hand-made request could, and a share pointing into another group moves a
-- balance somewhere nobody can see it.

create or replace function public.seat_in_group(seat uuid, target_group uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from public.members m where m.id = seat and m.group_id = target_group);
$$;

revoke all on function public.seat_in_group(uuid, uuid) from public;
grant execute on function public.seat_in_group(uuid, uuid) to authenticated;

create or replace function public.guard_seats_in_group()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  target_group uuid;
begin
  case tg_table_name
    when 'expenses', 'recurring_expenses' then
      if not public.seat_in_group(new.payer_member_id, new.group_id) then
        raise exception 'the payer is not in this group' using errcode = '23503';
      end if;
    when 'settlements' then
      if not (public.seat_in_group(new.from_member_id, new.group_id)
              and public.seat_in_group(new.to_member_id, new.group_id)) then
        raise exception 'both ends of a payment have to be in its group' using errcode = '23503';
      end if;
    when 'expense_shares' then
      select e.group_id into target_group from public.expenses e where e.id = new.expense_id;
      if not public.seat_in_group(new.member_id, target_group) then
        raise exception 'a share has to belong to someone in the group' using errcode = '23503';
      end if;
    when 'recurring_shares' then
      select r.group_id into target_group from public.recurring_expenses r where r.id = new.recurring_id;
      if not public.seat_in_group(new.member_id, target_group) then
        raise exception 'a share has to belong to someone in the group' using errcode = '23503';
      end if;
  end case;
  return new;
end;
$$;

do $$
declare
  t text;
begin
  foreach t in array array['expenses', 'recurring_expenses', 'settlements', 'expense_shares', 'recurring_shares'] loop
    execute format('drop trigger if exists guard_seats_in_group on public.%I', t);
    execute format(
      'create trigger guard_seats_in_group before insert or update on public.%I
         for each row execute function public.guard_seats_in_group()', t);
  end loop;
end;
$$;

-- -------------------------------------------------- 7. deleting an account
--
-- The App Store requires it, and the schema made it impossible: authorship
-- columns referenced profiles with no ON DELETE, so removing a user failed on
-- the first expense they had ever added.
--
-- What deleting means here: the account, the profile, its friendships and its
-- inbox go. The ledger does not — the expenses other people split with you
-- are their history too. Your seats stay, under the name they had, as
-- placeholders with no email, phone or VPA, so nobody can later claim them by
-- signing up on your old address. Authorship becomes null.
--
-- The stamp and guard triggers all restore old values on update, and an
-- ON DELETE SET NULL is an update as far as triggers are concerned — so each
-- one steps aside while `mull.erasing` is set, which only delete_my_account()
-- sets, and only for its own transaction.

alter table public.groups             alter column created_by drop not null;
alter table public.expenses           alter column created_by drop not null;
alter table public.settlements        alter column claimed_by drop not null;
alter table public.recurring_expenses alter column created_by drop not null;

alter table public.groups
  drop constraint if exists groups_created_by_fkey,
  add constraint groups_created_by_fkey foreign key (created_by) references public.profiles(id) on delete set null;
alter table public.expenses
  drop constraint if exists expenses_created_by_fkey,
  add constraint expenses_created_by_fkey foreign key (created_by) references public.profiles(id) on delete set null;
alter table public.recurring_expenses
  drop constraint if exists recurring_expenses_created_by_fkey,
  add constraint recurring_expenses_created_by_fkey foreign key (created_by) references public.profiles(id) on delete set null;
alter table public.settlements
  drop constraint if exists settlements_claimed_by_fkey,
  add constraint settlements_claimed_by_fkey foreign key (claimed_by) references public.profiles(id) on delete set null,
  drop constraint if exists settlements_confirmed_by_fkey,
  add constraint settlements_confirmed_by_fkey foreign key (confirmed_by) references public.profiles(id) on delete set null;

create or replace function public.stamp_group_author()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if current_setting('mull.erasing', true) = 'on' then return new; end if;
  new.created_by := old.created_by;
  return new;
end;
$$;

create or replace function public.stamp_expense_author()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if current_setting('mull.erasing', true) = 'on' then return new; end if;
  new.created_by := old.created_by;
  return new;
end;
$$;

create or replace function public.stamp_settlement_claimer()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if current_setting('mull.erasing', true) = 'on' then return new; end if;
  new.claimed_by := old.claimed_by;
  return new;
end;
$$;

create or replace function public.keep_recurring_author()
returns trigger language plpgsql as $$
begin
  if current_setting('mull.erasing', true) = 'on' then return new; end if;
  new.created_by := old.created_by;
  return new;
end;
$$;

-- guard_member_identity, rebuilt on the 2026-09-20 body with the same escape.
create or replace function public.guard_member_identity()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if current_setting('mull.erasing', true) = 'on' then
    return new;
  end if;

  if tg_op = 'INSERT' then
    if exists (
      select 1 from public.members m
       where m.id = new.id and m.user_id is not distinct from new.user_id
    ) then
      return new;
    end if;
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

create or replace function public.delete_my_account()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  me uuid := auth.uid();
begin
  if me is null then
    raise exception 'sign in first' using errcode = '42501';
  end if;

  perform set_config('mull.erasing', 'on', true);

  -- Your seats keep your name, so the ledgers still read, and lose every way
  -- of reaching you or paying you.
  update public.members
     set email = null, phone = null, upi_id = null
   where user_id = me;

  delete from public.notices where recipient_id = me or actor_id = me;
  delete from public.friendships where requester_id = me or addressee_id = me;

  -- Cascades to profiles, which nulls members.user_id and every authorship
  -- column above.
  delete from auth.users where id = me;
end;
$$;

revoke all on function public.delete_my_account() from public;
grant execute on function public.delete_my_account() to authenticated;
