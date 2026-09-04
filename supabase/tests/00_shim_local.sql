-- Reproduz o mínimo do ambiente Supabase para rodar as migrations num Postgres
-- local. NÃO faz parte das migrations — é só andaime de teste.
create schema if not exists auth;

create table if not exists auth.users (
  id                  uuid primary key,
  email               text,
  raw_user_meta_data  jsonb not null default '{}'::jsonb,
  created_at          timestamptz not null default now()
);

create or replace function auth.uid() returns uuid
language sql stable as $$
  select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid
$$;

create or replace function auth.jwt() returns jsonb
language sql stable as $$ select '{}'::jsonb $$;

do $$
begin
  if not exists (select 1 from pg_roles where rolname='anon')
    then create role anon; end if;
  if not exists (select 1 from pg_roles where rolname='authenticated')
    then create role authenticated; end if;
  if not exists (select 1 from pg_roles where rolname='service_role')
    then create role service_role; end if;
end $$;
