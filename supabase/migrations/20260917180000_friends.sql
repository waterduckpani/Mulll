-- Friends.
--
-- Until now the only way to put someone in a group was to type their name, and
-- optionally their email and their UPI ID. Both of those last two are facts
-- about *them* being entered by *you*, which is the wrong way round: a VPA
-- typed by the payer is a payment to whoever owns that handle, and a typo is a
-- transfer to a stranger that no one can undo.
--
-- A friendship makes the link once, with both people agreeing to it, and after
-- that their name and VPA come from their own account and follow them when
-- they change bank.
--
-- The request/accept shape also solves the lookup problem. You can send a
-- request to any address without learning anything: if they have an account it
-- appears for them, if they do not it waits, and either way the sender is told
-- only "sent". There is no query here that answers "is this person on Mull",
-- which is what makes it safe to let anyone type any address.

create type public.friendship_status as enum ('pending', 'accepted');

create table public.friendships (
  id               uuid primary key default gen_random_uuid(),
  requester_id     uuid not null references public.profiles(id) on delete cascade,

  -- Exactly one of these is set. addressee_id once the person exists;
  -- addressee_email while the request is still waiting for them to sign up —
  -- the same "invite someone who has never heard of Mull" idea as an unclaimed
  -- seat, and claimed by the same function at the same moment.
  addressee_id     uuid references public.profiles(id) on delete cascade,
  addressee_email  text,

  status           public.friendship_status not null default 'pending',
  created_at       timestamptz not null default now(),
  responded_at     timestamptz,

  constraint friendship_has_an_addressee check (addressee_id is not null or addressee_email is not null),
  constraint friendship_is_not_with_yourself check (addressee_id is null or addressee_id <> requester_id)
);

-- One friendship per pair, in whichever direction it was asked. least/greatest
-- normalises the pair so A→B and B→A collide instead of producing two rows that
-- disagree about the status.
create unique index friendships_one_per_pair
  on public.friendships (least(requester_id, addressee_id), greatest(requester_id, addressee_id))
  where addressee_id is not null;

create unique index friendships_one_per_invite
  on public.friendships (requester_id, addressee_email)
  where addressee_id is null;

create index friendships_requester_idx on public.friendships (requester_id);
create index friendships_addressee_idx on public.friendships (addressee_id) where addressee_id is not null;
create index friendships_email_idx on public.friendships (addressee_email) where addressee_email is not null;

-- ------------------------------------------------------------------ helpers

-- Security definer for the same reason is_member() is: a policy on profiles
-- that asks "are we friends?" would otherwise consult friendships, whose own
-- policy consults profiles.
create or replace function public.is_friend(other uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.friendships f
     where f.status = 'accepted'
       and ((f.requester_id = auth.uid() and f.addressee_id = other)
         or (f.addressee_id = auth.uid() and f.requester_id = other))
  );
$$;

revoke all on function public.is_friend(uuid) from public;
grant execute on function public.is_friend(uuid) to authenticated;

-- ---------------------------------------------------------------------- RLS

alter table public.friendships enable row level security;

-- You see a friendship only if you are one of its two sides. A pending request
-- addressed to your email is visible too, so it can be shown to you the moment
-- you sign up, before claim_invitations() has run.
create policy friendships_read on public.friendships
  for select to authenticated
  using (
    requester_id = auth.uid()
    or addressee_id = auth.uid()
    or addressee_email = (select email from public.profiles where id = auth.uid())
  );

create policy friendships_request on public.friendships
  for insert to authenticated
  with check (requester_id = auth.uid() and status = 'pending');

-- Only the person who was asked can accept. The requester accepting their own
-- request would make the whole handshake decorative.
create policy friendships_respond on public.friendships
  for update to authenticated
  using (addressee_id = auth.uid())
  with check (addressee_id = auth.uid());

-- Either side can withdraw: cancelling a request you sent, declining one you
-- received, or unfriending later. All three are the same row going away.
create policy friendships_withdraw on public.friendships
  for delete to authenticated
  using (requester_id = auth.uid() or addressee_id = auth.uid());

-- Accepting must not be able to rewrite who the friendship is between.
create or replace function public.guard_friendship()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.requester_id is distinct from old.requester_id
     or new.addressee_id is distinct from old.addressee_id
     or new.addressee_email is distinct from old.addressee_email then
    raise exception 'a friendship cannot change who it is between'
      using errcode = '42501';
  end if;
  if new.status is distinct from old.status then
    new.responded_at := now();
  end if;
  return new;
end;
$$;

create trigger guard_friendship
  before update on public.friendships
  for each row execute function public.guard_friendship();

-- ---------------------------------------------------------------- profiles
--
-- A friend's name and VPA have to be readable, or the whole point is lost.
-- Scoped to accepted friendships only: a pending request reveals nothing.

create policy profiles_friends on public.profiles
  for select to authenticated
  using (public.is_friend(id));

-- -------------------------------------------------------------- seating
--
-- guard_member_identity refuses to let anyone but the owner attach a user_id
-- to a seat, which is right for a claim but blocks the thing friends are for:
-- adding someone to a group with their account already attached, so their name
-- and VPA come from them rather than being typed by you.
--
-- Friendship is the consent that makes this allowed. Note the asymmetry: this
-- only opens up INSERT, so a *new* seat can be created for a friend. Changing
-- who an existing seat belongs to stays forbidden for everyone, because that
-- would rewrite history rather than add to it.

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

  if tg_op = 'INSERT'
     and new.user_id is distinct from auth.uid()
     and public.is_friend(new.user_id) then
    return new;                      -- seating a friend, with their agreement
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

-- ------------------------------------------------------------------ claiming
--
-- Signing up collects everything that was waiting on your address: seats in
-- groups, and friend requests. Both were addressed to an email before there was
-- an account to attach them to, and both should be there when you arrive.

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
  select count(*) into seats from taken;

  with linked as (
    update public.friendships f
       set addressee_id = auth.uid(),
           addressee_email = null
     where f.addressee_id is null
       and my_email is not null
       and f.addressee_email = my_email
       and f.requester_id <> auth.uid()
       -- Someone you are already friends with does not get a second row.
       and not exists (
         select 1 from public.friendships other
          where other.status = 'accepted'
            and ((other.requester_id = f.requester_id and other.addressee_id = auth.uid())
              or (other.addressee_id = f.requester_id and other.requester_id = auth.uid()))
       )
    returning 1
  )
  select count(*) into friends from linked;

  return json_build_object('seats', seats, 'friends', friends);
end;
$$;

revoke all on function public.claim_invitations() from public;
grant execute on function public.claim_invitations() to authenticated;

-- claim_seats() stays as a thin wrapper so an older build in someone's hands
-- keeps working rather than silently claiming nothing.
create or replace function public.claim_seats()
returns integer
language sql
security definer
set search_path = public
as $$
  select (public.claim_invitations() ->> 'seats')::integer;
$$;

-- ----------------------------------------------------------------- realtime

alter publication supabase_realtime add table public.friendships;
