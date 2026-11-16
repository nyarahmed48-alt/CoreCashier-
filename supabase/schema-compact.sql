begin;

create extension if not exists pgcrypto;

create table if not exists cc_shop (
  id             uuid primary key default gen_random_uuid(),
  name           text        not null,
  frozen         boolean     not null default false,
  frozen_message text        not null default '',
  until          timestamptz,
  grace_days     integer     not null default 14,
  created_at     timestamptz not null default now()
);

comment on table cc_shop is 'One row per shop. Only CoreOS writes it.';

create table if not exists cc_member (
  user_id uuid primary key references auth.users (id) on delete cascade,
  shop_id uuid not null references cc_shop (id) on delete cascade,
  created_at timestamptz not null default now()
);

create index if not exists cc_member_shop on cc_member (shop_id);

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

create table if not exists cc_till (
  shop_id   uuid        not null references cc_shop (id) on delete cascade,
  id        text        not null,
  label     text        not null default '',
  build     text        not null default '',
  last_seen timestamptz not null default now(),
  primary key (shop_id, id)
);

create table if not exists cc_sale (
  shop_id       uuid        not null references cc_shop (id) on delete cascade,
  id            text        not null,
  till_id       text        not null default '',
  receipt_no    text        not null default '',
  at            timestamptz not null,
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
  voided_at     timestamptz,
  voided_by     text        not null default '',
  void_reason   text        not null default '',
  server_at     timestamptz not null default now(),
  primary key (shop_id, id)
);

create index if not exists cc_sale_pull on cc_sale (shop_id, server_at);
create index if not exists cc_sale_day  on cc_sale (shop_id, at);

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

create table if not exists cc_stock_move (
  shop_id    uuid        not null references cc_shop (id) on delete cascade,
  id         text        not null,
  till_id    text        not null default '',
  product_id text        not null,
  delta      integer     not null,
  reason     text        not null default 'sold',
  sale_id    text,
  at         timestamptz not null,
  server_at  timestamptz not null default now(),
  primary key (shop_id, id)
);

create index if not exists cc_stock_move_pull    on cc_stock_move (shop_id, server_at);
create index if not exists cc_stock_move_product on cc_stock_move (shop_id, product_id);

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

create table if not exists cc_debt (
  shop_id     uuid        not null references cc_shop (id) on delete cascade,
  id          text        not null,
  customer_id text        not null default '',
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

create or replace view cc_stock_now
  with (security_invoker = true) as
  select shop_id, product_id, sum(delta)::integer as stock, max(at) as last_move
    from cc_stock_move
   group by shop_id, product_id;

commit;

begin;

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

drop policy if exists cc_read on cc_shop;
create policy cc_read on cc_shop
  for select to authenticated
  using (id = cc_my_shop());

drop policy if exists cc_read on cc_member;
create policy cc_read on cc_member
  for select to authenticated
  using (user_id = auth.uid());

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

grant select, insert, update on table cc_till to authenticated;

grant select on cc_stock_now to authenticated;

revoke all on schema public from anon;

commit;
