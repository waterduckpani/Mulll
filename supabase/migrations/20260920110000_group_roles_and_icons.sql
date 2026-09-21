-- Who runs a group, and what it looks like in a list.
--
-- Until now every seat was equal, which sounds fair and reads as chaos: anyone
-- could rename the flat, and the only honest answer to "who added Kabir?" was
-- "somebody did". A group of people splitting real money needs a name against
-- the decisions, and the person who made the group is the obvious one.
--
-- Deliberately two roles and no more. A permissions matrix is the wrong amount
-- of app for four flatmates; what is needed is a short answer to "may I remove
-- this person" and a visible list of who can.

-- ------------------------------------------------------------------- roles

create type public.member_role as enum ('admin', 'member');

alter table public.members
  add column role public.member_role not null default 'member';

-- Everyone who already made a group keeps it. Without this every existing
-- group becomes one nobody can administer, including by its own creator.
update public.members m
   set role = 'admin'
  from public.groups g
 where g.id = m.group_id
   and g.created_by = m.user_id;

-- A group with no admin at all cannot be repaired from inside the app, so any
-- group whose creator never took a seat promotes its oldest seat instead.
with orphaned as (
  select g.id as group_id,
         (select m.id
            from public.members m
           where m.group_id = g.id
           order by m.created_at, m.id
           limit 1) as seat
    from public.groups g
   where not exists (
     select 1 from public.members a where a.group_id = g.id and a.role = 'admin'
   )
)
update public.members m
   set role = 'admin'
  from orphaned o
 where m.id = o.seat;

-- A one-to-one ledger has no hierarchy in it. "What I owe Ritu" belongs to
-- both of you equally, and an admin who could rename or delete it out from
-- under the other person would be inventing a power the relationship does not
-- have.
update public.members m
   set role = 'admin'
  from public.groups g
 where g.id = m.group_id
   and g.kind = 'direct';

create or replace function public.is_group_admin(target_group uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.members m
     where m.group_id = target_group
       and m.user_id = auth.uid()
       and m.role = 'admin'
  );
$$;

revoke all on function public.is_group_admin(uuid) from public;
grant execute on function public.is_group_admin(uuid) to authenticated;

-- Only an admin may hand out or take back the role, and the last one may not
-- step down — a group that can no longer be administered is a group that can
-- never be tidied up, renamed or left.
--
-- A trigger rather than a policy, for the reason this schema keeps running
-- into: Mull pushes whole groups, so every sync re-sends every seat with its
-- current role. A column revoke would reject those unchanged re-sends. `is
-- distinct from` lets a no-op through and judges only a real change.
create or replace function public.guard_member_role()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  admins_left integer;
begin
  if tg_op = 'INSERT' then
    -- The first seat in a brand new group is its creator's, and there is
    -- nobody to have granted it anything yet.
    if new.role = 'admin'
       and not public.is_group_admin(new.group_id)
       and not exists (
         select 1 from public.groups g
          where g.id = new.group_id and g.created_by = auth.uid()
       ) then
      raise exception 'only an admin can add an admin' using errcode = '42501';
    end if;
    return new;
  end if;

  if new.role is not distinct from old.role then
    return new;                        -- the wholesale push lands here
  end if;

  if not public.is_group_admin(new.group_id) then
    raise exception 'only an admin can change who runs a group'
      using errcode = '42501';
  end if;

  if old.role = 'admin' and new.role <> 'admin' then
    select count(*) into admins_left
      from public.members m
     where m.group_id = old.group_id and m.role = 'admin' and m.id <> old.id;
    if admins_left = 0 then
      raise exception 'a group needs at least one admin'
        using errcode = '23514';
    end if;
  end if;

  return new;
end;
$$;

create trigger guard_member_role
  before insert or update on public.members
  for each row execute function public.guard_member_role();

-- Removing a seat becomes an admin's job. Reading, adding expenses and
-- settling up are untouched: those are what being in a group *is*.
drop policy if exists members_delete on public.members;

create policy members_delete on public.members
  for delete to authenticated
  using (
    public.is_group_admin(group_id)
    -- Leaving is always yours to do. An admin who could trap someone in a
    -- group would be a worse problem than an unadministered one. Read off the
    -- row directly rather than through a subquery: a subquery against members
    -- is itself subject to members' policies, which is how a rule like this
    -- ends up quietly meaning something narrower than it says.
    or user_id = auth.uid()
  );

-- ------------------------------------------------------------------- icons

-- A short key into a fixed set the app draws — 'plane', 'home', 'cutlery'.
-- Not an image and not an emoji: an image is a storage bucket and a cache, and
-- an emoji renders differently on every OS and colours a design that has no
-- colour in it anywhere.
alter table public.groups
  add column icon text;

alter table public.groups
  add constraint groups_icon_is_a_key
  check (icon is null or icon ~ '^[a-z][a-z0-9_]{0,30}$');

-- Renaming and re-badging a group are the same decision and both belong to an
-- admin. `is_member` stays on the read side.
drop policy if exists groups_update on public.groups;

create policy groups_update on public.groups
  for update to authenticated
  using (public.is_member(id))
  with check (public.is_member(id));

create or replace function public.guard_group_identity()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.name is not distinct from old.name
     and new.icon is not distinct from old.icon
     and new.deleted_at is not distinct from old.deleted_at then
    return new;                        -- the wholesale push lands here
  end if;
  if not public.is_group_admin(new.id) then
    raise exception 'only an admin can rename, re-badge or delete a group'
      using errcode = '42501';
  end if;
  return new;
end;
$$;

create trigger guard_group_identity
  before update on public.groups
  for each row execute function public.guard_group_identity();

-- ------------------------------------------------------------------- grants

-- Both new columns join the lists. See the note in the recurring migration:
-- a column the client sends but has no UPDATE grant on fails the entire
-- upsert, not just that column.
revoke update on public.groups from authenticated;
grant update (id, name, kind, icon, created_by, deleted_at)
  on public.groups to authenticated;

revoke update on public.members from authenticated;
grant update (id, group_id, user_id, name, email, phone, upi_id, role)
  on public.members to authenticated;
