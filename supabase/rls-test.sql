-- Does a shop's data actually stay inside that shop?
--
-- Run after schema.sql, on a project with no real shops in it. It makes two
-- shops, two accounts and some trade, then tries every way a till might
-- reach another shop's books. Every assertion must pass; the first failure
-- aborts with the line that failed.
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/rls-test.sql
--
-- It cleans up after itself. It is not a benchmark and not a fixture: it is
-- the evidence that the policies in schema.sql do what their comments claim.

\set ON_ERROR_STOP on
\timing off

begin;

-- ---------------------------------------------------------------- set-up

insert into auth.users (id, email) values
  ('11111111-1111-1111-1111-111111111111', 'shop-a@corecashier.test'),
  ('22222222-2222-2222-2222-222222222222', 'shop-b@corecashier.test')
on conflict (id) do nothing;

select cc_link('shop-a@corecashier.test', 'TEST Shop A');
select cc_link('shop-b@corecashier.test', 'TEST Shop B');

-- Into psql variables rather than a temporary table: the tests below run
-- as the `authenticated` role, which has no business reading a table we
-- made for our own convenience.
select id as shop_a from cc_shop where name = 'TEST Shop A' \gset
select id as shop_b from cc_shop where name = 'TEST Shop B' \gset

-- psql does not expand its variables inside a dollar-quoted block, so the
-- two tests that forge a write from inside one read the id from here.
select set_config('test.shop_a', :'shop_a', false);

-- Become a till belonging to shop A, exactly as PostgREST would.
create or replace function t_be(who text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', who, true);
end;
$$;

\echo '--- 1. a till writes its own shop'
select t_be('11111111-1111-1111-1111-111111111111');
set local role authenticated;

insert into cc_sale (shop_id, id, till_id, receipt_no, at, lines, total, method)
values (:'shop_a', 's-a1', 'T1', 'T1-000001', now(), '[{"name":"Rice 5kg","qty":2,"price":9000}]'::jsonb, 18000, 'cash');
insert into cc_sale (shop_id, id, till_id, receipt_no, at, lines, total, method)
values (:'shop_a', 's-a2', 'T2', 'T2-000001', now(), '[{"name":"Tea 500g","qty":1,"price":4500}]'::jsonb, 4500, 'later');

do $$ begin
  assert (select count(*) from cc_sale) = 2, 'shop A should see its own two sales';
end $$;

\echo '--- 2. the same sale pushed twice is still one sale'
insert into cc_sale (shop_id, id, till_id, at, total, method)
values (:'shop_a', 's-a1', 'T1', now(), 18000, 'cash')
on conflict do nothing;

do $$ begin
  assert (select count(*) from cc_sale) = 2, 're-sending a sale must not duplicate it';
  assert (select total from cc_sale where id = 's-a1') = 18000, 'and must not alter it';
end $$;

\echo '--- 3. a till cannot change or delete a sale'
do $$
declare ok boolean := false;
begin
  begin
    update cc_sale set total = 1 where id = 's-a1';
  exception when insufficient_privilege then ok := true;
  end;
  assert ok, 'UPDATE on a sale must be refused outright';
end $$;

do $$
declare ok boolean := false;
begin
  begin
    delete from cc_sale where id = 's-a1';
  exception when insufficient_privilege then ok := true;
  end;
  assert ok, 'DELETE on a sale must be refused outright';
end $$;

\echo '--- 4. a till cannot unfreeze itself'
do $$
declare ok boolean := false;
begin
  begin
    update cc_shop set frozen = false, until = null;
  exception when insufficient_privilege then ok := true;
  end;
  assert ok, 'a till must not be able to write its own standing';
end $$;

\echo '--- 5. voiding folds onto the sale, once'
insert into cc_void (shop_id, id, sale_id, at, voided_by, reason)
values (:'shop_a', 'v-1', 's-a1', now(), 'Owner', 'wrong item');

do $$ begin
  assert (select voided_at from cc_sale where id = 's-a1') is not null, 'the void should land';
  assert (select void_reason from cc_sale where id = 's-a1') = 'wrong item', 'with its reason';
end $$;

insert into cc_void (shop_id, id, sale_id, at, voided_by, reason)
values (:'shop_a', 'v-2', 's-a1', now(), 'Someone else', 'changed my mind');

do $$ begin
  assert (select voided_by from cc_sale where id = 's-a1') = 'Owner',
    'a second void must not rewrite who approved the first';
end $$;

\echo '--- 6. two tills selling the same thing offline both count'
insert into cc_stock_move (shop_id, id, till_id, product_id, delta, reason, at)
values (:'shop_a', 'm-open', 'T1', 'p-rice', 10, 'opening', now());
insert into cc_stock_move (shop_id, id, till_id, product_id, delta, reason, at)
values (:'shop_a', 'm-t1', 'T1', 'p-rice', -2, 'sold', now());
insert into cc_stock_move (shop_id, id, till_id, product_id, delta, reason, at)
values (:'shop_a', 'm-t2', 'T2', 'p-rice', -2, 'sold', now());

do $$ begin
  assert (select stock from cc_stock_now where product_id = 'p-rice') = 6,
    'ten in, two off each till, six left — whatever order they arrived in';
end $$;

\echo '--- 7. the later price edit wins, even arriving first'
insert into cc_product_edit (shop_id, id, product_id, name, price, edited_at)
values (:'shop_a', 'pe-thu', 'p-rice', 'Rice 5kg', 9500, '2026-11-12 10:00+00');
insert into cc_product_edit (shop_id, id, product_id, name, price, edited_at)
values (:'shop_a', 'pe-tue', 'p-rice', 'Rice 5kg', 9000, '2026-11-10 10:00+00');

do $$ begin
  assert (select price from cc_product where id = 'p-rice') = 9500,
    'Tuesday arriving after Thursday must not undo Thursday';
  assert (select count(*) from cc_product_edit where product_id = 'p-rice') = 2,
    'and both edits stay in the history';
end $$;

\echo '--- 8. the debt book adds up'
insert into cc_customer_edit (shop_id, id, customer_id, name, phone, edited_at)
values (:'shop_a', 'ce-1', 'c-1', 'Abu Omar', '+9647701234567', now());
insert into cc_debt (shop_id, id, customer_id, amount, at)
values (:'shop_a', 'd-1', 'c-1', 9000, now());
insert into cc_debt (shop_id, id, customer_id, amount, at)
values (:'shop_a', 'd-2', 'c-1', -4000, now());

do $$ begin
  assert (select owed from cc_owing() where customer_id = 'c-1') = 5000,
    'nine thousand taken, four paid off, five owed';
  assert (select name from cc_owing() where customer_id = 'c-1') = 'Abu Omar',
    'and the owner sees a name, not an id';
end $$;

\echo '--- 9. the owner page figures'
do $$
declare r record;
begin
  select * into r from cc_day('00:00', null);
  assert r.sales_count = 1,  format('one sale stands after the void, got %s', r.sales_count);
  assert r.takings = 4500,   format('a voided sale leaves the takings, got %s', r.takings);
  assert r.on_book = 4500,   format('it was on the book, got %s', r.on_book);
  assert r.voided_count = 1, 'and the void is still reported';
  assert r.voided_value = 18000, 'with its value';
end $$;

do $$ begin
  assert (select qty from cc_top_products('00:00', null, 5) where name = 'Tea 500g') = 1,
    'the standing sale is counted';
  assert not exists (select 1 from cc_top_products('00:00', null, 5) where name = 'Rice 5kg'),
    'the voided one is not';
end $$;

\echo '--- 10. SHOP B CANNOT SEE ANY OF IT'
select t_be('22222222-2222-2222-2222-222222222222');

do $$ begin
  assert (select count(*) from cc_sale)          = 0, 'shop B must see no sales of shop A';
  assert (select count(*) from cc_debt)          = 0, 'nor debts';
  assert (select count(*) from cc_stock_move)    = 0, 'nor stock movements';
  assert (select count(*) from cc_product)       = 0, 'nor products';
  assert (select count(*) from cc_customer)      = 0, 'nor customers';
  assert (select count(*) from cc_void)          = 0, 'nor voids';
  assert (select count(*) from cc_product_edit)  = 0, 'nor the edit history';
  assert (select count(*) from cc_stock_now)     = 0, 'nor the stock view';
  assert (select count(*) from cc_shop)          = 1, 'and exactly one shop: its own';
  assert (select name from cc_shop) = 'TEST Shop B', 'which is its own';
  assert (select count(*) from cc_owing())       = 0, 'the owner page shows it nothing either';
  assert (select coalesce(sum(takings), 0) from cc_day('00:00', null)) = 0, 'nor any takings';
end $$;

\echo '--- 11. nor write into it'
do $$
declare ok boolean := false;
begin
  begin
    insert into cc_sale (shop_id, id, at, total)
    values (current_setting('test.shop_a')::uuid, 's-forged', now(), 1);
  exception when insufficient_privilege then ok := true;
  end;
  assert ok, 'shop B must not be able to write a row into shop A';
end $$;

do $$
declare ok boolean := false;
begin
  begin
    insert into cc_member (user_id, shop_id)
    values ('22222222-2222-2222-2222-222222222222',
            current_setting('test.shop_a')::uuid);
  exception when insufficient_privilege then ok := true;
  end;
  assert ok, 'and must not be able to join itself to shop A';
end $$;

\echo '--- 12. signed out, nothing at all'
reset role;
set local role anon;
do $$
declare ok boolean := false;
begin
  begin
    perform count(*) from cc_sale;
  exception when insufficient_privilege then ok := true;
  end;
  assert ok, 'the publishable key alone must open nothing';
end $$;

reset role;

\echo '--- all assertions passed'

rollback;
