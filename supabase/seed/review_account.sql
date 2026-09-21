-- Demo ledgers for the App Review account, review@mull.oblunestudio.com.
--
-- Run by tool/review-account.sh after it has created the account. Idempotent:
-- it deletes what the account created before and writes it all again, so it
-- is also how to reset the account between submissions.
--
-- Written as the review account itself (role authenticated, its uid in the
-- JWT claims), so every row goes through the same RLS and triggers as one the
-- app wrote. Everyone else in these groups is a placeholder seat, a name with
-- no account, so nothing here reaches a real person. UPI IDs end in @example,
-- which no bank issues, so a reviewer who taps Pay cannot pay anybody.

do $$
declare
  uid uuid := (select id from auth.users where email = 'review@mull.oblunestudio.com');
  goa uuid := gen_random_uuid();
  flat uuid := gen_random_uuid();
  meera_ledger uuid := gen_random_uuid();
  me_goa uuid := gen_random_uuid();
  sahil uuid := gen_random_uuid();
  ananya uuid := gen_random_uuid();
  kabir uuid := gen_random_uuid();
  me_flat uuid := gen_random_uuid();
  riya uuid := gen_random_uuid();
  arjun uuid := gen_random_uuid();
  me_meera uuid := gen_random_uuid();
  meera uuid := gen_random_uuid();
  rent uuid := gen_random_uuid();
  e uuid;
begin
  if uid is null then
    raise exception 'create the review account first (tool/review-account.sh does)';
  end if;

  delete from public.groups where created_by = uid;
  delete from public.notices where recipient_id = uid;
  update public.profiles set name = 'App Review', upi_id = 'review@example' where id = uid;

  perform set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';

  -- Goa trip: four people, a claim waiting on you.
  insert into public.groups (id, name, created_by, kind, icon) values (goa, 'Goa trip', uid, 'group', 'beach');
  insert into public.members (id, group_id, user_id, name, upi_id, role) values
    (me_goa, goa, uid, 'App Review', null, 'admin'),
    (sahil, goa, null, 'Sahil Mehra', 'sahil@example', 'member'),
    (ananya, goa, null, 'Ananya Rao', 'ananya@example', 'member'),
    (kabir, goa, null, 'Kabir', null, 'member');

  e := gen_random_uuid();
  insert into public.expenses (id, group_id, description, amount, payer_member_id, method, spent_on, repeats_monthly, created_by)
    values (e, goa, 'Villa, three nights', 12000, me_goa, 'equal', current_date - 12, false, uid);
  insert into public.expense_shares values (e, me_goa, 3000), (e, sahil, 3000), (e, ananya, 3000), (e, kabir, 3000);

  e := gen_random_uuid();
  insert into public.expenses (id, group_id, description, amount, payer_member_id, method, spent_on, repeats_monthly, created_by)
    values (e, goa, 'Scooter rental', 2400, sahil, 'equal', current_date - 11, false, uid);
  insert into public.expense_shares values (e, me_goa, 600), (e, sahil, 600), (e, ananya, 600), (e, kabir, 600);

  e := gen_random_uuid();
  insert into public.expenses (id, group_id, description, amount, payer_member_id, method, spent_on, repeats_monthly, created_by)
    values (e, goa, 'Dinner at the shack', 4800, ananya, 'equal', current_date - 10, false, uid);
  insert into public.expense_shares values (e, me_goa, 1200), (e, sahil, 1200), (e, ananya, 1200), (e, kabir, 1200);

  e := gen_random_uuid();
  insert into public.expenses (id, group_id, description, amount, payer_member_id, method, spent_on, repeats_monthly, created_by)
    values (e, goa, 'Petrol', 1200, me_goa, 'equal', current_date - 9, false, uid);
  insert into public.expense_shares values (e, me_goa, 400), (e, sahil, 400), (e, kabir, 400);

  -- Kabir says he paid. Pending until you confirm it.
  insert into public.settlements (group_id, from_member_id, to_member_id, amount, status, claimed_at, claimed_by, is_offset)
    values (goa, kabir, me_goa, 1500, 'pending', now() - interval '2 hours', uid, false);

  -- Flat 302: rent on a schedule that is due today, so it asks.
  insert into public.groups (id, name, created_by, kind, icon) values (flat, 'Flat 302', uid, 'group', 'home');
  insert into public.members (id, group_id, user_id, name, upi_id, role) values
    (me_flat, flat, uid, 'App Review', null, 'admin'),
    (riya, flat, null, 'Riya Kapoor', 'riya@example', 'member'),
    (arjun, flat, null, 'Arjun Nair', 'arjun@example', 'member');

  insert into public.recurring_expenses (id, group_id, description, amount, payer_member_id, method, frequency, next_due, paused, auto_add, created_by)
    values (rent, flat, 'Rent', 45000, riya, 'equal', 'monthly', current_date, false, false, uid);
  insert into public.recurring_shares values (rent, me_flat, 15000), (rent, riya, 15000), (rent, arjun, 15000);

  e := gen_random_uuid();
  insert into public.expenses (id, group_id, description, amount, payer_member_id, method, spent_on, repeats_monthly, created_by)
    values (e, flat, 'Electricity', 3150, me_flat, 'equal', current_date - 6, false, uid);
  insert into public.expense_shares values (e, me_flat, 1050), (e, riya, 1050), (e, arjun, 1050);

  e := gen_random_uuid();
  insert into public.expenses (id, group_id, description, amount, payer_member_id, method, spent_on, repeats_monthly, created_by)
    values (e, flat, 'Groceries', 2340, arjun, 'equal', current_date - 3, false, uid);
  insert into public.expense_shares values (e, me_flat, 780), (e, riya, 780), (e, arjun, 780);

  e := gen_random_uuid();
  insert into public.expenses (id, group_id, description, amount, payer_member_id, method, spent_on, repeats_monthly, created_by)
    values (e, flat, 'Wi-Fi', 999, me_flat, 'equal', current_date - 2, false, uid);
  insert into public.expense_shares values (e, me_flat, 333), (e, riya, 333), (e, arjun, 333);

  -- A one-to-one ledger.
  insert into public.groups (id, name, created_by, kind, icon) values (meera_ledger, 'Meera', uid, 'direct', null);
  insert into public.members (id, group_id, user_id, name, upi_id, role) values
    (me_meera, meera_ledger, uid, 'App Review', null, 'admin'),
    (meera, meera_ledger, null, 'Meera Iyer', 'meera@example', 'member');

  e := gen_random_uuid();
  insert into public.expenses (id, group_id, description, amount, payer_member_id, method, spent_on, repeats_monthly, created_by)
    values (e, meera_ledger, 'Concert tickets', 3000, meera, 'equal', current_date - 5, false, uid);
  insert into public.expense_shares values (e, me_meera, 1500), (e, meera, 1500);
end;
$$;
