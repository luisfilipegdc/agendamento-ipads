-- =============================================================================
-- Seed: as 3 unidades, seus segmentos, frotas e grades horárias.
-- Extraído das 5 planilhas em uso (fev–dez/2026).
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Unidades
-- -----------------------------------------------------------------------------
insert into unidade (nome, sigla, modo_padrao, ponto_apoio, antecedencia_min_horas)
values
  ('Maristão',   'MTO', 'ENTREGA_EM_SALA', 'Sala de Tecnologia',        24),
  ('Maristinha', 'MTA', 'ENTREGA_EM_SALA', 'Coordenação',                0),
  ('Pio XII',    'PIO', 'RETIRADA_BALCAO', 'Coordenação — Bloco B',      0)
on conflict (nome) do nothing;

-- Maristão exige 24h de antecedência (regra que estava só no texto da planilha).

-- -----------------------------------------------------------------------------
-- Segmentos
-- -----------------------------------------------------------------------------
insert into segmento (unidade_id, nome, ordem)
select u.id, s.nome, s.ordem
  from unidade u
  join (values
    ('Maristão',   'Anos Finais',   2),
    ('Maristão',   'Ensino Médio',  3),
    ('Maristinha', 'Anos Iniciais', 1),
    ('Maristinha', 'Anos Finais',   2),
    ('Pio XII',    'Anos Iniciais', 1)
  ) as s(unidade, nome, ordem) on s.unidade = u.nome
on conflict do nothing;

-- -----------------------------------------------------------------------------
-- Locais de guarda
-- -----------------------------------------------------------------------------
insert into local (unidade_id, nome, bloco)
select u.id, l.nome, l.bloco
  from unidade u
  join (values
    ('Maristão',   'Sala de Tecnologia',     null),
    ('Maristinha', 'Coordenação',            null),
    ('Pio XII',    'Coordenação',            'Bloco B')
  ) as l(unidade, nome, bloco) on l.unidade = u.nome
on conflict do nothing;

-- -----------------------------------------------------------------------------
-- Frotas (pools). Quantidades lidas das planilhas.
-- -----------------------------------------------------------------------------
insert into pool (unidade_id, nome, tipo, quantidade_total, local_guarda_id)
select u.id, p.nome, p.tipo, p.qtd,
       (select id from local where unidade_id = u.id and nome = p.guarda)
  from unidade u
  join (values
    ('Maristão',   'iPads Maristão',              'IPAD',     20, 'Sala de Tecnologia'),
    ('Maristão',   'Notebooks Maristão',          'NOTEBOOK', 20, 'Sala de Tecnologia'),
    ('Maristinha', 'iPads Anos Iniciais',         'IPAD',     35, 'Coordenação'),
    ('Maristinha', 'iPads Anos Finais',           'IPAD',     43, 'Coordenação'),
    ('Pio XII',    'iPads Pio XII',               'IPAD',     35, 'Coordenação')
  ) as p(unidade, nome, tipo, qtd, guarda) on p.unidade = u.nome
on conflict (unidade_id, nome) do nothing;

-- CONFERIR: a quantidade de notebooks do Maristão não aparece na planilha
-- (as células só têm texto livre, sem saldo). Valor provisório = 20.

-- Quem pode reservar de qual frota
insert into pool_segmento (pool_id, segmento_id)
select p.id, s.id
  from pool p
  join unidade u on u.id = p.unidade_id
  join segmento s on s.unidade_id = u.id
 where (p.nome = 'iPads Anos Iniciais' and s.nome = 'Anos Iniciais')
    or (p.nome = 'iPads Anos Finais'   and s.nome = 'Anos Finais')
    or (p.nome = 'iPads Pio XII'       and s.nome = 'Anos Iniciais')
    or (p.nome in ('iPads Maristão', 'Notebooks Maristão'))
on conflict do nothing;

-- -----------------------------------------------------------------------------
-- Grades horárias. Cadastradas UMA vez — o calendário de qualquer mês sai daqui.
-- -----------------------------------------------------------------------------

-- Pio XII — Anos Iniciais (sábado letivo: dias 1..6)
insert into horario (unidade_id, turno, ordem, rotulo, inicio, fim, eh_intervalo, dias_semana)
select (select id from unidade where nome = 'Pio XII'),
       h.turno::turno, h.ordem, h.rotulo, h.inicio::time, h.fim::time, h.intv, '{1,2,3,4,5,6}'
  from (values
    ('MATUTINO',   1, '7h30-8h30',   '07:30', '08:30', false),
    ('MATUTINO',   2, '8h30-9h15',   '08:30', '09:15', false),
    ('MATUTINO',   3, 'Intervalo',   '09:15', '09:45', true ),
    ('MATUTINO',   4, '9h45-10h30',  '09:45', '10:30', false),
    ('MATUTINO',   5, '10h30-11h15', '10:30', '11:15', false),
    ('MATUTINO',   6, '11h15-12h',   '11:15', '12:00', false),
    ('VESPERTINO', 1, '13h30-14h30', '13:30', '14:30', false),
    ('VESPERTINO', 2, '14h30-15h15', '14:30', '15:15', false),
    ('VESPERTINO', 3, 'Intervalo',   '15:15', '15:45', true ),
    ('VESPERTINO', 4, '15h45-16h30', '15:45', '16:30', false),
    ('VESPERTINO', 5, '16h30-17h15', '16:30', '17:15', false),
    ('VESPERTINO', 6, '17h15-18h',   '17:15', '18:00', false)
  ) as h(turno, ordem, rotulo, inicio, fim, intv)
on conflict (unidade_id, turno, ordem) do nothing;

-- Maristinha — grade única para Anos Iniciais e Anos Finais (idênticas nas planilhas)
insert into horario (unidade_id, turno, ordem, rotulo, inicio, fim, eh_intervalo, dias_semana)
select (select id from unidade where nome = 'Maristinha'),
       h.turno::turno, h.ordem, h.rotulo, h.inicio::time, h.fim::time, h.intv, '{1,2,3,4,5,6}'
  from (values
    ('MATUTINO',   1, '7h30-8h15',   '07:30', '08:15', false),
    ('MATUTINO',   2, '8h15-9h',     '08:15', '09:00', false),
    ('MATUTINO',   3, '9h-9h40',     '09:00', '09:40', false),
    ('MATUTINO',   4, 'Intervalo',   '09:40', '10:05', true ),
    ('MATUTINO',   5, '10h05-10h55', '10:05', '10:55', false),
    ('MATUTINO',   6, '10h55-11h40', '10:55', '11:40', false),
    ('MATUTINO',   7, '11h40-12h25', '11:40', '12:25', false),
    ('VESPERTINO', 1, '13h30-14h15', '13:30', '14:15', false),
    ('VESPERTINO', 2, '14h15-15h',   '14:15', '15:00', false),
    ('VESPERTINO', 3, '15h-15h45',   '15:00', '15:45', false),
    ('VESPERTINO', 4, 'Intervalo',   '15:45', '16:10', true ),
    ('VESPERTINO', 5, '16h10-16h55', '16:10', '16:55', false),
    ('VESPERTINO', 6, '16h55-17h40', '16:55', '17:40', false)
  ) as h(turno, ordem, rotulo, inicio, fim, intv)
on conflict (unidade_id, turno, ordem) do nothing;

-- Maristão — Anos Finais e Ensino Médio
-- NOTA: a planilha de iPads traz o intervalo como "9h50-10h15", o que colide com
-- o 3º Horário (9h40-10h25). A planilha de notebooks da mesma unidade traz
-- 10h25-10h50, que é coerente com a grade. Adotado 10h25-10h50 — CONFERIR.
insert into horario (unidade_id, turno, ordem, rotulo, inicio, fim, eh_intervalo, dias_semana)
select (select id from unidade where nome = 'Maristão'),
       h.turno::turno, h.ordem, h.rotulo, h.inicio::time, h.fim::time, h.intv, '{1,2,3,4,5}'
  from (values
    ('MATUTINO',   1, '1º Horário',  '08:00', '08:50', false),
    ('MATUTINO',   2, '2º Horário',  '08:50', '09:40', false),
    ('MATUTINO',   3, '3º Horário',  '09:40', '10:25', false),
    ('MATUTINO',   4, 'Intervalo',   '10:25', '10:50', true ),
    ('MATUTINO',   5, '4º Horário',  '10:50', '11:35', false),
    ('MATUTINO',   6, '5º Horário',  '11:35', '12:20', false),
    ('MATUTINO',   7, '6º Horário',  '12:20', '13:05', false),
    ('VESPERTINO', 1, '7º Horário',  '14:20', '15:05', false),
    ('VESPERTINO', 2, '8º Horário',  '15:05', '15:50', false),
    ('VESPERTINO', 3, '9º Horário',  '15:50', '16:35', false),
    ('VESPERTINO', 4, '10º Horário', '16:35', '17:20', false)
  ) as h(turno, ordem, rotulo, inicio, fim, intv)
on conflict (unidade_id, turno, ordem) do nothing;

-- -----------------------------------------------------------------------------
-- Janela de cobertura do estagiário: segunda a quinta, turno da manhã.
-- Fora dela, o sistema avisa o professor que a retirada é no balcão.
-- -----------------------------------------------------------------------------
insert into janela_apoio (unidade_id, dia_semana, inicio, fim, descricao)
select u.id, d.dia, '07:00'::time, '13:00'::time, 'Estagiário — turno matutino'
  from unidade u
  cross join (values (1), (2), (3), (4)) as d(dia)
 where u.modo_padrao = 'ENTREGA_EM_SALA';

-- -----------------------------------------------------------------------------
-- Configuração das notificações (nada de horário no código)
-- -----------------------------------------------------------------------------
insert into config_notificacao (unidade_id, chave, hora_envio, antecedencia_min, destinatarios)
select u.id, c.chave, c.hora::time, c.antec, c.dest::papel[]
  from unidade u
  cross join (values
    ('confirmacao',     null,    null, '{PROFESSOR}'),
    ('novo_agendamento',null,    null, '{COORDENACAO}'),
    ('vespera',        '17:00',  null, '{PROFESSOR}'),
    ('fila_do_dia',    '06:30',  null, '{ESTAGIARIO,COORDENACAO}'),
    ('proxima_tarefa',  null,      15, '{ESTAGIARIO}'),
    ('atraso',          null,      20, '{PROFESSOR,COORDENACAO}'),
    ('resumo_semanal', '16:00',  null, '{COORDENACAO}')
  ) as c(chave, hora, antec, dest)
on conflict (unidade_id, chave) do nothing;

-- -----------------------------------------------------------------------------
-- Domínios autorizados a entrar via magic link.
-- SUBSTITUA pelo domínio real da rede antes de abrir para os professores.
-- Sem nenhuma linha aqui, ninguém consegue acessar — é proposital.
-- -----------------------------------------------------------------------------
-- insert into dominio_permitido (dominio, papel_padrao, unidade_id)
-- values ('marista.edu.br', 'PROFESSOR', null);
