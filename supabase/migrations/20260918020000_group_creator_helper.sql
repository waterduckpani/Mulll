-- Same deadlock as groups, one table down.
--
-- members_insert's fallback was an inline subquery over groups. A policy's
-- subquery is itself subject to that table's policies, so "am I this group's
-- author?" could only be answered if groups_read already said yes — which is
-- the very thing that was failing. And members_update had no fallback at all,
-- so an upsert that hit the conflict path was refused outright.
--
-- is_member() was made security definer for precisely this reason. This is the
-- same lesson arriving a second time: a policy that needs a fact from another
-- table should ask a security definer function for it, not inline a select
-- that the asker may not be allowed to run.

create or replace function public.is_group_creator(target_group uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.groups g
     where g.id = target_group and g.created_by = auth.uid()
  );
$$;

revoke all on function public.is_group_creator(uuid) from public;
grant execute on function public.is_group_creator(uuid) to authenticated;

-- Creating a group means writing seats into a group you are not yet a member
-- of — you become one by virtue of the seat you are inserting. Authorship is
-- what carries you across that gap, on insert and on update alike.

drop policy if exists members_insert on public.members;
create policy members_insert on public.members
  for insert to authenticated
  with check (public.is_member(group_id) or public.is_group_creator(group_id));

drop policy if exists members_update on public.members;
create policy members_update on public.members
  for update to authenticated
  using (public.is_member(group_id) or public.is_group_creator(group_id))
  with check (public.is_member(group_id) or public.is_group_creator(group_id));

drop policy if exists members_read on public.members;
create policy members_read on public.members
  for select to authenticated
  using (public.is_member(group_id) or public.is_group_creator(group_id));

drop policy if exists members_delete on public.members;
create policy members_delete on public.members
  for delete to authenticated
  using (public.is_member(group_id) or public.is_group_creator(group_id));

-- The same gap exists for the rest of a group's contents: a push sends the
-- group, its seats, then its expenses, and any of those can arrive before the
-- seat that would make the sender a member.

drop policy if exists expenses_insert on public.expenses;
create policy expenses_insert on public.expenses
  for insert to authenticated
  with check (
    (public.is_member(group_id) or public.is_group_creator(group_id))
    and created_by = auth.uid()
  );

drop policy if exists expenses_read on public.expenses;
create policy expenses_read on public.expenses
  for select to authenticated
  using (public.is_member(group_id) or public.is_group_creator(group_id));

drop policy if exists expenses_update on public.expenses;
create policy expenses_update on public.expenses
  for update to authenticated
  using (public.is_member(group_id) or public.is_group_creator(group_id))
  with check (public.is_member(group_id) or public.is_group_creator(group_id));
