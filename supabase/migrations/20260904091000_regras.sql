-- =============================================================================
-- Regras de negócio: saldo derivado, anti-overbooking, geração de tarefas,
-- calendário recorrente e enfileiramento de notificações.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Utilitário: a data é letiva para a unidade?
-- -----------------------------------------------------------------------------
create or replace function eh_dia_letivo(p_unidade uuid, p_data date)
returns boolean
language sql stable as $$
  select not exists (
    select 1 from excecao_calendario e
     where e.data = p_data
       and (e.unidade_id = p_unidade or e.unidade_id is null)
  );
$$;

-- -----------------------------------------------------------------------------
-- Saldo de um pool em (data, horário). Derivado — nunca armazenado.
-- Substitui o "35" digitado na célula da planilha.
-- -----------------------------------------------------------------------------
create or replace function saldo_disponivel(
  p_pool uuid, p_data date, p_horario uuid, p_ignorar_reserva uuid default null
) returns integer
language sql stable as $$
  select (select capacidade from pool_capacidade where pool_id = p_pool)
       - coalesce((
           select sum(r.quantidade)
             from reserva r
            where r.pool_id   = p_pool
              and r.data      = p_data
              and r.horario_id = p_horario
              and r.status not in ('CANCELADA', 'LISTA_ESPERA', 'NAO_COMPARECEU')
              and (p_ignorar_reserva is null or r.id <> p_ignorar_reserva)
         ), 0);
$$;

comment on function saldo_disponivel is
  'Fonte única do saldo. A tela e o trigger usam a MESMA função, então o que o '
  'professor vê é exatamente o que o banco vai aceitar.';

-- -----------------------------------------------------------------------------
-- Há estagiário de plantão neste momento?
-- -----------------------------------------------------------------------------
create or replace function tem_apoio(p_unidade uuid, p_data date, p_horario uuid)
returns boolean
language sql stable as $$
  select exists (
    select 1
      from janela_apoio j
      join horario h on h.id = p_horario
     where j.unidade_id = p_unidade
       and j.dia_semana = extract(isodow from p_data)::smallint
       and h.inicio >= j.inicio
       and h.fim    <= j.fim
  );
$$;

-- -----------------------------------------------------------------------------
-- Modo efetivo da reserva: fora da janela de apoio, cai para retirada no balcão.
-- -----------------------------------------------------------------------------
create or replace function modo_efetivo(p_unidade uuid, p_data date, p_horario uuid)
returns modo_atendimento
language sql stable as $$
  select case
    when (select modo_padrao from unidade where id = p_unidade) = 'RETIRADA_BALCAO'
      then 'RETIRADA_BALCAO'::modo_atendimento
    when tem_apoio(p_unidade, p_data, p_horario)
      then 'ENTREGA_EM_SALA'::modo_atendimento
    else 'RETIRADA_BALCAO'::modo_atendimento
  end;
$$;

-- -----------------------------------------------------------------------------
-- Validação da reserva. Roda ANTES de gravar: overbooking é impossível.
-- -----------------------------------------------------------------------------
create or replace function valida_reserva()
returns trigger
language plpgsql as $$
declare
  v_unidade   uuid;
  v_saldo     integer;
  v_horario   horario%rowtype;
  v_pool      pool%rowtype;
  v_ant_min   smallint;
  v_ant_max   smallint;
begin
  select * into v_pool from pool where id = new.pool_id;
  if not found or not v_pool.ativo then
    raise exception 'Pool inexistente ou inativo.';
  end if;
  v_unidade := v_pool.unidade_id;

  select * into v_horario from horario where id = new.horario_id;
  if not found or not v_horario.ativo then
    raise exception 'Horário inexistente ou inativo.';
  end if;

  if v_horario.unidade_id <> v_unidade then
    raise exception 'O horário pertence a outra unidade.';
  end if;

  if v_horario.eh_intervalo then
    raise exception 'Não é possível agendar durante o intervalo.';
  end if;

  -- O horário funciona neste dia da semana?
  if not (extract(isodow from new.data)::smallint = any (v_horario.dias_semana)) then
    raise exception 'O horário "%" não funciona neste dia da semana.', v_horario.rotulo;
  end if;

  if not eh_dia_letivo(v_unidade, new.data) then
    raise exception 'Data não letiva (feriado, recesso ou unidade fechada).';
  end if;

  -- Antecedência mínima/máxima (regra da unidade). Só na criação: remarcar uma
  -- reserva antiga ou o estagiário corrigir status não pode esbarrar nisso.
  if tg_op = 'INSERT' then
    select antecedencia_min_horas, antecedencia_max_dias
      into v_ant_min, v_ant_max from unidade where id = v_unidade;

    if v_ant_min > 0
       and (new.data + v_horario.inicio) at time zone
             (select fuso from unidade where id = v_unidade)
           < now() + make_interval(hours => v_ant_min) then
      raise exception
        'Esta unidade exige agendamento com no mínimo % horas de antecedência.',
        v_ant_min;
    end if;

    if new.data > (current_date + v_ant_max) then
      raise exception 'Só é possível agendar até % dias à frente.', v_ant_max;
    end if;
  end if;

  -- Limites por reserva
  if new.quantidade < v_pool.min_por_reserva then
    raise exception 'Mínimo de % equipamentos por reserva.', v_pool.min_por_reserva;
  end if;
  if v_pool.max_por_reserva is not null and new.quantidade > v_pool.max_por_reserva then
    raise exception 'Máximo de % equipamentos por reserva.', v_pool.max_por_reserva;
  end if;

  -- Anti-overbooking. Só vale para status que consomem frota.
  if new.status not in ('CANCELADA', 'LISTA_ESPERA', 'NAO_COMPARECEU') then
    v_saldo := saldo_disponivel(new.pool_id, new.data, new.horario_id,
                                case when tg_op = 'UPDATE' then new.id else null end);
    if new.quantidade > v_saldo then
      raise exception
        'Saldo insuficiente: restam % de % equipamentos neste horário.',
        v_saldo, v_pool.quantidade_total
        using errcode = 'check_violation';
    end if;
  end if;

  -- Modo é sempre derivado da regra da unidade + cobertura do estagiário.
  new.modo := modo_efetivo(v_unidade, new.data, new.horario_id);

  -- Sala de destino: usa a sala habitual da turma se não veio preenchida.
  if new.local_id is null and new.turma_id is not null then
    select local_padrao_id into new.local_id from turma where id = new.turma_id;
  end if;

  new.atualizado_em := now();
  return new;
end;
$$;

create trigger trg_valida_reserva
  before insert or update on reserva
  for each row execute function valida_reserva();

-- -----------------------------------------------------------------------------
-- Geração das tarefas logísticas.
-- Regra da transferência direta: se a mesma frota sai da sala A no horário N e
-- entra na sala B no horário N+1, não volta ao depósito — vira uma tarefa só.
-- -----------------------------------------------------------------------------
create or replace function gera_tarefas(p_reserva uuid)
returns void
language plpgsql as $$
declare
  r           reserva%rowtype;
  h           horario%rowtype;
  v_unidade   uuid;
  v_guarda    uuid;
  v_ant       reserva%rowtype;   -- reserva imediatamente anterior
  v_seg       reserva%rowtype;   -- reserva imediatamente seguinte
  v_h_ant     horario%rowtype;
begin
  select * into r from reserva where id = p_reserva;
  if not found then return; end if;

  select * into h from horario where id = r.horario_id;
  select unidade_id, local_guarda_id into v_unidade, v_guarda
    from pool where id = r.pool_id;

  -- Reescreve as tarefas ainda não executadas ligadas a esta reserva.
  delete from tarefa
   where (reserva_origem_id = p_reserva or reserva_destino_id = p_reserva)
     and status = 'PENDENTE';

  if r.status in ('CANCELADA', 'LISTA_ESPERA', 'NAO_COMPARECEU', 'DEVOLVIDA') then
    return;
  end if;

  -- Sem estagiário de plantão: o professor retira e devolve no balcão.
  -- Nenhuma rota a percorrer, apenas a conferência da devolução.
  if r.modo = 'RETIRADA_BALCAO' then
    insert into tarefa (tipo, unidade_id, data, hora_prevista, quantidade,
                        reserva_origem_id, local_origem_id, local_destino_id, observacao)
    values ('COLETA', v_unidade, r.data, h.fim, r.quantidade,
            r.id, r.local_id, v_guarda,
            'Conferir devolução no balcão (retirada pelo professor).');
    return;
  end if;

  -- --------------------------------------------------------------------------
  -- Encadeamento. A mesma frota, na mesma quantidade, saindo de um horário e
  -- entrando no seguinte não volta ao depósito: vira uma TRANSFERENCIA.
  -- Olhamos nas DUAS direções, porque a reserva vizinha pode ter sido criada
  -- antes ou depois desta.
  -- --------------------------------------------------------------------------
  select res.* into v_ant
    from reserva res
    join horario ha on ha.id = res.horario_id
   where res.pool_id = r.pool_id
     and res.data    = r.data
     and res.id     <> r.id
     and res.modo    = 'ENTREGA_EM_SALA'
     and res.quantidade = r.quantidade
     and res.status not in ('CANCELADA','LISTA_ESPERA','NAO_COMPARECEU','DEVOLVIDA')
     and ha.fim <= h.inicio
     and ha.fim >  h.inicio - interval '30 minutes'
   order by ha.fim desc
   limit 1;

  select res.* into v_seg
    from reserva res
    join horario hs on hs.id = res.horario_id
   where res.pool_id = r.pool_id
     and res.data    = r.data
     and res.id     <> r.id
     and res.modo    = 'ENTREGA_EM_SALA'
     and res.quantidade = r.quantidade
     and res.status not in ('CANCELADA','LISTA_ESPERA','NAO_COMPARECEU','DEVOLVIDA')
     and hs.inicio >= h.fim
     and hs.inicio <  h.fim + interval '30 minutes'
   order by hs.inicio
   limit 1;

  -- Entrada da frota nesta reserva
  if v_ant.id is not null then
    select * into v_h_ant from horario where id = v_ant.horario_id;

    -- A anterior não precisa mais devolver ao depósito.
    delete from tarefa
     where reserva_origem_id = v_ant.id and tipo = 'COLETA' and status = 'PENDENTE';

    insert into tarefa (tipo, unidade_id, data, hora_prevista, quantidade,
                        reserva_origem_id, reserva_destino_id,
                        local_origem_id, local_destino_id, observacao)
    values ('TRANSFERENCIA', v_unidade, r.data, v_h_ant.fim, r.quantidade,
            v_ant.id, r.id, v_ant.local_id, r.local_id,
            'Levar direto para a próxima turma — não retornar ao depósito.');
  else
    insert into tarefa (tipo, unidade_id, data, hora_prevista, quantidade,
                        reserva_destino_id, local_origem_id, local_destino_id)
    values ('ENTREGA', v_unidade, r.data, h.inicio - interval '10 minutes',
            r.quantidade, r.id, v_guarda, r.local_id);
  end if;

  -- Saída da frota desta reserva
  if v_seg.id is not null then
    -- A seguinte não precisa mais de uma entrega vinda do depósito.
    delete from tarefa
     where reserva_destino_id = v_seg.id and tipo = 'ENTREGA' and status = 'PENDENTE';

    insert into tarefa (tipo, unidade_id, data, hora_prevista, quantidade,
                        reserva_origem_id, reserva_destino_id,
                        local_origem_id, local_destino_id, observacao)
    values ('TRANSFERENCIA', v_unidade, r.data, h.fim, r.quantidade,
            r.id, v_seg.id, r.local_id, v_seg.local_id,
            'Levar direto para a próxima turma — não retornar ao depósito.')
    on conflict do nothing;
  else
    insert into tarefa (tipo, unidade_id, data, hora_prevista, quantidade,
                        reserva_origem_id, local_origem_id, local_destino_id)
    values ('COLETA', v_unidade, r.data, h.fim, r.quantidade,
            r.id, r.local_id, v_guarda);
  end if;
end;
$$;

comment on function gera_tarefas is
  'Reconstrói a fila do estagiário para uma reserva. Idempotente: só mexe em '
  'tarefas PENDENTES, então reprocessar não desfaz trabalho já executado.';

-- -----------------------------------------------------------------------------
-- Notificações: enfileira com chave de dedupe.
-- -----------------------------------------------------------------------------
create or replace function enfileira_notificacao(
  p_chave text, p_pessoa uuid, p_assunto text, p_corpo text,
  p_quando timestamptz default now(), p_canal text default 'EMAIL',
  p_reserva uuid default null
) returns void
language plpgsql as $$
declare v_email text;
begin
  select email into v_email from pessoa where id = p_pessoa;
  if v_email is null then return; end if;

  insert into notificacao (chave, destinatario_id, destinatario_email,
                           canal, assunto, corpo, agendada_para, reserva_id)
  values (p_chave, p_pessoa, v_email, p_canal, p_assunto, p_corpo, p_quando,
          p_reserva)
  on conflict (chave) do nothing;   -- nunca envia duas vezes
end;
$$;

-- -----------------------------------------------------------------------------
-- Depois de gravar a reserva: gera tarefas, convite .ics e notificações.
-- -----------------------------------------------------------------------------
create or replace function pos_reserva()
returns trigger
language plpgsql as $$
declare
  h          horario%rowtype;
  v_unidade  unidade%rowtype;
  v_prof     pessoa%rowtype;
  v_pool     pool%rowtype;
  v_turma    text;
  v_inicio   timestamptz;
  v_coord    record;
  v_resumo   text;
begin
  select * into h from horario where id = new.horario_id;
  select * into v_pool from pool where id = new.pool_id;
  select * into v_unidade from unidade where id = v_pool.unidade_id;
  select * into v_prof from pessoa where id = new.professor_id;

  v_turma := coalesce((select nome from turma where id = new.turma_id), new.turma_texto);
  v_inicio := (new.data + h.inicio) at time zone v_unidade.fuso;

  perform gera_tarefas(new.id);

  -- Convite de calendário: cria na primeira vez, incrementa SEQUENCE depois,
  -- para que o Outlook ATUALIZE o evento em vez de duplicar.
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
    -- 1. Confirmação para o professor
    perform enfileira_notificacao(
      'confirmacao:' || new.id, new.professor_id,
      'Agendamento confirmado: ' || v_resumo,
      case when new.modo = 'RETIRADA_BALCAO' then
        'Sua reserva está confirmada. ATENÇÃO: neste horário não há estagiário de '
        || 'plantão — você deve retirar e devolver os equipamentos em: '
        || coalesce(v_unidade.ponto_apoio, 'Coordenação') || '.'
      else
        'Sua reserva está confirmada. A estagiária levará os equipamentos até a sala '
        || 'e os buscará ao fim do horário.'
      end,
      now(), 'EMAIL', new.id);

    -- 2. Coordenação é avisada de todo agendamento novo
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
        now(), 'EMAIL', new.id);
    end loop;

    -- 3. Lembrete na véspera, 17h
    perform enfileira_notificacao(
      'vespera:' || new.id, new.professor_id,
      'Lembrete: amanhã você tem ' || v_resumo,
      'Amanhã às ' || to_char(h.inicio, 'HH24:MI') || ' você tem '
        || new.quantidade || ' equipamentos reservados para a turma '
        || coalesce(v_turma, '—') || '.',
      ((new.data - 1) + time '17:00') at time zone v_unidade.fuso,
      'EMAIL', new.id);
  end if;

  -- Cancelamento: avisa e promove o primeiro da lista de espera.
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

create trigger trg_pos_reserva
  after insert or update on reserva
  for each row execute function pos_reserva();

-- -----------------------------------------------------------------------------
-- Marca reservas em atraso e abre ocorrência. Chamado pelo cron.
-- Substitui "alguém precisa lembrar de cobrar a devolução".
-- -----------------------------------------------------------------------------
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
      now(), 'EMAIL', r.id);

    v_qtd := v_qtd + 1;
  end loop;
  return v_qtd;
end;
$$;

-- -----------------------------------------------------------------------------
-- Conferência da devolução: quantidade a menos abre ocorrência na hora.
-- -----------------------------------------------------------------------------
create or replace function confere_devolucao(
  p_tarefa uuid, p_qtd_conferida smallint, p_por uuid, p_obs text default null
) returns void
language plpgsql as $$
declare t tarefa%rowtype; r reserva%rowtype; v_coord record;
begin
  select * into t from tarefa where id = p_tarefa;
  if not found then raise exception 'Tarefa não encontrada.'; end if;

  update tarefa
     set status = 'CONCLUIDA', concluida_em = now(),
         qtd_conferida = p_qtd_conferida, responsavel_id = p_por,
         observacao = coalesce(p_obs, observacao)
   where id = p_tarefa;

  if t.reserva_origem_id is null then return; end if;
  select * into r from reserva where id = t.reserva_origem_id;

  update reserva
     set status = 'DEVOLVIDA', devolvido_em = now(),
         devolvido_por = p_por, qtd_devolvida = p_qtd_conferida
   where id = r.id;

  if p_qtd_conferida < r.quantidade then
    insert into ocorrencia (reserva_id, tarefa_id, pool_id, tipo, quantidade,
                            descricao, registrada_por)
    values (r.id, p_tarefa, r.pool_id, 'FALTA', r.quantidade - p_qtd_conferida,
            format('Faltaram %s equipamentos na devolução.',
                   r.quantidade - p_qtd_conferida), p_por);

    for v_coord in
      select p.id from pessoa p
        join pessoa_papel pp on pp.pessoa_id = p.id
        join pool po on po.unidade_id = pp.unidade_id
       where pp.papel = 'COORDENACAO' and po.id = r.pool_id and p.ativo
    loop
      perform enfileira_notificacao(
        'falta:' || p_tarefa || ':' || v_coord.id, v_coord.id,
        'Falta de equipamento na devolução',
        format('Reserva de %s: entregues %s, devolvidos %s.',
               (select nome from pessoa where id = r.professor_id),
               r.quantidade, p_qtd_conferida));
    end loop;
  end if;
end;
$$;

-- -----------------------------------------------------------------------------
-- Agenda de uma data: gerada da grade recorrente + saldo em tempo real.
-- É o que a tela consome. Nenhuma "aba de mês" precisa existir.
-- -----------------------------------------------------------------------------
create or replace function agenda_do_dia(p_pool uuid, p_data date)
returns table (
  horario_id uuid, rotulo text, turno turno, inicio time, fim time,
  eh_intervalo boolean, capacidade integer, reservado integer,
  disponivel integer, tem_estagiario boolean
)
language sql stable as $$
  select h.id, h.rotulo, h.turno, h.inicio, h.fim, h.eh_intervalo,
         pc.capacidade::integer,
         (pc.capacidade - saldo_disponivel(p_pool, p_data, h.id))::integer,
         saldo_disponivel(p_pool, p_data, h.id),
         tem_apoio(po.unidade_id, p_data, h.id)
    from horario h
    join pool po on po.id = p_pool
    join pool_capacidade pc on pc.pool_id = p_pool
   where h.unidade_id = po.unidade_id
     and h.ativo
     and extract(isodow from p_data)::smallint = any (h.dias_semana)
     and eh_dia_letivo(po.unidade_id, p_data)
   order by h.turno, h.ordem;
$$;
