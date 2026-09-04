-- =============================================================================
-- Suporte ao worker de notificações: view com tudo que o e-mail precisa,
-- montagem da fila do dia e agendamento dos jobs.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Tudo o que o worker precisa para montar o e-mail e o convite .ics,
-- em uma consulta só.
-- -----------------------------------------------------------------------------
create or replace view notificacao_pendente as
select n.id, n.chave, n.assunto, n.corpo, n.canal,
       n.destinatario_email, n.destinatario_id, n.tentativas,
       r.id            as reserva_id,
       r.data          as reserva_data,
       r.quantidade,
       r.modo,
       h.rotulo        as horario_rotulo,
       h.inicio        as horario_inicio,
       h.fim           as horario_fim,
       po.nome         as pool_nome,
       u.nome          as unidade_nome,
       u.fuso,
       u.ponto_apoio,
       coalesce(t.nome, r.turma_texto) as turma,
       l.nome          as sala,
       prof.nome       as professor_nome,
       cc.uid          as ics_uid,
       cc.sequence     as ics_sequence,
       cc.metodo       as ics_metodo
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
   and n.agendada_para <= now()
   and n.tentativas < 5;

-- -----------------------------------------------------------------------------
-- Fila operacional do dia — o que o estagiário vê ao chegar.
-- -----------------------------------------------------------------------------
create or replace function fila_do_dia(p_unidade uuid, p_data date default current_date)
returns table (
  tarefa_id uuid, tipo tipo_tarefa, hora time, quantidade smallint,
  origem text, destino text, professor text, turma text,
  status status_tarefa, observacao text
)
language sql stable as $$
  select t.id, t.tipo, t.hora_prevista, t.quantidade,
         coalesce(lo.nome, 'Depósito'),
         coalesce(ld.nome, 'Depósito'),
         coalesce(pd.nome, po_.nome),
         coalesce(td.nome, rd.turma_texto, to_.nome, ro.turma_texto),
         t.status, t.observacao
    from tarefa t
    left join local lo on lo.id = t.local_origem_id
    left join local ld on ld.id = t.local_destino_id
    left join reserva ro on ro.id = t.reserva_origem_id
    left join reserva rd on rd.id = t.reserva_destino_id
    left join pessoa po_ on po_.id = ro.professor_id
    left join pessoa pd  on pd.id  = rd.professor_id
    left join turma to_  on to_.id = ro.turma_id
    left join turma td   on td.id  = rd.turma_id
   where t.unidade_id = p_unidade
     and t.data = p_data
   order by t.hora_prevista, t.tipo;
$$;

-- -----------------------------------------------------------------------------
-- Enfileira o resumo diário para estagiários e coordenação.
-- Roda de madrugada; o horário vem de config_notificacao.
-- -----------------------------------------------------------------------------
create or replace function enfileira_fila_do_dia(p_data date default current_date)
returns integer
language plpgsql security definer set search_path = public as $$
declare
  v_qtd integer := 0;
  u     record;
  d     record;
  v_corpo text;
  v_linhas integer;
begin
  for u in select * from unidade where ativo loop
    select count(*) into v_linhas from tarefa
     where unidade_id = u.id and data = p_data and status = 'PENDENTE';
    continue when v_linhas = 0;

    select string_agg(
             format('%s  %s  %s → %s  (%s un.)  %s',
                    to_char(hora, 'HH24:MI'), tipo, origem, destino,
                    quantidade, coalesce(professor, '')),
             E'\n' order by hora)
      into v_corpo
      from fila_do_dia(u.id, p_data)
     where status = 'PENDENTE';

    for d in
      select p.id from pessoa p
        join pessoa_papel pp on pp.pessoa_id = p.id
       where pp.unidade_id = u.id
         and pp.papel in ('ESTAGIARIO', 'COORDENACAO')
         and p.ativo
    loop
      perform enfileira_notificacao(
        format('fila_do_dia:%s:%s:%s', u.id, p_data, d.id), d.id,
        format('Fila do dia — %s (%s)', u.nome, to_char(p_data, 'DD/MM')),
        v_corpo);
      v_qtd := v_qtd + 1;
    end loop;
  end loop;
  return v_qtd;
end $$;

-- -----------------------------------------------------------------------------
-- Agendamento dos jobs.
-- Requer pg_cron. Em projetos Supabase: habilitar a extensão em Database →
-- Extensions antes de aplicar esta migration.
-- -----------------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_extension where extname = 'pg_cron') then
    raise notice
      'pg_cron não está habilitado — os jobs não foram agendados. '
      'Habilite a extensão e rode supabase/jobs.sql.';
    return;
  end if;

  -- Horários em UTC. America/Sao_Paulo = UTC-3 (sem horário de verão desde 2019).
  perform cron.schedule('fila-do-dia',   '30 9 * * 1-6',
                        $j$select enfileira_fila_do_dia();$j$);
  perform cron.schedule('marca-atrasadas','*/10 10-23 * * 1-6',
                        $j$select marca_atrasadas();$j$);
end $$;
