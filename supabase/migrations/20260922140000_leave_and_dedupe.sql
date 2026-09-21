-- Leaving a group you have used, and the same notification twice.
--
-- 1. leave_group(). Leaving used to mean deleting your seat, and a seat that
--    paid for or shared anything is referenced by that history, so the app
--    refused anyone who had ever taken part. A settled seat now stays, under
--    your name, and stops being yours: user_id goes to null, the group drops
--    out of your list, and everyone else's history still adds up.
--
--    Detaching a seat is exactly what guard_member_identity exists to stop
--    ("changing who a seat belongs to is forbidden for everyone"), so it gets
--    one narrow escape: `mull.leaving` holding the id of the seat being
--    detached, set only inside leave_group(), which only ever names the
--    caller's own seat.
--
-- 2. notify() drops a notice identical to one the same sender gave the same
--    person in the last two minutes. TestFlight saw settlement notices land
--    twice, ten seconds apart: a double tap, or a confirm card still on screen
--    after it was handled, each wrote its own row and each row buzzed.

-- ====================================================== 1. leave_group()

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

  -- leave_group() letting go of the caller's own seat, and nothing else.
  if current_setting('mull.leaving', true) = old.id::text
     and old.user_id = auth.uid()
     and new.user_id is null then
    return new;
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
  balance bigint;
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

  -- The same arithmetic as Group.balances in the app: paid, minus shares,
  -- plus confirmed settlements sent, minus confirmed settlements received.
  select coalesce(sum(x.amount), 0) into balance from (
    select e.amount from public.expenses e
     where e.group_id = target_group and e.deleted_at is null and e.payer_member_id = seat.id
    union all
    select -s.amount from public.expense_shares s
      join public.expenses e on e.id = s.expense_id
     where e.group_id = target_group and e.deleted_at is null and s.member_id = seat.id
    union all
    select t.amount from public.settlements t
     where t.group_id = target_group and t.deleted_at is null and t.status = 'confirmed'
       and t.from_member_id = seat.id
    union all
    select -t.amount from public.settlements t
     where t.group_id = target_group and t.deleted_at is null and t.status = 'confirmed'
       and t.to_member_id = seat.id
  ) x;
  if balance <> 0 then
    raise exception 'settle up before leaving' using errcode = '23514';
  end if;

  if exists (
    select 1 from public.settlements t
     where t.group_id = target_group and t.deleted_at is null and t.status = 'pending'
       and (t.from_member_id = seat.id or t.to_member_id = seat.id)
  ) then
    raise exception 'a payment with you is still waiting to be confirmed' using errcode = '23514';
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
         role = case when admins_left > 0 then 'member'::public.member_role else m.role end
   where m.id = seat.id;
  perform set_config('mull.leaving', '', true);
  return 'detached';
end;
$$;

revoke all on function public.leave_group(uuid) from public, anon;
grant execute on function public.leave_group(uuid) to authenticated;

-- ================================================= 2. notify(), deduped

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
    select distinct r, auth.uid(), notify.notice, notify.target_group,
           left(notify.title, 140), left(coalesce(notify.body, ''), 280), notify.amount
      from unnest(recipients) as r
     where r is distinct from auth.uid()
       and (
         (notify.target_group is not null and exists (
            select 1 from public.members m
             where m.group_id = notify.target_group and m.user_id = r
         ))
         or (notify.target_group is null and public.shares_a_group(r))
       )
       -- Said once. The inbox index covers (recipient_id, created_at).
       and not exists (
         select 1 from public.notices d
          where d.recipient_id = r
            and d.created_at > now() - interval '2 minutes'
            and d.actor_id = auth.uid()
            and d.kind = notify.notice
            and d.group_id is not distinct from notify.target_group
            and d.title = left(notify.title, 140)
            and d.body = left(coalesce(notify.body, ''), 280)
       )
    returning 1
  )
  select count(*) into sent from delivered;
  return sent;
end;
$$;

revoke all on function public.notify(uuid, uuid[], public.notice_kind, text, text, integer) from public, anon;
grant execute on function public.notify(uuid, uuid[], public.notice_kind, text, text, integer) to authenticated;
