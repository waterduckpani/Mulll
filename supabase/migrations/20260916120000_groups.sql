-- Mull's shared ledger.
--
-- Only groups live here. The wishlist, the budget and the lists stay on the
-- phone in mull.json: they are private to one person, they work offline, and
-- putting them behind a network call would make the app worse. Groups are the
-- one part of Mull that is inherently other people.
--
-- Money is whole rupees, everywhere, matching lib/core/split.dart. A paise
-- column here would reintroduce exactly the rounding drift those tests exist
-- to prevent.

-- ---------------------------------------------------------------- profiles

-- One row per signed-in person, keyed to auth.users.
--
-- Either contact can be the identity. Login is by email for now, but an
-- unclaimed seat is matched on whichever of the two it was invited by, so
-- moving to phone-OTP later adds a door rather than rebuilding the house.
-- Phones are stored E.164 ("+919876543210") and emails lowercased, so matching
-- is a plain equality check rather than a fuzzy one.
create table public.profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  email       text unique,
  phone       text unique,
  name        text not null default '',
  upi_id      text,
  created_at  timestamptz not null default now(),
  check (email is not null or phone is not null)
);

create index profiles_email_idx on public.profiles (email) where email is not null;
create index profiles_phone_idx on public.profiles (phone) where phone is not null;

-- ------------------------------------------------------------------ groups

create table public.groups (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  created_by  uuid not null references public.profiles(id),
  created_at  timestamptz not null default now(),
  deleted_at  timestamptz
);

-- ----------------------------------------------------------------- members
--
-- A member is a seat at the table, not a user. You add "Ritu" tonight; Ritu
-- may sign up next week, or never. Until she does, user_id is null and the
-- seat carries just a name, a way to reach her and maybe a VPA. When someone
-- signs up on that email or number, claim_seats() fills in user_id and the
-- history she was already part of becomes hers.
--
-- Everything else references member_id, never user_id, so a claim never has to
-- rewrite the ledger.

create table public.members (
  id          uuid primary key default gen_random_uuid(),
  group_id    uuid not null references public.groups(id) on delete cascade,
  user_id     uuid references public.profiles(id) on delete set null,
  name        text not null,
  email       text,
  phone       text,
  upi_id      text,
  created_at  timestamptz not null default now()
);

create index members_group_idx on public.members (group_id);
create index members_user_idx on public.members (user_id) where user_id is not null;
create index members_email_idx on public.members (email) where email is not null;
create index members_phone_idx on public.members (phone) where phone is not null;

-- One seat per person per group, and one unclaimed seat per contact per group.
create unique index members_one_seat_per_user on public.members (group_id, user_id) where user_id is not null;
create unique index members_one_seat_per_email on public.members (group_id, email) where email is not null and user_id is null;
create unique index members_one_seat_per_phone on public.members (group_id, phone) where phone is not null and user_id is null;

-- ---------------------------------------------------------------- expenses

create type public.split_method as enum ('equal', 'exact', 'shares', 'percent');

create table public.expenses (
  id              uuid primary key default gen_random_uuid(),
  group_id        uuid not null references public.groups(id) on delete cascade,
  description     text not null,
  amount          integer not null check (amount > 0),
  payer_member_id uuid not null references public.members(id),
  method          public.split_method not null default 'equal',
  spent_on        date not null default current_date,
  -- Rent, wifi and the maid are the same number every month. This only marks
  -- the intent; the client offers to repeat it, nothing is created behind
  -- anyone's back.
  repeats_monthly boolean not null default false,
  created_by      uuid not null references public.profiles(id),
  created_at      timestamptz not null default now(),
  -- Anyone in a group can add an expense, so nothing is ever truly deleted:
  -- a balance that silently changes is a balance nobody trusts.
  deleted_at      timestamptz
);

create index expenses_group_idx on public.expenses (group_id) where deleted_at is null;

-- The resolved rupee split, worked out once on the client when the expense is
-- saved. Never re-derived, so a balance read years later gives the same answer.
create table public.expense_shares (
  expense_id  uuid not null references public.expenses(id) on delete cascade,
  member_id   uuid not null references public.members(id),
  amount      integer not null check (amount >= 0),
  primary key (expense_id, member_id)
);

-- ------------------------------------------------------------- settlements
--
-- Two-sided on purpose. "Mark as settled" being a single unverified claim is
-- what makes other split apps rot: one person taps it, the other never sees
-- the money, and the balance is wrong forever. Here the payer claims and the
-- payee confirms, with the UPI reference kept as evidence.

create type public.settlement_status as enum ('pending', 'confirmed', 'disputed');

create table public.settlements (
  id              uuid primary key default gen_random_uuid(),
  group_id        uuid not null references public.groups(id) on delete cascade,
  from_member_id  uuid not null references public.members(id),
  to_member_id    uuid not null references public.members(id),
  amount          integer not null check (amount > 0),
  status          public.settlement_status not null default 'pending',
  -- Read off the payer's UPI receipt, so "I already sent it" has something
  -- behind it.
  utr             text,
  proof_path      text,
  claimed_at      timestamptz not null default now(),
  claimed_by      uuid not null references public.profiles(id),
  confirmed_at    timestamptz,
  confirmed_by    uuid references public.profiles(id),
  check (from_member_id <> to_member_id)
);

create index settlements_group_idx on public.settlements (group_id);

-- Only confirmed settlements move a balance. A pending claim is shown, but it
-- does not clear a debt until the person owed says it landed.

-- ----------------------------------------------------------- membership fn
--
-- RLS on members that asks "are you a member?" would consult members, which
-- runs the same policy again. security definer breaks that loop: the function
-- reads the table with the policy suspended, and is the single place every
-- other policy asks its question.

create or replace function public.is_member(target_group uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.members m
    where m.group_id = target_group and m.user_id = auth.uid()
  );
$$;

revoke all on function public.is_member(uuid) from public;
grant execute on function public.is_member(uuid) to authenticated;

-- ------------------------------------------------------------------- claim
--
-- Called after signup. Any seat left waiting on this phone number becomes
-- this account's, which is what lets you be added to a group before you have
-- ever heard of Mull.

create or replace function public.claim_seats()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  my_email text;
  my_phone text;
  claimed  integer;
begin
  select email, phone into my_email, my_phone from public.profiles where id = auth.uid();
  if my_email is null and my_phone is null then
    return 0;
  end if;

  with taken as (
    update public.members m
       set user_id = auth.uid()
     where (
             (my_email is not null and m.email = my_email)
             or (my_phone is not null and m.phone = my_phone)
           )
       and m.user_id is null
       -- Never take a second seat in a group this account already sits in.
       and not exists (
         select 1 from public.members other
          where other.group_id = m.group_id and other.user_id = auth.uid()
       )
    returning 1
  )
  select count(*) into claimed from taken;

  return claimed;
end;
$$;

revoke all on function public.claim_seats() from public;
grant execute on function public.claim_seats() to authenticated;

-- Keep profiles in step with auth, and pick up any seat already waiting.
create or replace function public.on_auth_user_created()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, email, phone, name)
  values (
    new.id,
    nullif(lower(coalesce(new.email, '')), ''),
    nullif(coalesce(new.phone, ''), ''),
    coalesce(new.raw_user_meta_data ->> 'name', '')
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.on_auth_user_created();

-- --------------------------------------------------------------------- RLS

alter table public.profiles        enable row level security;
alter table public.groups          enable row level security;
alter table public.members         enable row level security;
alter table public.expenses        enable row level security;
alter table public.expense_shares  enable row level security;
alter table public.settlements     enable row level security;

-- Profiles: yours to edit. Readable by people you actually share a group with,
-- so the app can show a real name and VPA without exposing the whole table.
create policy profiles_self on public.profiles
  for all to authenticated
  using (id = auth.uid())
  with check (id = auth.uid());

create policy profiles_shared_groups on public.profiles
  for select to authenticated
  using (
    exists (
      select 1
        from public.members mine
        join public.members theirs on theirs.group_id = mine.group_id
       where mine.user_id = auth.uid()
         and theirs.user_id = public.profiles.id
    )
  );

-- Groups: members read and update; anyone signed in can create one.
create policy groups_read on public.groups
  for select to authenticated
  using (public.is_member(id));

create policy groups_insert on public.groups
  for insert to authenticated
  with check (created_by = auth.uid());

create policy groups_update on public.groups
  for update to authenticated
  using (public.is_member(id))
  with check (public.is_member(id));

-- Members: anyone in the group manages the seats. The exception is the very
-- first seat — creating a group means adding yourself to a group you are not
-- yet a member of, so that one is allowed by the group's own authorship.
create policy members_read on public.members
  for select to authenticated
  using (public.is_member(group_id));

create policy members_insert on public.members
  for insert to authenticated
  with check (
    public.is_member(group_id)
    or exists (select 1 from public.groups g where g.id = group_id and g.created_by = auth.uid())
  );

create policy members_update on public.members
  for update to authenticated
  using (public.is_member(group_id))
  with check (public.is_member(group_id));

create policy members_delete on public.members
  for delete to authenticated
  using (public.is_member(group_id));

-- Expenses and shares: the group's business, all of it.
create policy expenses_read on public.expenses
  for select to authenticated using (public.is_member(group_id));

create policy expenses_insert on public.expenses
  for insert to authenticated with check (public.is_member(group_id) and created_by = auth.uid());

create policy expenses_update on public.expenses
  for update to authenticated
  using (public.is_member(group_id)) with check (public.is_member(group_id));

create policy shares_read on public.expense_shares
  for select to authenticated
  using (exists (select 1 from public.expenses e where e.id = expense_id and public.is_member(e.group_id)));

create policy shares_write on public.expense_shares
  for all to authenticated
  using (exists (select 1 from public.expenses e where e.id = expense_id and public.is_member(e.group_id)))
  with check (exists (select 1 from public.expenses e where e.id = expense_id and public.is_member(e.group_id)));

-- Settlements: anyone in the group can see them and claim one. Confirming is
-- narrower — only the person being paid can say the money arrived, which is
-- the whole point of two-sided settlement.
create policy settlements_read on public.settlements
  for select to authenticated using (public.is_member(group_id));

create policy settlements_insert on public.settlements
  for insert to authenticated
  with check (public.is_member(group_id) and claimed_by = auth.uid());

create policy settlements_confirm on public.settlements
  for update to authenticated
  using (
    exists (
      select 1 from public.members m
       where m.id = public.settlements.to_member_id and m.user_id = auth.uid()
    )
  )
  with check (
    exists (
      select 1 from public.members m
       where m.id = public.settlements.to_member_id and m.user_id = auth.uid()
    )
  );

-- ------------------------------------------------------------------ realtime

alter publication supabase_realtime add table public.groups;
alter publication supabase_realtime add table public.members;
alter publication supabase_realtime add table public.expenses;
alter publication supabase_realtime add table public.expense_shares;
alter publication supabase_realtime add table public.settlements;
