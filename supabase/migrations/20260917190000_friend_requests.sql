-- Sending and answering a friend request.
--
-- Both of these have to run as the server, for opposite reasons.
--
-- Sending, because resolving an address to an account is exactly the query the
-- profiles policies exist to forbid. The client cannot do it — and should not:
-- a client-side lookup that returns a row for a real address and nothing for a
-- fake one is an oracle for "who is on Mull", testable against any list of
-- addresses. So the client never sees the answer; it hands over an address and
-- is told only that the request was sent.
--
-- Answering, because a request sent to someone who had no account yet is
-- addressed to an email rather than a user. They can see it (the read policy
-- matches on their address) but `friendships_respond` requires addressee_id,
-- which is still null. Accepting has to fill that in, and filling it in is the
-- one thing the guard trigger refuses to let a client do.

create or replace function public.send_friend_request(target_email text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  address  text := lower(trim(target_email));
  me       uuid := auth.uid();
  my_email text;
  target   uuid;
begin
  if me is null then
    raise exception 'sign in first' using errcode = '42501';
  end if;
  if address is null or address !~ '^[^@\s]+@[^@\s.]+\.[^@\s]{2,}$' then
    raise exception 'that does not look like an email address' using errcode = '22023';
  end if;

  select email into my_email from public.profiles where id = me;
  if address = my_email then
    raise exception 'that is your own address' using errcode = '22023';
  end if;

  select id into target from public.profiles where email = address;

  -- Already connected, in either direction and at any stage. Returning the
  -- existing state rather than raising keeps the caller's message honest
  -- without telling it anything it could not already see.
  if target is not null and exists (
    select 1 from public.friendships f
     where (f.requester_id = me and f.addressee_id = target)
        or (f.requester_id = target and f.addressee_id = me)
  ) then
    return 'already';
  end if;
  if exists (
    select 1 from public.friendships f
     where f.requester_id = me and f.addressee_email = address
  ) then
    return 'already';
  end if;

  insert into public.friendships (requester_id, addressee_id, addressee_email, status)
  values (me, target, case when target is null then address else null end, 'pending');

  -- The same word whether or not anyone was there. This is the whole point.
  return 'sent';
end;
$$;

revoke all on function public.send_friend_request(text) from public;
grant execute on function public.send_friend_request(text) to authenticated;

create or replace function public.accept_friend_request(friendship uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  me       uuid := auth.uid();
  my_email text;
  row_     public.friendships%rowtype;
begin
  if me is null then
    raise exception 'sign in first' using errcode = '42501';
  end if;
  select email into my_email from public.profiles where id = me;

  select * into row_ from public.friendships where id = friendship;
  if not found then
    return false;
  end if;

  -- Yours to answer if it names you, or if it was sent to your address before
  -- you had an account. Never if you are the one who asked.
  if row_.requester_id = me then
    raise exception 'you cannot accept your own request' using errcode = '42501';
  end if;
  if row_.addressee_id is distinct from me
     and (my_email is null or row_.addressee_email is distinct from my_email) then
    raise exception 'that request is not yours to answer' using errcode = '42501';
  end if;

  update public.friendships
     set addressee_id = me,
         addressee_email = null,
         status = 'accepted',
         responded_at = now()
   where id = friendship;

  return true;
end;
$$;

revoke all on function public.accept_friend_request(uuid) from public;
grant execute on function public.accept_friend_request(uuid) to authenticated;

-- The guard runs on every update, including the one just above, and it refuses
-- any change to who a friendship is between. Linking an email-addressed request
-- to the account that turned out to own that address is the single exception.
create or replace function public.guard_friendship()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.requester_id is distinct from old.requester_id then
    raise exception 'a friendship cannot change who it is between'
      using errcode = '42501';
  end if;

  if new.addressee_id is distinct from old.addressee_id then
    if old.addressee_id is not null then
      raise exception 'a friendship cannot change who it is between'
        using errcode = '42501';
    end if;
    -- Filling in a blank, and only with the account whose address it is.
    if new.addressee_id is distinct from auth.uid() then
      raise exception 'only the person invited can take up that request'
        using errcode = '42501';
    end if;
  end if;

  if new.status is distinct from old.status then
    new.responded_at := now();
  end if;
  return new;
end;
$$;

-- Declining a request addressed to your email, before it has been linked to
-- your account. friendships_withdraw only matches on the two id columns, so
-- without this the only way to be rid of it is to accept it.
create policy friendships_decline_invite on public.friendships
  for delete to authenticated
  using (
    addressee_id is null
    and addressee_email = (select email from public.profiles where id = auth.uid())
  );
