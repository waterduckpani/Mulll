-- A group must never become unreachable by the person who made it.
--
-- groups_read and groups_update both asked only `is_member(id)`, and membership
-- lives in a different table that is written by a *later* statement in the same
-- push. So a push that inserted the group and then failed on the seats left a
-- row that nobody — including its author — could read or update. The next push
-- tried to upsert it, took the ON CONFLICT path, was refused by the update
-- policy, and so never got as far as inserting the seats that would have made
-- the author a member again.
--
-- Deadlock, and a silent one: the group is invisible to the only account that
-- could repair it, so it does not even show up when you go looking for what
-- went wrong. Every retry fails identically forever.
--
-- `created_by` is the fix because it is on the row itself and set at insert
-- time, so it cannot be out of step with a table that has not been written yet.
-- Authorship is the one claim that is true the instant the row exists.

drop policy if exists groups_read on public.groups;
create policy groups_read on public.groups
  for select to authenticated
  using (public.is_member(id) or created_by = auth.uid());

drop policy if exists groups_update on public.groups;
create policy groups_update on public.groups
  for update to authenticated
  using (public.is_member(id) or created_by = auth.uid())
  with check (public.is_member(id) or created_by = auth.uid());

-- Members has the same shape of problem in miniature: inserting the very first
-- seat means writing to a group you are not yet a member of. The original
-- policy already allowed for that via created_by, and it is worth keeping the
-- two in step.

drop policy if exists members_insert on public.members;
create policy members_insert on public.members
  for insert to authenticated
  with check (
    public.is_member(group_id)
    or exists (select 1 from public.groups g where g.id = group_id and g.created_by = auth.uid())
  );

-- Clear out anything already stranded. A group with no members cannot be
-- reached, repaired or displayed by anyone, so there is nothing to preserve —
-- and leaving them would mean the next push still collides with a dead row.
delete from public.groups g
 where not exists (select 1 from public.members m where m.group_id = g.id);
