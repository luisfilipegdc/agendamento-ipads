-- =============================================================================
-- Row Level Security.
-- Regra geral: professor enxerga a agenda inteira da sua unidade (precisa ver o
-- saldo para escolher horário) mas só altera as próprias reservas.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Helpers. SECURITY DEFINER + search_path fixo para não serem sequestrados.
-- -----------------------------------------------------------------------------
create or replace function tem_papel(p_papel papel, p_unidade uuid default null)
returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from pessoa_papel pp
     where pp.pessoa_id = auth.uid()
       and pp.papel = p_papel
       and (p_unidade is null or pp.unidade_id = p_unidade)
  );
$$;

create or replace function eh_gestor(p_unidade uuid default null)
returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from pessoa_papel pp
     where pp.pessoa_id = auth.uid()
       and pp.papel in ('COORDENACAO', 'ADMIN')
       and (p_unidade is null or pp.unidade_id = p_unidade or pp.papel = 'ADMIN')
  );
$$;

create or replace function minha_unidade() returns uuid
language sql stable security definer set search_path = public as $$
  select unidade_id from pessoa where id = auth.uid();
$$;

-- Unidades que o usuário alcança: a sua + aquelas em que tem papel.
create or replace function minhas_unidades() returns setof uuid
language sql stable security definer set search_path = public as $$
  select unidade_id from pessoa where id = auth.uid() and unidade_id is not null
  union
  select unidade_id from pessoa_papel where pessoa_id = auth.uid()
                                        and unidade_id is not null
  union
  select id from unidade where tem_papel('ADMIN');
$$;

-- -----------------------------------------------------------------------------
alter table unidade            enable row level security;
alter table segmento           enable row level security;
alter table local              enable row level security;
alter table turma              enable row level security;
alter table pessoa             enable row level security;
alter table pessoa_papel       enable row level security;
alter table pool               enable row level security;
alter table pool_segmento      enable row level security;
alter table equipamento        enable row level security;
alter table horario            enable row level security;
alter table excecao_calendario enable row level security;
alter table janela_apoio       enable row level security;
alter table reserva            enable row level security;
alter table tarefa             enable row level security;
alter table ocorrencia         enable row level security;
alter table notificacao        enable row level security;
alter table convite_calendario enable row level security;
alter table dominio_permitido  enable row level security;
alter table config_notificacao enable row level security;
alter table auditoria          enable row level security;

-- -----------------------------------------------------------------------------
-- Cadastros: todo mundo autenticado lê; só gestor escreve.
-- -----------------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['unidade','segmento','local','turma','pool',
                           'pool_segmento','horario','excecao_calendario',
                           'janela_apoio','equipamento','config_notificacao']
  loop
    execute format(
      'create policy %I on %I for select to authenticated using (true)',
      t || '_leitura', t);
    execute format(
      'create policy %I on %I for all to authenticated
         using (eh_gestor()) with check (eh_gestor())',
      t || '_gestao', t);
  end loop;
end $$;

-- -----------------------------------------------------------------------------
-- Pessoas
-- -----------------------------------------------------------------------------
create policy pessoa_le_a_si on pessoa
  for select to authenticated
  using (id = auth.uid() or unidade_id in (select minhas_unidades()));

create policy pessoa_edita_a_si on pessoa
  for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());

create policy pessoa_gestao on pessoa
  for all to authenticated
  using (eh_gestor()) with check (eh_gestor());

create policy papel_leitura on pessoa_papel
  for select to authenticated
  using (pessoa_id = auth.uid() or eh_gestor());

-- Só ADMIN concede papéis. Coordenação não se autopromove.
create policy papel_gestao on pessoa_papel
  for all to authenticated
  using (tem_papel('ADMIN')) with check (tem_papel('ADMIN'));

create policy dominio_leitura on dominio_permitido
  for select to authenticated using (true);
create policy dominio_gestao on dominio_permitido
  for all to authenticated
  using (tem_papel('ADMIN')) with check (tem_papel('ADMIN'));

-- -----------------------------------------------------------------------------
-- Reservas
-- -----------------------------------------------------------------------------
-- Ver a agenda inteira da unidade é necessário: o professor precisa enxergar
-- o que já está ocupado para escolher horário.
create policy reserva_leitura on reserva
  for select to authenticated
  using (
    professor_id = auth.uid()
    or exists (select 1 from pool p
                where p.id = reserva.pool_id
                  and p.unidade_id in (select minhas_unidades()))
  );

-- Cria só para si, e só em frota da sua unidade.
create policy reserva_cria on reserva
  for insert to authenticated
  with check (
    (professor_id = auth.uid() or eh_gestor())
    and exists (select 1 from pool p
                 where p.id = reserva.pool_id
                   and p.unidade_id in (select minhas_unidades()))
  );

create policy reserva_altera on reserva
  for update to authenticated
  using (professor_id = auth.uid()
         or eh_gestor()
         or tem_papel('ESTAGIARIO', (select unidade_id from pool
                                      where id = reserva.pool_id)))
  with check (professor_id = auth.uid()
              or eh_gestor()
              or tem_papel('ESTAGIARIO', (select unidade_id from pool
                                           where id = reserva.pool_id)));

-- Ninguém apaga reserva: cancela. Preserva o histórico.
create policy reserva_remove on reserva
  for delete to authenticated using (tem_papel('ADMIN'));

-- -----------------------------------------------------------------------------
-- Tarefas: fila do estagiário
-- -----------------------------------------------------------------------------
create policy tarefa_leitura on tarefa
  for select to authenticated
  using (unidade_id in (select minhas_unidades()));

create policy tarefa_execucao on tarefa
  for update to authenticated
  using (tem_papel('ESTAGIARIO', unidade_id) or eh_gestor(unidade_id))
  with check (tem_papel('ESTAGIARIO', unidade_id) or eh_gestor(unidade_id));

create policy tarefa_gestao on tarefa
  for all to authenticated
  using (eh_gestor(unidade_id)) with check (eh_gestor(unidade_id));

-- -----------------------------------------------------------------------------
-- Ocorrências
-- -----------------------------------------------------------------------------
create policy ocorrencia_leitura on ocorrencia
  for select to authenticated
  using (exists (select 1 from pool p
                  where p.id = ocorrencia.pool_id
                    and p.unidade_id in (select minhas_unidades())));

create policy ocorrencia_registro on ocorrencia
  for insert to authenticated
  with check (exists (select 1 from pool p
                       where p.id = ocorrencia.pool_id
                         and (tem_papel('ESTAGIARIO', p.unidade_id)
                              or eh_gestor(p.unidade_id))));

create policy ocorrencia_gestao on ocorrencia
  for update to authenticated
  using (exists (select 1 from pool p
                  where p.id = ocorrencia.pool_id and eh_gestor(p.unidade_id)));

-- -----------------------------------------------------------------------------
-- Convites de calendário
-- -----------------------------------------------------------------------------
create policy convite_leitura on convite_calendario
  for select to authenticated
  using (exists (select 1 from reserva r
                  where r.id = convite_calendario.reserva_id
                    and r.professor_id = auth.uid()));

-- -----------------------------------------------------------------------------
-- Notificações e auditoria: só o worker (service_role) mexe.
-- Nenhuma policy para authenticated = ninguém autenticado enxerga a fila.
-- -----------------------------------------------------------------------------
create policy notificacao_propria on notificacao
  for select to authenticated using (destinatario_id = auth.uid());

create policy auditoria_leitura on auditoria
  for select to authenticated using (eh_gestor());

-- -----------------------------------------------------------------------------
-- Provisionamento no primeiro acesso.
-- O magic link só é aceito se o domínio do e-mail estiver cadastrado.
-- -----------------------------------------------------------------------------
create or replace function provisiona_pessoa()
returns trigger
language plpgsql security definer set search_path = public, auth as $$
declare
  v_dom  dominio_permitido%rowtype;
  v_nome text;
begin
  select * into v_dom from dominio_permitido
   where dominio = lower(split_part(new.email, '@', 2));

  if not found then
    raise exception 'Domínio de e-mail não autorizado: %',
      split_part(new.email, '@', 2);
  end if;

  v_nome := coalesce(new.raw_user_meta_data->>'full_name',
                     new.raw_user_meta_data->>'name',
                     initcap(replace(split_part(new.email, '@', 1), '.', ' ')));

  insert into pessoa (id, nome, email, unidade_id)
  values (new.id, v_nome, lower(new.email), v_dom.unidade_id)
  on conflict (id) do nothing;

  insert into pessoa_papel (pessoa_id, papel, unidade_id)
  values (new.id, v_dom.papel_padrao, v_dom.unidade_id)
  on conflict do nothing;

  return new;
end;
$$;

create trigger trg_provisiona_pessoa
  after insert on auth.users
  for each row execute function provisiona_pessoa();

comment on function provisiona_pessoa is
  'Primeiro acesso via magic link: cria o perfil e o papel padrão a partir do '
  'domínio do e-mail. Domínio fora da lista é recusado.';

-- -----------------------------------------------------------------------------
-- Auditoria das reservas
-- -----------------------------------------------------------------------------
create or replace function audita() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into auditoria (tabela, registro_id, acao, ator_id, antes, depois)
  values (tg_table_name,
          coalesce(new.id, old.id),
          tg_op,
          auth.uid(),
          case when tg_op = 'INSERT' then null else to_jsonb(old) end,
          case when tg_op = 'DELETE' then null else to_jsonb(new) end);
  return coalesce(new, old);
end $$;

create trigger trg_audita_reserva
  after insert or update or delete on reserva
  for each row execute function audita();

create trigger trg_audita_tarefa
  after update on tarefa
  for each row execute function audita();
