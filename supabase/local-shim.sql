-- Supabase, pretended, so the schema can be tested without one.
--
-- A Supabase project arrives with an `auth` schema, an `auth.uid()` that
-- reads the signed-in user out of the request, and the `anon` /
-- `authenticated` / `service_role` roles PostgREST connects as. This makes
-- those in a bare Postgres so that schema.sql and rls-test.sql can be run
-- exactly as they will be run there — on a laptop, in a sandbox, in CI, with
-- no project and no network.
--
--   initdb -D pgdata && pg_ctl -D pgdata -o "-p 5433" start
--   createdb -p 5433 corecashier
--   psql -p 5433 -d corecashier -v ON_ERROR_STOP=1 \
--        -f supabase/local-shim.sql -f supabase/schema.sql -f supabase/rls-test.sql
--
-- Never run this against a real project: it would be creating, badly, things
-- that are already there.

-- What Supabase already has in a project, recreated locally so schema.sql
-- can be run exactly as it will be run there. Not part of the real schema.
do $$ begin
  if not exists (select 1 from pg_roles where rolname='anon') then create role anon nologin; end if;
  if not exists (select 1 from pg_roles where rolname='authenticated') then create role authenticated nologin; end if;
  if not exists (select 1 from pg_roles where rolname='service_role') then create role service_role nologin bypassrls; end if;
end $$;
create extension if not exists pgcrypto;
create schema if not exists auth;
create table if not exists auth.users (
  id uuid primary key default gen_random_uuid(),
  email text unique
);
create or replace function auth.uid() returns uuid language sql stable as $$
  select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid;
$$;
grant usage on schema public to anon, authenticated, service_role;
grant usage on schema auth to authenticated, service_role;
alter default privileges in schema public grant all on tables to anon, authenticated, service_role;
