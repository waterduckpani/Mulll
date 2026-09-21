-- guard_member_identity referenced OLD on INSERT.
--
--   declare previous uuid := case when tg_op = 'UPDATE' then old.user_id else null end;
--
-- A DECLARE default is evaluated every time the function is entered, whatever
-- the branch would have decided, and in an INSERT trigger OLD is unassigned.
-- So every insert into members raised `record "old" is not assigned yet`.
--
-- The damage was quiet and total. Creating a group inserts the group row, then
-- the seats; the seats threw, the push aborted, and the group was left with no
-- member carrying the creator's user_id. is_member() then answered false for
-- its own author, so groups_read hid the row from them, the next pull returned
-- nothing, and replaceGroups() deleted the local copy. From the app it looked
-- like groups simply were not being saved.
--
-- The lesson is narrower than "be careful with OLD": a DECLARE default is not
-- a lazily evaluated expression, so a trigger that serves both INSERT and
-- UPDATE has to reach for OLD inside a branch that only UPDATE can enter.

create or replace function public.guard_member_identity()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  previous uuid;
begin
  if tg_op = 'UPDATE' then
    previous := old.user_id;
  end if;

  if new.user_id is not distinct from previous then
    return new;                      -- unchanged; the wholesale push lands here
  end if;

  -- Seating a friend: a new seat may be created already attached to someone
  -- else's account, but only if the two of you have agreed to that. Only ever
  -- on INSERT — changing who an existing seat belongs to would rewrite history
  -- rather than add to it, and stays forbidden for everybody.
  if tg_op = 'INSERT'
     and new.user_id is distinct from auth.uid()
     and public.is_friend(new.user_id) then
    return new;
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
