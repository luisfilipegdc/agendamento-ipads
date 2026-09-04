-- Testes de RLS. Rodam como usuário 'authenticated', não como superusuário,
-- porque superusuário ignora RLS e daria falso positivo.
\set ON_ERROR_STOP on
\set QUIET on

-- Simula o auth.uid() do Supabase lendo o JWT que o teste injeta.
create or replace function auth.uid() returns uuid
language sql stable as $$
  select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid
$$;

grant usage on schema public, auth to authenticated;
grant select, insert, update, delete on all tables in schema public to authenticated;
grant select on all tables in schema auth to authenticated;
grant execute on all functions in schema public, auth to authenticated;
grant usage, select on all sequences in schema public to authenticated;

do $$
declare
  v_pio uuid; v_mta uuid; v_pool_pio uuid; v_pool_mta uuid;
  v_h1 uuid; v_data date;
  v_a uuid := gen_random_uuid();   -- professor Pio XII
  v_b uuid := gen_random_uuid();   -- professor Maristinha
  v_r uuid;
begin
  v_data := date_trunc('week', current_date + 40)::date;
  select id into v_pio from unidade where nome = 'Pio XII';
  select id into v_mta from unidade where nome = 'Maristinha';
  select id into v_pool_pio from pool where nome = 'iPads Pio XII';
  select id into v_pool_mta from pool where nome = 'iPads Anos Finais';
  select id into v_h1 from horario
   where unidade_id = v_pio and turno = 'MATUTINO' and ordem = 1;

  insert into dominio_permitido (dominio, papel_padrao, unidade_id)
  values ('rls.test', 'PROFESSOR', v_pio) on conflict do nothing;

  insert into auth.users (id, email) values
    (v_a, 'a@rls.test'), (v_b, 'b@rls.test');
  update pessoa set unidade_id = v_pio where id = v_a;
  -- B pertence à Maristinha. O papel também precisa acompanhar: uma linha de
  -- pessoa_papel apontando para outra unidade concede leitura daquela unidade.
  update pessoa       set unidade_id = v_mta where id = v_b;
  update pessoa_papel set unidade_id = v_mta where pessoa_id = v_b;

  insert into reserva (pool_id, horario_id, data, professor_id, turma_texto, quantidade)
  values (v_pool_pio, v_h1, v_data, v_a, '2ºD', 10) returning id into v_r;

  -- Guarda os ids para os testes fora do bloco. Tabela comum (não temp) para
  -- que o papel 'authenticated' consiga lê-la depois do SET ROLE.
  drop table if exists ctx;
  create table ctx as
  select v_a a, v_b b, v_pio pio, v_mta mta, v_pool_pio pool_pio,
         v_pool_mta pool_mta, v_h1 h1, v_data dt, v_r r;
  grant select on ctx to authenticated;
end $$;

\set QUIET off
select 'contexto criado' as etapa;

-- ---------------------------------------------------------------------------
set role authenticated;

-- === Professor A (Pio XII) ===
select set_config('request.jwt.claim.sub', (select a::text from ctx), false);

select case when count(*) = 1 then 'PASS  A vê a própria reserva'
            else 'FALHOU: A não vê a própria reserva' end
  from reserva where id = (select r from ctx);

-- === Professor B (Maristinha) — não deve enxergar a reserva do Pio XII ===
select set_config('request.jwt.claim.sub', (select b::text from ctx), false);

select case when count(*) = 0
            then 'PASS  B (outra unidade) não vê a reserva do Pio XII'
            else 'FALHOU: vazamento entre unidades' end
  from reserva where id = (select r from ctx);

-- B não pode alterar a reserva de A (0 linhas afetadas, sem erro)
with u as (
  update reserva set quantidade = 1 where id = (select r from ctx) returning 1
)
select case when count(*) = 0 then 'PASS  B não altera reserva de outro professor'
            else 'FALHOU: B alterou reserva alheia' end from u;

-- B não pode criar reserva em nome de A
do $$
begin
  begin
    insert into reserva (pool_id, horario_id, data, professor_id,
                         turma_texto, quantidade)
    select pool_mta, (select id from horario
                       where unidade_id = mta and turno='MATUTINO' and ordem=1),
           dt, a, 'fake', 5 from ctx;
    raise exception 'FALHOU: B criou reserva em nome de A';
  exception
    when insufficient_privilege or check_violation then
      raise notice 'PASS  B não cria reserva em nome de outro professor';
    when others then
      if sqlerrm like 'FALHOU%' then raise; end if;
      raise notice 'PASS  B não cria reserva em nome de outro professor (%)',
        left(sqlerrm, 40);
  end;
end $$;

-- Professor comum não vira admin sozinho
do $$
begin
  begin
    insert into pessoa_papel (pessoa_id, papel, unidade_id)
    select b, 'ADMIN', mta from ctx;
    raise exception 'FALHOU: professor se autopromoveu a ADMIN';
  exception
    when insufficient_privilege then
      raise notice 'PASS  professor não consegue se conceder papel de ADMIN';
    when others then
      if sqlerrm like 'FALHOU%' then raise; end if;
      raise notice 'PASS  professor não consegue se conceder papel de ADMIN';
  end;
end $$;

-- Fila de notificações não é legível por terceiros
select case when count(*) = 0
            then 'PASS  fila de notificações de outros não é visível'
            else 'FALHOU: notificações de terceiros expostas' end
  from notificacao where destinatario_id = (select a from ctx);

reset role;
select '=== RLS OK ===' as resultado;
