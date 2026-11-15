-- CoreCashier — the shop's half of the cloud.
-- SPDX-License-Identifier: Apache-2.0
--
-- Run this once, whole, in the Supabase SQL Editor. It is written to be run
-- again safely: every statement is `if not exists` or `create or replace`.
--
--
-- THE ONE IDEA
--
-- Everything a till sends is an INSERT of a row it has already written to its
-- own tablet, carrying an id the tablet made. Nothing is ever sent as an
-- update. A till that pushes the same sale five times — which is the normal
-- case on a connection that dies mid-request — inserts it once and is told
-- "already have it" four times.
--
-- That is why the event tables below have no UPDATE and no DELETE policy at
-- all. Not "a till shouldn't change a sale": a till *cannot*. The database
-- refuses. A sale, a void, a debt line and a stock movement are things that
-- happened, and things that happened do not get edited.
--
-- State that does change — a product's price, a customer's phone, whether a
-- sale was voided — is kept in separate tables that no till may write to
-- either. They are maintained by the triggers at the bottom of this file,
-- from the events. So the history is not something we remember to keep; it
-- is the only thing we store, and the current state is derived from it.
--
--
-- AND STOCK
--
-- Stock is the reason this is event-sourced rather than row-synced. Two
-- tills in one shop, both offline, both selling the last of the rice: if
-- stock were a number each till pushed, whichever synced last would win and
-- the shop would be short. As movements — "-2 from till 1", "-2 from till
-- 2" — both land and the arithmetic is right whatever order they arrive in.

begin;

-- gen_random_uuid(), for shop ids made here rather than on a tablet.
create extension if not exists pgcrypto;


-- ---------------------------------------------------------------- the shop

create table if not exists cc_shop (
  id             uuid primary key default gen_random_uuid(),
  name           text        not null,
  -- Set by CoreOS alone. A till can read this and can never write it, which
  -- is the whole of the subscription: if stopping a till were something the
  -- till could undo, it would not be stopping it.
  frozen         boolean     not null default false,
  frozen_message text        not null default '',
  -- When the subscription runs out. Null means no end date.
  until          timestamptz,
  -- How many days a tablet may go without reaching us before it stops on its
  -- own. Without this, pulling the wifi out would keep a frozen till working
  -- for ever. Two weeks survives a bad month of Iraqi connectivity.
  grace_days     integer     not null default 14,
  created_at     timestamptz not null default now()
);

comment on table cc_shop is 'One row per shop. Only CoreOS writes it.';


-- Which sign-in belongs to which shop. One shop, one account, many tills.
create table if not exists cc_member (
  user_id uuid primary key references auth.users (id) on delete cascade,
  shop_id uuid not null references cc_shop (id) on delete cascade,
  created_at timestamptz not null default now()
);

create index if not exists cc_member_shop on cc_member (shop_id);


/*
 * Which shop is asking.
 *
 * Every policy in this file is written against this one function, so there
 * is exactly one place where "whose rows are these" is decided, and it can
 * be read in four lines.
 *
 * `security definer` because the policies on cc_member would otherwise have
 * to call this to check cc_member, which is a loop. `search_path` is pinned
 * because a security-definer function that resolves names through the
 * caller's path is a way in.
 */
create or replace function cc_my_shop()
  returns uuid
  language sql
  stable
  security definer
  set search_path = public, pg_temp
as $$
  select shop_id from cc_member where user_id = auth.uid()
$$;

revoke all on function cc_my_shop() from public;
grant execute on function cc_my_shop() to authenticated;


-- The tablets. A till says hello so a support desk holding fifty of them can
-- tell which is which and when each was last awake.
create table if not exists cc_till (
  shop_id   uuid        not null references cc_shop (id) on delete cascade,
  id        text        not null,
  label     text        not null default '',
  build     text        not null default '',
  last_seen timestamptz not null default now(),
  primary key (shop_id, id)
);


-- ------------------------------------------------------------- the events
--
-- Insert-only, every one of them. `id` is made on the tablet, so re-sending
-- is free: the primary key does the deduplicating and the till never has to
-- know whether its last request got through.
--
-- `at` is the tablet's clock and is what the shop sees. `server_at` is ours
-- and is what the pull cursor uses — tablet clocks in these shops are wrong
-- often enough that a cursor trusting them would skip a day of trade.

create table if not exists cc_sale (
  shop_id       uuid        not null references cc_shop (id) on delete cascade,
  id            text        not null,
  till_id       text        not null default '',
  receipt_no    text        not null default '',
  at            timestamptz not null,
  -- The lines as they were sold: name and price copied, not referenced. A
  -- receipt from March has to still read as March's prices after the shelf
  -- price changes.
  lines         jsonb       not null default '[]'::jsonb,
  subtotal      integer     not null default 0,
  discount      integer     not null default 0,
  rounding      integer     not null default 0,
  total         integer     not null default 0,
  method        text        not null default 'cash',
  tendered      integer     not null default 0,
  change_given  integer     not null default 0,
  staff_name    text        not null default '',
  customer_id   text,
  customer_name text        not null default '',
  -- Filled in by the trigger on cc_void, never by a till.
  voided_at     timestamptz,
  voided_by     text        not null default '',
  void_reason   text        not null default '',
  server_at     timestamptz not null default now(),
  primary key (shop_id, id)
);

create index if not exists cc_sale_pull on cc_sale (shop_id, server_at);
create index if not exists cc_sale_day  on cc_sale (shop_id, at);


-- Voiding a sale is its own event, so that the sale itself stays insert-only
-- and both can be re-sent for ever without harm.
create table if not exists cc_void (
  shop_id   uuid        not null references cc_shop (id) on delete cascade,
  id        text        not null,
  sale_id   text        not null,
  at        timestamptz not null,
  voided_by text        not null default '',
  reason    text        not null default '',
  server_at timestamptz not null default now(),
  primary key (shop_id, id)
);

create index if not exists cc_void_pull on cc_void (shop_id, server_at);


-- Stock, as movements. See the note at the top of this file.
create table if not exists cc_stock_move (
  shop_id    uuid        not null references cc_shop (id) on delete cascade,
  id         text        not null,
  till_id    text        not null default '',
  product_id text        not null,
  -- Negative for goods leaving, positive for goods arriving.
  delta      integer     not null,
  -- 'sold' | 'void' | 'received' | 'counted' | 'opening'
  reason     text        not null default 'sold',
  sale_id    text,
  at         timestamptz not null,
  server_at  timestamptz not null default now(),
  primary key (shop_id, id)
);

create index if not exists cc_stock_move_pull    on cc_stock_move (shop_id, server_at);
create index if not exists cc_stock_move_product on cc_stock_move (shop_id, product_id);


-- Every edit to a product, in order. This is both the wire format and the
-- change history the brief asks for — we do not keep one and derive the
-- other, we keep the edits and derive the product.
create table if not exists cc_product_edit (
  shop_id      uuid        not null references cc_shop (id) on delete cascade,
  id           text        not null,
  product_id   text        not null,
  name         text        not null default '',
  barcode      text        not null default '',
  category     text        not null default '',
  price        integer     not null default 0,
  low_stock_at integer     not null default -1,
  archived     boolean     not null default false,
  -- The tablet's clock, and the thing last-edit-wins is decided on.
  edited_at    timestamptz not null,
  till_id      text        not null default '',
  server_at    timestamptz not null default now(),
  primary key (shop_id, id)
);

create index if not exists cc_product_edit_pull on cc_product_edit (shop_id, server_at);
create index if not exists cc_product_edit_item on cc_product_edit (shop_id, product_id, edited_at desc);


create table if not exists cc_customer_edit (
  shop_id     uuid        not null references cc_shop (id) on delete cascade,
  id          text        not null,
  customer_id text        not null,
  name        text        not null default '',
  phone       text        not null default '',
  edited_at   timestamptz not null,
  server_at   timestamptz not null default now(),
  primary key (shop_id, id)
);

create index if not exists cc_customer_edit_pull on cc_customer_edit (shop_id, server_at);


-- The debt book. One signed column rather than a kind: a tab is the sum of
-- its lines, and a reader who has to know the word "owed" to add them up
-- will get it wrong one day.
create table if not exists cc_debt (
  shop_id     uuid        not null references cc_shop (id) on delete cascade,
  id          text        not null,
  customer_id text        not null default '',
  -- Positive: goods taken on the book. Negative: money paid off.
  amount      integer     not null,
  note        text        not null default '',
  receipt_no  text        not null default '',
  sale_id     text,
  staff_name  text        not null default '',
  till_id     text        not null default '',
  at          timestamptz not null,
  server_at   timestamptz not null default now(),
  primary key (shop_id, id)
);

create index if not exists cc_debt_pull     on cc_debt (shop_id, server_at);
create index if not exists cc_debt_customer on cc_debt (shop_id, customer_id);


create table if not exists cc_close (
  shop_id      uuid        not null references cc_shop (id) on delete cascade,
  id           text        not null,
  till_id      text        not null default '',
  day          date        not null,
  closed_at    timestamptz not null,
  staff_name   text        not null default '',
  sales_count  integer     not null default 0,
  takings      integer     not null default 0,
  counted_cash integer     not null default 0,
  difference   integer     not null default 0,
  server_at    timestamptz not null default now(),
  primary key (shop_id, id)
);

create index if not exists cc_close_pull on cc_close (shop_id, server_at);


-- -------------------------------------------------------------- the state
--
-- Derived, by the triggers below, from the events above. No till writes
-- these. They exist so that a tablet joining a shop for the first time can
-- read what the shelf looks like now instead of replaying four years of
-- edits, and so the owner's phone can answer a question in one query.

create table if not exists cc_product (
  shop_id      uuid        not null references cc_shop (id) on delete cascade,
  id           text        not null,
  name         text        not null default '',
  barcode      text        not null default '',
  category     text        not null default '',
  price        integer     not null default 0,
  low_stock_at integer     not null default -1,
  archived     boolean     not null default false,
  edited_at    timestamptz not null,
  primary key (shop_id, id)
);

create table if not exists cc_customer (
  shop_id   uuid        not null references cc_shop (id) on delete cascade,
  id        text        not null,
  name      text        not null default '',
  phone     text        not null default '',
  edited_at timestamptz not null,
  primary key (shop_id, id)
);


/*
 * What is on the shelf, by the only definition that survives two tills
 * selling at once: the sum of everything that moved.
 *
 * `security_invoker` is not optional and is not a detail. A view without it
 * runs as the role that created it, which means the row-level security on
 * cc_stock_move underneath is evaluated as *that* role rather than as the
 * till asking — and every shop's stock comes back to every shop. This was
 * caught by supabase/rls-test.sql, which is the entire reason that file
 * exists. Any view added to this schema needs the same thing.
 */
create or replace view cc_stock_now
  with (security_invoker = true) as
  select shop_id, product_id, sum(delta)::integer as stock, max(at) as last_move
    from cc_stock_move
   group by shop_id, product_id;


commit;


-- ------------------------------------------------------------ the folding
--
-- Each of these turns an event into current state. They are the only writers
-- the state tables have.

begin;

/*
 * A void lands on its sale.
 *
 * `where voided_at is null` is not an optimisation. A sale is voided once;
 * if a second void event for the same sale ever arrives — two tills, two
 * cashiers, one argument — the first one stands, with its reason and the
 * name of whoever approved it. Overwriting it would quietly rewrite who
 * authorised giving the money back.
 */
create or replace function cc_apply_void()
  returns trigger
  language plpgsql
  security definer
  set search_path = public, pg_temp
as $$
begin
  update cc_sale
     set voided_at   = new.at,
         voided_by   = new.voided_by,
         void_reason = new.reason
   where shop_id = new.shop_id
     and id      = new.sale_id
     and voided_at is null;
  return new;
end;
$$;

drop trigger if exists cc_void_applies on cc_void;
create trigger cc_void_applies
  after insert on cc_void
  for each row execute function cc_apply_void();


/*
 * Last edit wins, by the tablet's clock.
 *
 * The `where` clause is the whole conflict rule, and it has to be here
 * rather than in the till: edits do not arrive in the order they were made.
 * A tablet that was offline for three days pushes Tuesday's price change on
 * Friday, long after another till changed the same price on Thursday. The
 * Thursday price is the right one, and this is what makes it stick
 * regardless of who syncs first.
 */
create or replace function cc_apply_product_edit()
  returns trigger
  language plpgsql
  security definer
  set search_path = public, pg_temp
as $$
begin
  insert into cc_product (shop_id, id, name, barcode, category, price,
                          low_stock_at, archived, edited_at)
  values (new.shop_id, new.product_id, new.name, new.barcode, new.category,
          new.price, new.low_stock_at, new.archived, new.edited_at)
  on conflict (shop_id, id) do update
     set name         = excluded.name,
         barcode      = excluded.barcode,
         category     = excluded.category,
         price        = excluded.price,
         low_stock_at = excluded.low_stock_at,
         archived     = excluded.archived,
         edited_at    = excluded.edited_at
   where excluded.edited_at > cc_product.edited_at;
  return new;
end;
$$;

drop trigger if exists cc_product_edit_applies on cc_product_edit;
create trigger cc_product_edit_applies
  after insert on cc_product_edit
  for each row execute function cc_apply_product_edit();


create or replace function cc_apply_customer_edit()
  returns trigger
  language plpgsql
  security definer
  set search_path = public, pg_temp
as $$
begin
  insert into cc_customer (shop_id, id, name, phone, edited_at)
  values (new.shop_id, new.customer_id, new.name, new.phone, new.edited_at)
  on conflict (shop_id, id) do update
     set name      = excluded.name,
         phone     = excluded.phone,
         edited_at = excluded.edited_at
   where excluded.edited_at > cc_customer.edited_at;
  return new;
end;
$$;

drop trigger if exists cc_customer_edit_applies on cc_customer_edit;
create trigger cc_customer_edit_applies
  after insert on cc_customer_edit
  for each row execute function cc_apply_customer_edit();

commit;


-- ----------------------------------------------------------------- locking
--
-- Row-level security, on every table, written against cc_my_shop() and
-- nothing else.
--
-- Read what is NOT here. No update policy and no delete policy on any event
-- table: a till cannot change or remove a sale, a void, a stock movement, a
-- debt line or a day's close. No write policy at all on cc_shop, cc_product
-- or cc_customer: a till cannot unfreeze itself, and it cannot write the
-- derived state except through the events the triggers read.
--
-- The triggers can, because they are `security definer` and run as the
-- owner. That is the only door into those tables and it is one-way.

begin;

alter table cc_shop          enable row level security;
alter table cc_member        enable row level security;
alter table cc_till          enable row level security;
alter table cc_sale          enable row level security;
alter table cc_void          enable row level security;
alter table cc_stock_move    enable row level security;
alter table cc_product_edit  enable row level security;
alter table cc_customer_edit enable row level security;
alter table cc_debt          enable row level security;
alter table cc_close         enable row level security;
alter table cc_product       enable row level security;
alter table cc_customer      enable row level security;

-- Belt as well as braces: RLS does not apply to the table owner, and a
-- future function marked `security definer` by mistake would otherwise read
-- every shop. These say the rules bind even then.
alter table cc_sale          force row level security;
alter table cc_debt          force row level security;
alter table cc_stock_move    force row level security;

do $$
declare
  t text;
begin
  -- The event tables: read your own, write your own, change nothing.
  foreach t in array array[
    'cc_sale', 'cc_void', 'cc_stock_move', 'cc_product_edit',
    'cc_customer_edit', 'cc_debt', 'cc_close'
  ] loop
    execute format('drop policy if exists cc_read on %I', t);
    execute format('drop policy if exists cc_add  on %I', t);
    execute format(
      'create policy cc_read on %I for select to authenticated
         using (shop_id = cc_my_shop())', t);
    execute format(
      'create policy cc_add on %I for insert to authenticated
         with check (shop_id = cc_my_shop())', t);
  end loop;

  -- The derived state: read only. The triggers do the writing.
  foreach t in array array['cc_product', 'cc_customer'] loop
    execute format('drop policy if exists cc_read on %I', t);
    execute format(
      'create policy cc_read on %I for select to authenticated
         using (shop_id = cc_my_shop())', t);
  end loop;
end;
$$;

-- The shop's own record: readable, never writable from a till.
drop policy if exists cc_read on cc_shop;
create policy cc_read on cc_shop
  for select to authenticated
  using (id = cc_my_shop());

-- You may see that you are a member, and nothing about anyone else.
drop policy if exists cc_read on cc_member;
create policy cc_read on cc_member
  for select to authenticated
  using (user_id = auth.uid());

-- A till announces itself and updates its own last-seen. It may read its
-- siblings, so a shop can see its own tablets.
drop policy if exists cc_read   on cc_till;
drop policy if exists cc_add    on cc_till;
drop policy if exists cc_update on cc_till;
create policy cc_read on cc_till
  for select to authenticated using (shop_id = cc_my_shop());
create policy cc_add on cc_till
  for insert to authenticated with check (shop_id = cc_my_shop());
create policy cc_update on cc_till
  for update to authenticated
  using (shop_id = cc_my_shop()) with check (shop_id = cc_my_shop());

commit;


-- ---------------------------------------------------------- what the till asks
--
-- One round trip: may this tablet still sell, and what should it say if not.

create or replace function cc_standing()
  returns table (frozen boolean, until timestamptz, grace_days integer, message text)
  language sql
  stable
  security definer
  set search_path = public, pg_temp
as $$
  select s.frozen, s.until, s.grace_days, s.frozen_message
    from cc_shop s
   where s.id = cc_my_shop()
$$;

revoke all on function cc_standing() from public;
grant execute on function cc_standing() to authenticated;


-- ------------------------------------------------------- the owner's phone
--
-- The shop owner opens a page on his phone and asks one question: what did
-- today do. Answered in one round trip rather than four, because he is on a
-- phone on Iraqi mobile data.
--
-- `day_starts_at` is the shop's own idea of when a day begins — a café
-- serving past midnight counts two in the morning as the night before, and
-- the till already works that way. Pass '00:00' for an ordinary shop.

create or replace function cc_day(day_starts_at text default '00:00',
                                  which date default null)
  returns table (
    day          date,
    sales_count  integer,
    takings      integer,
    cash         integer,
    card         integer,
    on_book      integer,
    voided_count integer,
    voided_value integer
  )
  language sql
  stable
  security definer
  set search_path = public, pg_temp
as $$
  with shifted as (
    select s.*,
           (s.at - day_starts_at::interval)::date as trading_day
      from cc_sale s
     where s.shop_id = cc_my_shop()
  ),
  pick as (
    select coalesce(which, (now() - day_starts_at::interval)::date) as d
  )
  select
    (select d from pick),
    count(*) filter (where voided_at is null)::integer,
    coalesce(sum(total) filter (where voided_at is null), 0)::integer,
    coalesce(sum(total) filter (where voided_at is null and method = 'cash'), 0)::integer,
    coalesce(sum(total) filter (where voided_at is null and method = 'card'), 0)::integer,
    coalesce(sum(total) filter (where voided_at is null and method = 'later'), 0)::integer,
    count(*) filter (where voided_at is not null)::integer,
    coalesce(sum(total) filter (where voided_at is not null), 0)::integer
  from shifted, pick
  where trading_day = pick.d
$$;

revoke all on function cc_day(text, date) from public;
grant execute on function cc_day(text, date) to authenticated;


-- What moved off the shelf, by count rather than by money: one expensive
-- thing outselling nothing is not a best seller.
create or replace function cc_top_products(day_starts_at text default '00:00',
                                           which date default null,
                                           how_many integer default 5)
  returns table (name text, qty integer, takings integer)
  language sql
  stable
  security definer
  set search_path = public, pg_temp
as $$
  select line->>'name' as name,
         sum((line->>'qty')::numeric)::integer as qty,
         sum((line->>'qty')::numeric * (line->>'price')::numeric)::integer as takings
    from cc_sale s
    cross join lateral jsonb_array_elements(s.lines) as line
   where s.shop_id = cc_my_shop()
     and s.voided_at is null
     and (s.at - day_starts_at::interval)::date
         = coalesce(which, (now() - day_starts_at::interval)::date)
   group by line->>'name'
   order by qty desc
   limit greatest(how_many, 1)
$$;

revoke all on function cc_top_products(text, date, integer) from public;
grant execute on function cc_top_products(text, date, integer) to authenticated;


-- Who owes the shop, most first. A customer who has paid off is left out
-- rather than listed at zero.
create or replace function cc_owing()
  returns table (customer_id text, name text, phone text, owed integer, last_at timestamptz)
  language sql
  stable
  security definer
  set search_path = public, pg_temp
as $$
  select d.customer_id,
         coalesce(c.name, '—'),
         coalesce(c.phone, ''),
         sum(d.amount)::integer as owed,
         max(d.at)
    from cc_debt d
    left join cc_customer c
      on c.shop_id = d.shop_id and c.id = d.customer_id
   where d.shop_id = cc_my_shop()
   group by d.customer_id, c.name, c.phone
  having sum(d.amount) <> 0
   order by owed desc
$$;

revoke all on function cc_owing() from public;
grant execute on function cc_owing() to authenticated;


-- ------------------------------------------------------------------ CoreOS
--
-- Run by hand, in the SQL Editor, as the project owner. Not reachable from a
-- till: these are not granted to `authenticated` and never should be.

/*
 * Put an account with a shop, making the shop if it is new.
 *
 *   select cc_link('shop@example.com', 'Al-Noor Market');
 *
 * The account must exist already — Authentication, Users, Add user. Calling
 * it twice with the same email moves that account to the named shop rather
 * than failing, which is what you want when you have typed the shop's name
 * wrongly and noticed.
 */
create or replace function cc_link(user_email text, shop_name text)
  returns uuid
  language plpgsql
  security definer
  set search_path = public, pg_temp, auth
as $$
declare
  who  uuid;
  shop uuid;
begin
  select id into who from auth.users where lower(email) = lower(user_email);
  if who is null then
    raise exception 'No account for %. Create it first under Authentication, Users.', user_email;
  end if;

  select id into shop from cc_shop where name = shop_name;
  if shop is null then
    insert into cc_shop (name) values (shop_name) returning id into shop;
  end if;

  insert into cc_member (user_id, shop_id) values (who, shop)
  on conflict (user_id) do update set shop_id = excluded.shop_id;

  return shop;
end;
$$;

revoke all on function cc_link(text, text) from public;


/*
 * Stop a shop, or let it go again.
 *
 *   select cc_freeze('Al-Noor Market', true, 'Subscription unpaid — call CoreOS');
 *
 * The till picks this up within two minutes of next seeing the internet. It
 * stops the till taking new sales; it never touches a row of the shop's
 * data, and the shop can still read and export everything it has. That is
 * the contract, and it is enforced by there being no delete in this file.
 */
create or replace function cc_freeze(shop_name text, stop boolean, why text default '')
  returns void
  language sql
  security definer
  set search_path = public, pg_temp
as $$
  update cc_shop
     set frozen = stop,
         frozen_message = case when stop then why else '' end
   where name = shop_name
$$;

revoke all on function cc_freeze(text, boolean, text) from public;


-- ------------------------------------------------------------- privileges
--
-- Belt as well as braces.
--
-- Supabase grants `authenticated` everything on a new table by default and
-- leaves row-level security to do the work. That is one mistake deep: a
-- policy written wrongly one afternoon is the only thing between a cashier's
-- tablet and a DELETE across the shop's whole history.
--
-- So the privileges are taken back and handed out exactly: insert and select
-- on the things a till records, select alone on everything derived. There is
-- no UPDATE and no DELETE granted to anybody on any table in this file. A
-- sale cannot be deleted by a till even if every policy here were wrong,
-- because the permission does not exist.

begin;

do $$
declare
  t text;
begin
  foreach t in array array[
    'cc_shop', 'cc_member', 'cc_till', 'cc_sale', 'cc_void', 'cc_stock_move',
    'cc_product_edit', 'cc_customer_edit', 'cc_debt', 'cc_close',
    'cc_product', 'cc_customer'
  ] loop
    execute format('revoke all on table %I from anon, authenticated', t);
  end loop;

  -- Written by a till.
  foreach t in array array[
    'cc_sale', 'cc_void', 'cc_stock_move', 'cc_product_edit',
    'cc_customer_edit', 'cc_debt', 'cc_close'
  ] loop
    execute format('grant select, insert on table %I to authenticated', t);
  end loop;

  -- Read only.
  foreach t in array array['cc_shop', 'cc_member', 'cc_product', 'cc_customer'] loop
    execute format('grant select on table %I to authenticated', t);
  end loop;
end;
$$;

-- A till says hello and keeps its own last-seen fresh, so this one may be
-- updated — by its own shop, per the policy above.
grant select, insert, update on table cc_till to authenticated;

grant select on cc_stock_now to authenticated;

-- Signed out means nothing at all. The publishable key in the app is not a
-- credential and must open no door on its own.
revoke all on schema public from anon;

commit;
