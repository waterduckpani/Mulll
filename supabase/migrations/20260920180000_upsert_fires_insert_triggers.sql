-- A wholesale push could not reach a group you did not create.
--
-- The symptom was total. Adding an expense, settling up, confirming a payment
-- someone said they had sent — none of it reached the server in any group
-- where you were a `member` rather than its creator, and the app said nothing,
-- because a failed push is caught and logged. The ledger simply disagreed with
-- itself on two phones. Confirming a payment was the clearest case: the claim
-- left the screen, the notice went out, and the next pull put the claim back.
--
-- The cause is a detail of how Postgres runs an upsert. PostgREST's `upsert` is
--
--   insert into … values (…) on conflict (id) do update set …
--
-- and a BEFORE INSERT trigger fires for every *proposed* row, before anything
-- has looked for a conflict. Rows that go on to take the DO UPDATE path have
-- already run the INSERT branch of every before-trigger on the table.
--
-- Both member guards are written as `if tg_op = 'INSERT' then … end if;` with
-- the real rules underneath, on the assumption that the INSERT branch only ever
-- sees genuinely new seats. It does not. Mull pushes whole groups, so every
-- sync re-sends every seat, and each one arrives at the INSERT branch looking
-- like somebody trying to create it from scratch:
--
--   * guard_member_role saw the group's admin seat coming from a non-admin and
--     raised 'only an admin can add an admin'. This is the one that fired.
--   * guard_member_identity would raise 'you can only add someone to a group if
--     you are friends' for any seat belonging to someone you are not friends
--     with — latent here only because the two accounts happened to be friends,
--     and it runs first, so it would have taken over the moment that changed.
--
-- The UPDATE halves of both functions already have exactly the right idea —
-- `is distinct from`, with a comment reading "the wholesale push lands here".
-- The fix is to give the INSERT halves the same out: a re-send of a row that is
-- already in the table, unchanged in the column being guarded, is not a request
-- to do anything and is never worth refusing.
--
-- Matching on `id` is what makes that safe. It is the conflict target, so a row
-- that matches is precisely the row the upsert is about to update; a seat id
-- that is not in the table yet matches nothing and is judged as before. Both
-- functions are SECURITY DEFINER, so these lookups see the table whole rather
-- than through the caller's policies.

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
    -- The wholesale push lands here, because an upsert runs this branch for
    -- rows it is about to update. Re-sending a seat with the role it already
    -- has is not adding an admin.
    if exists (
      select 1 from public.members m
       where m.id = new.id and m.role = new.role
    ) then
      return new;
    end if;

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

-- Same trap, same shape of fix. This one did not fire today only because the
-- two accounts are friends; it is the next thing that would have broken, and
-- for someone sharing a group with a person they have not friended it is
-- breaking already.
--
-- `is not distinct from` rather than `=` so that a placeholder seat, whose
-- user_id is null on both sides, counts as unchanged.

create or replace function public.guard_member_identity()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'INSERT' then
    -- The wholesale push lands here; see the note above.
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
