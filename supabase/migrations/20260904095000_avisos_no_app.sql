-- =============================================================================
-- Avisos dentro do sistema.
-- Sem e-mail configurado, a mesma fila de notificações vira a caixa de avisos
-- do painel. Ligar o e-mail depois é uma chave em config_sistema — as regras
-- que enfileiram não mudam.
-- =============================================================================

create table config_sistema (
  id            boolean primary key default true check (id),  -- linha única
  email_ativo   boolean not null default false,
  atualizado_em timestamptz not null default now()
);

insert into config_sistema (id, email_ativo) values (true, false);

comment on table config_sistema is
  'Linha única. email_ativo = false faz toda notificação nascer no canal APP; '
  'o worker de e-mail só consome linhas com canal EMAIL.';

alter table notificacao add column lida_em timestamptz;

create index notificacao_caixa_idx
  on notificacao (destinatario_id, agendada_para desc);

-- O canal passa a ser derivado da configuração.
create or replace function enfileira_notificacao(
  p_chave text, p_pessoa uuid, p_assunto text, p_corpo text,
  p_quando timestamptz default now(), p_canal text default null,
  p_reserva uuid default null
) returns void
language plpgsql as $$
declare
  v_email text;
  v_canal text;
begin
  select email into v_email from pessoa where id = p_pessoa;
  if v_email is null then return; end if;

  -- p_canal explícito vence; senão, segue a configuração do sistema.
  v_canal := coalesce(
    p_canal,
    case when (select email_ativo from config_sistema) then 'EMAIL' else 'APP' end
  );

  insert into notificacao (chave, destinatario_id, destinatario_email,
                           canal, assunto, corpo, agendada_para, reserva_id)
  values (p_chave, p_pessoa, v_email, v_canal, p_assunto, p_corpo, p_quando,
          p_reserva)
  on conflict (chave) do nothing;   -- nunca envia duas vezes
end;
$$;

-- As chamadas em pos_reserva/marca_atrasadas passavam 'EMAIL' fixo. Com a
-- configuração no lugar, devem passar NULL para respeitá-la.
create or replace function pos_reserva()
returns trigger
language plpgsql as $$
declare
  h          horario%rowtype;
  v_unidade  unidade%rowtype;
  v_prof     pessoa%rowtype;
  v_pool     pool%rowtype;
  v_turma    text;
  v_coord    record;
  v_resumo   text;
begin
  select * into h from horario where id = new.horario_id;
  select * into v_pool from pool where id = new.pool_id;
  select * into v_unidade from unidade where id = v_pool.unidade_id;
  select * into v_prof from pessoa where id = new.professor_id;

  v_turma := coalesce((select nome from turma where id = new.turma_id),
                      new.turma_texto);

  perform gera_tarefas(new.id);

  if new.status not in ('CANCELADA', 'LISTA_ESPERA') then
    insert into convite_calendario (reserva_id, uid, sequence, metodo)
    values (new.id, new.id::text || '@agendamento.marista', 0, 'REQUEST')
    on conflict (reserva_id) do update
      set sequence = convite_calendario.sequence + 1,
          metodo = 'REQUEST',
          atualizado_em = now();
  else
    update convite_calendario
       set sequence = sequence + 1, metodo = 'CANCEL', atualizado_em = now()
     where reserva_id = new.id;
  end if;

  v_resumo := format('%s — %s, %s, %s (%s equipamentos)',
                     v_pool.nome, to_char(new.data, 'DD/MM'),
                     h.rotulo, coalesce(v_turma, '—'), new.quantidade);

  if tg_op = 'INSERT' and new.status = 'CONFIRMADA' then
    perform enfileira_notificacao(
      'confirmacao:' || new.id, new.professor_id,
      'Agendamento confirmado: ' || v_resumo,
      case when new.modo = 'RETIRADA_BALCAO' then
        'Sua reserva está confirmada. ATENÇÃO: neste horário não há estagiário de '
        || 'plantão — você deve retirar e devolver os equipamentos em: '
        || coalesce(v_unidade.ponto_apoio, 'Coordenação') || '.'
      else
        'Sua reserva está confirmada. A estagiária levará os equipamentos até a '
        || 'sala e os buscará ao fim do horário.'
      end,
      now(), null, new.id);

    for v_coord in
      select p.id from pessoa p
        join pessoa_papel pp on pp.pessoa_id = p.id
       where pp.papel = 'COORDENACAO'
         and pp.unidade_id = v_unidade.id
         and p.ativo
    loop
      perform enfileira_notificacao(
        'novo_agendamento:' || new.id || ':' || v_coord.id, v_coord.id,
        'Novo agendamento — ' || v_unidade.nome,
        v_prof.nome || ' agendou ' || v_resumo,
        now(), null, new.id);
    end loop;

    perform enfileira_notificacao(
      'vespera:' || new.id, new.professor_id,
      'Lembrete: amanhã você tem ' || v_resumo,
      'Amanhã às ' || to_char(h.inicio, 'HH24:MI') || ' você tem '
        || new.quantidade || ' equipamentos reservados para a turma '
        || coalesce(v_turma, '—') || '.',
      ((new.data - 1) + time '17:00') at time zone v_unidade.fuso,
      null, new.id);
  end if;

  if tg_op = 'UPDATE' and new.status = 'CANCELADA' and old.status <> 'CANCELADA' then
    update reserva set status = 'CONFIRMADA'
     where id = (
       select r.id from reserva r
        where r.pool_id = new.pool_id and r.data = new.data
          and r.horario_id = new.horario_id
          and r.status = 'LISTA_ESPERA'
          and r.quantidade <= saldo_disponivel(new.pool_id, new.data, new.horario_id)
        order by r.criado_em
        limit 1
     );
  end if;

  return new;
end;
$$;

create or replace function marca_atrasadas(p_tolerancia_min integer default 20)
returns integer
language plpgsql as $$
declare v_qtd integer := 0; r record;
begin
  for r in
    select res.id, res.professor_id, res.pool_id, res.quantidade,
           p.nome as prof, po.nome as pool, h.rotulo
      from reserva res
      join horario h on h.id = res.horario_id
      join pool po   on po.id = res.pool_id
      join unidade u on u.id = po.unidade_id
      join pessoa p  on p.id = res.professor_id
     where res.status = 'ENTREGUE'
       and ((res.data + h.fim) at time zone u.fuso)
             + make_interval(mins => p_tolerancia_min) < now()
  loop
    update reserva set status = 'ATRASADA' where id = r.id;

    insert into ocorrencia (reserva_id, pool_id, tipo, quantidade, descricao)
    values (r.id, r.pool_id, 'ATRASO', r.quantidade,
            format('Devolução em atraso: %s (%s, %s)', r.prof, r.pool, r.rotulo));

    perform enfileira_notificacao(
      'atraso:' || r.id, r.professor_id,
      'Devolução pendente — ' || r.pool,
      format('Os %s equipamentos do horário %s ainda não foram devolvidos.',
             r.quantidade, r.rotulo),
      now(), null, r.id);

    v_qtd := v_qtd + 1;
  end loop;
  return v_qtd;
end;
$$;

-- -----------------------------------------------------------------------------
-- Caixa de avisos do usuário. Só entrega o que já venceu — um lembrete de
-- véspera agendado para amanhã não aparece hoje.
-- -----------------------------------------------------------------------------
create or replace function meus_avisos(p_limite integer default 50)
returns table (
  id uuid, assunto text, corpo text, agendada_para timestamptz,
  lida_em timestamptz, reserva_id uuid
)
language sql stable security definer set search_path = public as $$
  select n.id, n.assunto, n.corpo, n.agendada_para, n.lida_em, n.reserva_id
    from notificacao n
   where n.destinatario_id = auth.uid()
     and n.agendada_para <= now()
   order by n.agendada_para desc
   limit p_limite;
$$;

create or replace function marca_aviso_lido(p_id uuid) returns void
language sql security definer set search_path = public as $$
  update notificacao set lida_em = now()
   where id = p_id and destinatario_id = auth.uid() and lida_em is null;
$$;

create or replace function marca_todos_avisos_lidos() returns integer
language plpgsql security definer set search_path = public as $$
declare v_qtd integer;
begin
  update notificacao set lida_em = now()
   where destinatario_id = auth.uid()
     and lida_em is null
     and agendada_para <= now();
  get diagnostics v_qtd = row_count;
  return v_qtd;
end $$;

-- O worker de e-mail só consome o canal EMAIL.
create or replace view notificacao_pendente as
select n.id, n.chave, n.assunto, n.corpo, n.canal,
       n.destinatario_email, n.destinatario_id, n.tentativas,
       r.id as reserva_id, r.data as reserva_data, r.quantidade, r.modo,
       h.rotulo as horario_rotulo, h.inicio as horario_inicio,
       h.fim as horario_fim,
       po.nome as pool_nome, u.nome as unidade_nome, u.fuso, u.ponto_apoio,
       coalesce(t.nome, r.turma_texto) as turma,
       l.nome as sala, prof.nome as professor_nome,
       cc.uid as ics_uid, cc.sequence as ics_sequence, cc.metodo as ics_metodo
  from notificacao n
  left join reserva r  on r.id  = n.reserva_id
  left join horario h  on h.id  = r.horario_id
  left join pool po    on po.id = r.pool_id
  left join unidade u  on u.id  = po.unidade_id
  left join turma t    on t.id  = r.turma_id
  left join local l    on l.id  = r.local_id
  left join pessoa prof on prof.id = r.professor_id
  left join convite_calendario cc on cc.reserva_id = r.id
 where n.enviada_em is null
   and n.canal = 'EMAIL'
   and n.agendada_para <= now()
   and n.tentativas < 5;

alter table config_sistema enable row level security;
create policy config_leitura on config_sistema
  for select to authenticated using (true);
create policy config_gestao on config_sistema
  for all to authenticated
  using (tem_papel('ADMIN')) with check (tem_papel('ADMIN'));
