-- Testes das regras de negócio. Rodar contra um banco com schema+regras+seed.
\set ON_ERROR_STOP on
\set QUIET on

create or replace function ok(cond boolean, msg text) returns void
language plpgsql as $$
begin
  if cond then raise notice 'PASS  %', msg;
  else raise exception 'FALHOU: %', msg; end if;
end $$;

-- Espera que o bloco levante exceção contendo o trecho.
create or replace function falha_com(sql text, trecho text, msg text) returns void
language plpgsql as $$
begin
  begin
    execute sql;
  exception when others then
    if position(lower(trecho) in lower(sqlerrm)) > 0 then
      raise notice 'PASS  %', msg; return;
    else
      raise exception 'FALHOU: % — erro inesperado: %', msg, sqlerrm;
    end if;
  end;
  raise exception 'FALHOU: % — deveria ter sido recusado', msg;
end $$;

do $$
declare
  v_prof uuid := gen_random_uuid();
  v_prof2 uuid := gen_random_uuid();
  v_coord uuid := gen_random_uuid();
  v_pio uuid; v_mta uuid; v_mto uuid;
  v_pool_pio uuid; v_pool_mta uuid; v_pool_mto uuid;
  v_h1 uuid; v_h2 uuid; v_h_int uuid; v_h_mta1 uuid; v_h_mta2 uuid; v_h_mto1 uuid;
  v_seg uuid; v_sala_a uuid; v_sala_b uuid; v_turma_a uuid; v_turma_b uuid;
  v_r1 uuid; v_r2 uuid; v_r3 uuid;
  v_data date;
  v_tarefa uuid;
  n integer;
begin
  -- Uma segunda-feira bem à frente, para não esbarrar na antecedência.
  v_data := date_trunc('week', current_date + 30)::date;

  select id into v_pio from unidade where nome = 'Pio XII';
  select id into v_mta from unidade where nome = 'Maristinha';
  select id into v_mto from unidade where nome = 'Maristão';
  select id into v_pool_pio from pool where nome = 'iPads Pio XII';
  select id into v_pool_mta from pool where nome = 'iPads Anos Finais';
  select id into v_pool_mto from pool where nome = 'iPads Maristão';

  -- O domínio precisa estar autorizado, senão o provisionamento recusa o acesso.
  insert into dominio_permitido (dominio, papel_padrao, unidade_id)
  values ('marista.edu.br', 'PROFESSOR', v_pio) on conflict do nothing;

  insert into auth.users (id, email) values
    (v_prof,  'prof1@marista.edu.br'),
    (v_prof2, 'prof2@marista.edu.br'),
    (v_coord, 'coord@marista.edu.br');
  -- O trigger de provisionamento já criou os perfis; aqui só ajustamos nome/unidade.
  update pessoa set nome = 'Vinicius',    unidade_id = v_pio where id = v_prof;
  update pessoa set nome = 'Telma',       unidade_id = v_mta where id = v_prof2;
  update pessoa set nome = 'Coordenação', unidade_id = v_pio where id = v_coord;
  insert into pessoa_papel values (v_coord, 'COORDENACAO', v_pio);

  select id into v_h1 from horario
   where unidade_id = v_pio and turno='MATUTINO' and ordem = 1;
  select id into v_h2 from horario
   where unidade_id = v_pio and turno='MATUTINO' and ordem = 2;
  select id into v_h_int from horario
   where unidade_id = v_pio and eh_intervalo limit 1;

  -- ===========================================================
  raise notice '--- saldo e overbooking ---';
  perform ok(saldo_disponivel(v_pool_pio, v_data, v_h1) = 35,
             'saldo inicial = capacidade total (35)');

  insert into reserva (pool_id, horario_id, data, professor_id, turma_texto, quantidade)
  values (v_pool_pio, v_h1, v_data, v_prof, '2ºD', 20) returning id into v_r1;

  perform ok(saldo_disponivel(v_pool_pio, v_data, v_h1) = 15,
             'saldo cai para 15 após reservar 20');

  perform falha_com(format(
    'insert into reserva (pool_id,horario_id,data,professor_id,turma_texto,quantidade)
     values (%L,%L,%L,%L,''3ºA'',20)', v_pool_pio, v_h1, v_data, v_prof2),
    'saldo insuficiente', 'overbooking é recusado pelo banco');

  -- Cabe exatamente o que resta
  insert into reserva (pool_id, horario_id, data, professor_id, turma_texto, quantidade)
  values (v_pool_pio, v_h1, v_data, v_prof2, '3ºA', 15);
  perform ok(saldo_disponivel(v_pool_pio, v_data, v_h1) = 0, 'saldo zera exatamente');

  -- ===========================================================
  raise notice '--- validações de agenda ---';
  perform falha_com(format(
    'insert into reserva (pool_id,horario_id,data,professor_id,turma_texto,quantidade)
     values (%L,%L,%L,%L,''1ºA'',5)', v_pool_pio, v_h_int, v_data, v_prof),
    'intervalo', 'não deixa agendar no intervalo');

  insert into excecao_calendario (unidade_id, data, tipo, descricao)
  values (v_pio, v_data + 1, 'FERIADO', 'Feriado de teste');
  perform falha_com(format(
    'insert into reserva (pool_id,horario_id,data,professor_id,turma_texto,quantidade)
     values (%L,%L,%L,%L,''1ºA'',5)', v_pool_pio, v_h1, v_data + 1, v_prof),
    'não letiva', 'bloqueia agendamento em feriado');

  -- Domingo: nenhum horário do Pio XII funciona (dias 1..6)
  perform falha_com(format(
    'insert into reserva (pool_id,horario_id,data,professor_id,turma_texto,quantidade)
     values (%L,%L,%L,%L,''1ºA'',5)', v_pool_pio, v_h1, v_data + 6, v_prof),
    'dia da semana', 'bloqueia dia em que o horário não funciona');

  -- Duplicata: precisa de um horário COM vaga, senão o erro de saldo vem antes.
  insert into reserva (pool_id, horario_id, data, professor_id, turma_texto, quantidade)
  values (v_pool_pio, v_h2, v_data, v_prof, '2ºD', 5);
  perform falha_com(format(
    'insert into reserva (pool_id,horario_id,data,professor_id,turma_texto,quantidade)
     values (%L,%L,%L,%L,''2ºE'',5)', v_pool_pio, v_h2, v_data, v_prof),
    'duplicat', 'mesmo professor não reserva a mesma frota/horário duas vezes');

  -- ===========================================================
  raise notice '--- antecedência mínima (Maristão, 24h) ---';
  select id into v_h_mto1 from horario
   where unidade_id = v_mto and turno='MATUTINO' and ordem = 1;
  perform falha_com(format(
    'insert into reserva (pool_id,horario_id,data,professor_id,turma_texto,quantidade)
     values (%L,%L,%L,%L,''3ºB'',5)', v_pool_mto, v_h_mto1, current_date, v_prof),
    'antecedência', 'Maristão recusa agendamento para hoje (regra de 24h)');

  -- ===========================================================
  raise notice '--- modo de atendimento e cobertura do estagiário ---';
  perform ok((select modo from reserva where id = v_r1) = 'RETIRADA_BALCAO',
             'Pio XII sempre é retirada no balcão');

  select id into v_seg from segmento where unidade_id = v_mta and nome = 'Anos Finais';
  insert into local (unidade_id, nome) values (v_mta, 'Sala 12') returning id into v_sala_a;
  insert into local (unidade_id, nome) values (v_mta, 'Sala 07') returning id into v_sala_b;
  insert into turma (segmento_id, nome, local_padrao_id)
    values (v_seg, '6ºA', v_sala_a) returning id into v_turma_a;
  insert into turma (segmento_id, nome, local_padrao_id)
    values (v_seg, '7ºB', v_sala_b) returning id into v_turma_b;

  select id into v_h_mta1 from horario
   where unidade_id = v_mta and turno='MATUTINO' and ordem = 1;   -- 07:30-08:15
  select id into v_h_mta2 from horario
   where unidade_id = v_mta and turno='MATUTINO' and ordem = 2;   -- 08:15-09:00

  insert into reserva (pool_id, horario_id, data, professor_id, turma_id, quantidade)
  values (v_pool_mta, v_h_mta1, v_data, v_prof2, v_turma_a, 20) returning id into v_r2;

  perform ok((select modo from reserva where id = v_r2) = 'ENTREGA_EM_SALA',
             'segunda de manhã tem estagiário → entrega em sala');
  perform ok((select local_id from reserva where id = v_r2) = v_sala_a,
             'sala da turma preenchida automaticamente');

  -- Vespertino não tem cobertura → cai para balcão
  insert into reserva (pool_id, horario_id, data, professor_id, turma_id, quantidade)
  select v_pool_mta, id, v_data, v_prof2, v_turma_a, 5
    from horario where unidade_id = v_mta and turno = 'VESPERTINO' and ordem = 1;
  perform ok((select modo from reserva r join horario h on h.id = r.horario_id
               where r.professor_id = v_prof2 and h.turno = 'VESPERTINO')
             = 'RETIRADA_BALCAO',
             'à tarde não há estagiário → rebaixa para retirada no balcão');

  -- ===========================================================
  raise notice '--- geração de tarefas ---';
  select count(*) into n from tarefa where reserva_origem_id = v_r1;
  perform ok(n = 1, 'retirada no balcão gera só a conferência de devolução');

  select count(*) into n from tarefa where reserva_destino_id = v_r2 and tipo = 'ENTREGA';
  perform ok(n = 1, 'entrega em sala gera tarefa de ENTREGA');

  perform ok((select hora_prevista from tarefa
               where reserva_destino_id = v_r2 and tipo='ENTREGA') = '07:20',
             'entrega agendada 10 min antes do início');

  perform ok(exists (
      select 1 from fila_do_dia(v_mta, v_data)
       where tipo = 'ENTREGA' and origem = 'Coordenação' and destino = 'Sala 12'),
    'entrega sai do local de guarda da frota para a sala da turma');

  -- ===========================================================
  raise notice '--- transferência direta entre salas ---';
  insert into reserva (pool_id, horario_id, data, professor_id, turma_id, quantidade)
  values (v_pool_mta, v_h_mta2, v_data, v_prof, v_turma_b, 20) returning id into v_r3;

  select count(*) into n from tarefa
   where reserva_origem_id = v_r2 and reserva_destino_id = v_r3
     and tipo = 'TRANSFERENCIA';
  perform ok(n = 1, 'horários consecutivos, mesma frota → vira TRANSFERENCIA');

  select count(*) into n from tarefa
   where reserva_origem_id = v_r2 and tipo = 'COLETA' and status = 'PENDENTE';
  perform ok(n = 0, 'a COLETA da primeira foi absorvida pela transferência');

  select count(*) into n from tarefa
   where reserva_destino_id = v_r3 and tipo = 'ENTREGA' and status = 'PENDENTE';
  perform ok(n = 0, 'a ENTREGA da segunda foi absorvida pela transferência');

  select count(*) into n from tarefa where reserva_origem_id = v_r3 and tipo='COLETA';
  perform ok(n = 1, 'a última do encadeamento volta para o depósito');

  -- ===========================================================
  raise notice '--- notificações ---';
  select count(*) into n from notificacao where chave = 'confirmacao:' || v_r1;
  perform ok(n = 1, 'professor recebe confirmação');

  select count(*) into n from notificacao
   where chave = 'novo_agendamento:' || v_r1 || ':' || v_coord;
  perform ok(n = 1, 'coordenação é notificada de novo agendamento');

  select count(*) into n from notificacao where chave = 'vespera:' || v_r1;
  perform ok(n = 1, 'lembrete de véspera é enfileirado');

  perform ok((select agendada_para from notificacao where chave='vespera:'||v_r1)
             = ((v_data - 1) + time '17:00') at time zone 'America/Sao_Paulo',
             'lembrete marcado para as 17h do dia anterior');

  -- Dedupe: reenfileirar não duplica
  perform enfileira_notificacao('confirmacao:' || v_r1, v_prof, 'x', 'y');
  select count(*) into n from notificacao where chave = 'confirmacao:' || v_r1;
  perform ok(n = 1, 'chave de dedupe impede envio duplicado');

  -- ===========================================================
  raise notice '--- convite de calendário (.ics) ---';
  perform ok((select sequence from convite_calendario where reserva_id = v_r1) = 0,
             'convite criado com SEQUENCE 0');
  update reserva set quantidade = 18 where id = v_r1;
  perform ok((select sequence from convite_calendario where reserva_id = v_r1) = 1,
             'alterar a reserva incrementa SEQUENCE (Outlook atualiza, não duplica)');

  -- ===========================================================
  raise notice '--- devolução com falta ---';
  update reserva set status = 'ENTREGUE', entregue_em = now() where id = v_r2;
  select id into v_tarefa from tarefa
   where reserva_origem_id = v_r2 and tipo = 'TRANSFERENCIA';
  perform confere_devolucao(v_tarefa, 18::smallint, v_coord, 'faltaram 2');

  perform ok((select status from reserva where id = v_r2) = 'DEVOLVIDA',
             'reserva marcada como devolvida');
  select count(*) into n from ocorrencia
   where reserva_id = v_r2 and tipo = 'FALTA' and quantidade = 2;
  perform ok(n = 1, 'devolução a menor abre ocorrência de FALTA');

  -- ===========================================================
  raise notice '--- cancelamento promove a lista de espera ---';
  insert into reserva (pool_id, horario_id, data, professor_id, turma_texto,
                       quantidade, status)
  values (v_pool_pio, v_h1, v_data, v_coord, '4ºC', 10, 'LISTA_ESPERA');
  update reserva set status = 'CANCELADA' where id = v_r1;   -- libera 18
  perform ok((select status from reserva
               where professor_id = v_coord and turma_texto = '4ºC') = 'CONFIRMADA',
             'cancelamento promove o primeiro da lista de espera');

  -- ===========================================================
  raise notice '--- agenda do dia (substitui a aba do mês) ---';
  select count(*) into n from agenda_do_dia(v_pool_pio, v_data);
  perform ok(n = 12, 'agenda do dia gerada da grade recorrente (12 horários)');
  perform ok((select disponivel from agenda_do_dia(v_pool_pio, v_data)
               where rotulo = '7h30-8h30') = 10,
             'saldo do horário reflete as reservas vivas');

  -- ===========================================================
  raise notice '--- fila do dia do estagiário ---';
  select count(*) into n from fila_do_dia(v_mta, v_data);
  perform ok(n > 0, 'fila do dia lista as tarefas da unidade');

  perform ok(exists (
      select 1 from fila_do_dia(v_mta, v_data)
       where tipo = 'TRANSFERENCIA' and origem = 'Sala 12' and destino = 'Sala 07'),
    'transferência aparece na fila com origem e destino legíveis');

  -- Resumo diário: precisa de alguém com papel na unidade para receber.
  insert into pessoa_papel values (v_coord, 'ESTAGIARIO', v_mta)
    on conflict do nothing;
  perform enfileira_fila_do_dia(v_data);
  select count(*) into n from notificacao
   where chave like 'fila_do_dia:' || v_mta || ':' || v_data || '%';
  perform ok(n = 1, 'resumo da fila é enfileirado para o estagiário');

  -- O resumo lista só trabalho PENDENTE. A transferência daquele dia já foi
  -- concluída no teste, então não deve aparecer — é o ponto da verificação.
  perform ok((select corpo from notificacao
               where chave like 'fila_do_dia:' || v_mta || '%')
             not like '%TRANSFERENCIA%',
             'o resumo não repete tarefa já concluída');

  perform ok((select corpo from notificacao
               where chave like 'fila_do_dia:' || v_mta || '%') like '%COLETA%',
             'o resumo lista o que ainda falta fazer');

  -- ===========================================================
  raise notice '--- canal dos avisos (sem e-mail configurado) ---';
  perform ok((select canal from notificacao where chave='confirmacao:'||v_r1) = 'APP',
             'com email_ativo=false o aviso nasce no canal APP');

  perform ok(not exists (select 1 from notificacao_pendente),
             'worker de e-mail não vê avisos do canal APP');

  update config_sistema set email_ativo = true;
  insert into reserva (pool_id, horario_id, data, professor_id, turma_texto, quantidade)
  values (v_pool_pio, v_h2, v_data, v_prof2, '5ºA', 5);
  perform ok((select canal from notificacao
               where assunto like '%5ºA%' limit 1) = 'EMAIL',
             'ligar email_ativo passa os novos avisos para o canal EMAIL');
  perform ok(exists (select 1 from notificacao_pendente),
             'worker de e-mail passa a enxergar a fila');
  update config_sistema set email_ativo = false;

  raise notice '';
  raise notice '=== TODOS OS TESTES PASSARAM ===';
end $$;
