-- =============================================================================
-- Agendamento de iPads / Notebooks — Rede Marista
-- Schema base. Domínio em pt-BR para casar com o vocabulário da operação.
-- =============================================================================

create extension if not exists "pgcrypto";
create extension if not exists "btree_gist";

-- -----------------------------------------------------------------------------
-- Tipos
-- -----------------------------------------------------------------------------
create type turno as enum ('MATUTINO', 'VESPERTINO', 'NOTURNO', 'INTEGRAL');

create type modo_atendimento as enum (
  'ENTREGA_EM_SALA',   -- estagiário leva e busca na sala
  'RETIRADA_BALCAO'    -- professor retira e devolve no ponto de apoio
);

create type status_reserva as enum (
  'LISTA_ESPERA',
  'CONFIRMADA',
  'EM_SEPARACAO',
  'ENTREGUE',
  'DEVOLVIDA',
  'ATRASADA',
  'CANCELADA',
  'NAO_COMPARECEU'
);

create type tipo_tarefa as enum ('ENTREGA', 'COLETA', 'TRANSFERENCIA');
create type status_tarefa as enum ('PENDENTE', 'EM_ANDAMENTO', 'CONCLUIDA', 'CANCELADA');
create type papel as enum ('PROFESSOR', 'ESTAGIARIO', 'COORDENACAO', 'ADMIN');
create type tipo_excecao as enum ('FERIADO', 'RECESSO', 'EVENTO', 'FECHADO');

-- -----------------------------------------------------------------------------
-- Estrutura organizacional
-- -----------------------------------------------------------------------------
create table unidade (
  id                uuid primary key default gen_random_uuid(),
  nome              text not null unique,          -- 'Maristão', 'Maristinha', 'Pio XII'
  sigla             text not null unique,
  modo_padrao       modo_atendimento not null default 'ENTREGA_EM_SALA',
  ponto_apoio       text,                          -- 'Coordenação — Bloco B'
  fuso              text not null default 'America/Sao_Paulo',
  antecedencia_min_horas smallint not null default 0,
  antecedencia_max_dias  smallint not null default 60,
  ativo             boolean not null default true,
  criado_em         timestamptz not null default now()
);

comment on column unidade.antecedencia_min_horas is
  'Regra do Maristão: agendar com no mínimo 24h de antecedência. Estava escrita '
  'nas orientações da planilha e não era verificada por ninguém.';

comment on column unidade.modo_padrao is
  'Regra de entrega da unidade. Pio XII = RETIRADA_BALCAO; demais = ENTREGA_EM_SALA.';

create table segmento (
  id                uuid primary key default gen_random_uuid(),
  unidade_id        uuid not null references unidade(id) on delete cascade,
  nome              text not null,                 -- 'Anos Iniciais', 'Anos Finais', 'Ensino Médio'
  ordem             smallint not null default 0,
  unique (unidade_id, nome)
);

create table local (
  id                uuid primary key default gen_random_uuid(),
  unidade_id        uuid not null references unidade(id) on delete cascade,
  nome              text not null,                 -- 'Sala 12', 'Lab. de Ciências'
  bloco             text,
  unique (unidade_id, nome)
);

-- -----------------------------------------------------------------------------
-- Pessoas
-- -----------------------------------------------------------------------------
-- Espelha auth.users. Login por magic link no e-mail institucional (não exige
-- admin do Entra ID). O perfil é criado no primeiro acesso, se o domínio do
-- e-mail estiver na allowlist.
create table pessoa (
  id                uuid primary key references auth.users(id) on delete cascade,
  nome              text not null,
  email             text not null unique,
  unidade_id        uuid references unidade(id) on delete set null,
  telefone          text,
  ativo             boolean not null default true,
  criado_em         timestamptz not null default now()
);

create table pessoa_papel (
  pessoa_id         uuid not null references pessoa(id) on delete cascade,
  papel             papel not null,
  unidade_id        uuid references unidade(id) on delete cascade,
  primary key (pessoa_id, papel, unidade_id)
);

comment on table pessoa_papel is
  'Papel por unidade. Uma coordenadora pode ser COORDENACAO em duas unidades.';

create table turma (
  id                uuid primary key default gen_random_uuid(),
  segmento_id       uuid not null references segmento(id) on delete cascade,
  nome              text not null,                 -- '2ºD', 'Infantil 5A'
  qtd_alunos        smallint,
  local_padrao_id   uuid references local(id) on delete set null,
  unique (segmento_id, nome)
);

comment on column turma.local_padrao_id is
  'Sala habitual da turma. Preenche o destino da entrega sem o professor digitar.';

-- -----------------------------------------------------------------------------
-- Frota
-- -----------------------------------------------------------------------------
-- Um "pool" é um carrinho/conjunto: iPads Pio XII (35), iPads Maristão (20),
-- Notebooks Maristão, etc. A quantidade é do pool, não da célula da planilha.
create table pool (
  id                uuid primary key default gen_random_uuid(),
  unidade_id        uuid not null references unidade(id) on delete cascade,
  nome              text not null,
  tipo              text not null default 'IPAD',  -- IPAD | NOTEBOOK
  quantidade_total  smallint not null check (quantidade_total > 0),
  local_guarda_id   uuid references local(id) on delete set null,
  min_por_reserva   smallint not null default 1,
  max_por_reserva   smallint,
  ativo             boolean not null default true,
  unique (unidade_id, nome)
);

comment on column pool.quantidade_total is
  'Fonte única da capacidade. O saldo por horário é derivado, nunca digitado.';

-- Quais segmentos podem reservar de qual pool.
create table pool_segmento (
  pool_id           uuid not null references pool(id) on delete cascade,
  segmento_id       uuid not null references segmento(id) on delete cascade,
  primary key (pool_id, segmento_id)
);

-- Equipamento individual: só para rastrear perda/manutenção. Opcional.
create table equipamento (
  id                uuid primary key default gen_random_uuid(),
  pool_id           uuid not null references pool(id) on delete cascade,
  tombo             text not null,
  serial            text,
  em_manutencao     boolean not null default false,
  observacao        text,
  unique (pool_id, tombo)
);

-- Capacidade efetiva desconta equipamentos em manutenção.
create view pool_capacidade as
select p.id            as pool_id,
       p.quantidade_total,
       p.quantidade_total - coalesce(
         (select count(*) from equipamento e
           where e.pool_id = p.id and e.em_manutencao), 0)::smallint
                       as capacidade
from pool p;

-- -----------------------------------------------------------------------------
-- Grade horária recorrente  ← elimina "ficar criando os meses"
-- -----------------------------------------------------------------------------
-- A grade é cadastrada UMA vez por unidade/turno. O calendário de qualquer data
-- é gerado a partir dela. Não existe "aba de novembro".
create table horario (
  id                uuid primary key default gen_random_uuid(),
  unidade_id        uuid not null references unidade(id) on delete cascade,
  turno             turno not null,
  ordem             smallint not null,             -- 1 = '1º Horário'
  rotulo            text not null,                 -- '1º Horário' | '7h30-8h30'
  inicio            time not null,
  fim               time not null,
  eh_intervalo      boolean not null default false,
  dias_semana       smallint[] not null default '{1,2,3,4,5}', -- ISO: 1=seg .. 7=dom
  ativo             boolean not null default true,
  constraint horario_intervalo_valido check (fim > inicio),
  unique (unidade_id, turno, ordem)
);

comment on column horario.dias_semana is
  'ISO-8601: 1=segunda .. 7=domingo. Sábado letivo = incluir 6.';

-- Feriados, recessos, "Fechado". Bloqueia agendamento na data.
create table excecao_calendario (
  id                uuid primary key default gen_random_uuid(),
  unidade_id        uuid references unidade(id) on delete cascade, -- null = todas
  data              date not null,
  tipo              tipo_excecao not null default 'FERIADO',
  descricao         text not null,
  unique (unidade_id, data)
);

-- Janela em que há estagiário de plantão. Fora dela, cai para RETIRADA_BALCAO.
create table janela_apoio (
  id                uuid primary key default gen_random_uuid(),
  unidade_id        uuid not null references unidade(id) on delete cascade,
  dia_semana        smallint not null check (dia_semana between 1 and 7),
  inicio            time not null,
  fim               time not null,
  descricao         text,
  constraint janela_valida check (fim > inicio)
);

comment on table janela_apoio is
  'Cobertura do estagiário. Hoje: seg-qui, turno da manhã. Fora disso o professor '
  'retira no balcão — e é avisado disso no ato do agendamento.';

-- -----------------------------------------------------------------------------
-- Reservas
-- -----------------------------------------------------------------------------
create table reserva (
  id                uuid primary key default gen_random_uuid(),
  pool_id           uuid not null references pool(id) on delete restrict,
  horario_id        uuid not null references horario(id) on delete restrict,
  data              date not null,
  professor_id      uuid not null references pessoa(id) on delete restrict,
  turma_id          uuid references turma(id) on delete set null,
  turma_texto       text,                          -- fallback quando não há cadastro
  local_id          uuid references local(id) on delete set null,
  quantidade        smallint not null check (quantidade > 0),
  status            status_reserva not null default 'CONFIRMADA',
  modo              modo_atendimento not null,
  observacao        text,

  -- execução
  entregue_em       timestamptz,
  entregue_por      uuid references pessoa(id) on delete set null,
  devolvido_em      timestamptz,
  devolvido_por     uuid references pessoa(id) on delete set null,
  qtd_devolvida     smallint,

  criado_por        uuid references pessoa(id) on delete set null,
  criado_em         timestamptz not null default now(),
  atualizado_em     timestamptz not null default now(),

  constraint turma_informada check (turma_id is not null or turma_texto is not null)
);

create index reserva_agenda_idx on reserva (pool_id, data, horario_id)
  where status not in ('CANCELADA', 'LISTA_ESPERA');
create index reserva_professor_idx on reserva (professor_id, data);
create index reserva_status_idx on reserva (status, data);

-- Um professor não reserva o mesmo pool duas vezes no mesmo horário.
create unique index reserva_sem_duplicata_idx
  on reserva (pool_id, data, horario_id, professor_id)
  where status not in ('CANCELADA', 'NAO_COMPARECEU');

-- -----------------------------------------------------------------------------
-- Tarefas logísticas (geradas por trigger, nunca digitadas)
-- -----------------------------------------------------------------------------
create table tarefa (
  id                uuid primary key default gen_random_uuid(),
  tipo              tipo_tarefa not null,
  unidade_id        uuid not null references unidade(id) on delete cascade,
  data              date not null,
  hora_prevista     time not null,
  quantidade        smallint not null,

  reserva_origem_id uuid references reserva(id) on delete cascade, -- de onde sai
  reserva_destino_id uuid references reserva(id) on delete cascade, -- para onde vai
  local_origem_id   uuid references local(id) on delete set null,
  local_destino_id  uuid references local(id) on delete set null,

  status            status_tarefa not null default 'PENDENTE',
  responsavel_id    uuid references pessoa(id) on delete set null,
  concluida_em      timestamptz,
  qtd_conferida     smallint,
  observacao        text,
  criado_em         timestamptz not null default now(),

  constraint tarefa_tem_reserva
    check (reserva_origem_id is not null or reserva_destino_id is not null)
);

create index tarefa_fila_idx on tarefa (unidade_id, data, hora_prevista)
  where status = 'PENDENTE';

comment on table tarefa is
  'Fila operacional do estagiário. TRANSFERENCIA funde a coleta de uma reserva com '
  'a entrega da seguinte quando a mesma frota vai direto de uma sala para outra.';

-- -----------------------------------------------------------------------------
-- Ocorrências (falta de equipamento, dano, no-show)
-- -----------------------------------------------------------------------------
create table ocorrencia (
  id                uuid primary key default gen_random_uuid(),
  reserva_id        uuid references reserva(id) on delete set null,
  tarefa_id         uuid references tarefa(id) on delete set null,
  pool_id           uuid not null references pool(id) on delete cascade,
  tipo              text not null,                 -- FALTA | DANO | NAO_COMPARECEU | ATRASO
  quantidade        smallint,
  descricao         text not null,
  resolvida         boolean not null default false,
  registrada_por    uuid references pessoa(id) on delete set null,
  criado_em         timestamptz not null default now()
);

-- -----------------------------------------------------------------------------
-- Notificações (fila com dedupe — nada é enviado duas vezes)
-- -----------------------------------------------------------------------------
create table notificacao (
  id                uuid primary key default gen_random_uuid(),
  chave             text not null unique,          -- ex.: 'vespera:<reserva_id>'
  destinatario_id   uuid references pessoa(id) on delete cascade,
  destinatario_email text not null,
  reserva_id        uuid references reserva(id) on delete cascade,
  canal             text not null default 'EMAIL', -- EMAIL | TEAMS
  assunto           text not null,
  corpo             text not null,
  agendada_para     timestamptz not null default now(),
  enviada_em        timestamptz,
  erro              text,
  tentativas        smallint not null default 0
);

create index notificacao_pendente_idx on notificacao (agendada_para)
  where enviada_em is null;

comment on column notificacao.chave is
  'Dedupe. Reprocessar o cron não reenvia e-mail já entregue.';

-- Convite de calendário (.ics) anexado ao e-mail de confirmação. O professor
-- adiciona ao Outlook em um clique e o alarme dispara no aparelho dele.
-- Guardamos UID e SEQUENCE para que remarcar/cancelar ATUALIZE o mesmo evento no
-- calendário em vez de criar um duplicado.
create table convite_calendario (
  reserva_id        uuid primary key references reserva(id) on delete cascade,
  uid               text not null unique,          -- UID do VEVENT
  sequence          integer not null default 0,    -- incrementa a cada alteração
  metodo            text not null default 'REQUEST', -- REQUEST | CANCEL
  atualizado_em     timestamptz not null default now()
);

-- Domínios de e-mail autorizados a entrar. Sem isso, qualquer e-mail entraria
-- via magic link.
create table dominio_permitido (
  dominio           text primary key,              -- 'marista.edu.br'
  papel_padrao      papel not null default 'PROFESSOR',
  unidade_id        uuid references unidade(id) on delete set null
);

-- -----------------------------------------------------------------------------
-- Configuração de notificações (sem horário escrito no código)
-- -----------------------------------------------------------------------------
create table config_notificacao (
  id                uuid primary key default gen_random_uuid(),
  unidade_id        uuid references unidade(id) on delete cascade,
  chave             text not null,                 -- 'vespera' | 'fila_do_dia' | ...
  ativo             boolean not null default true,
  antecedencia_min  integer,                       -- p/ lembretes relativos
  hora_envio        time,                          -- p/ lembretes de horário fixo
  destinatarios     papel[] not null default '{}',
  unique (unidade_id, chave)
);

-- -----------------------------------------------------------------------------
-- Auditoria
-- -----------------------------------------------------------------------------
create table auditoria (
  id                bigserial primary key,
  tabela            text not null,
  registro_id       uuid not null,
  acao              text not null,
  ator_id           uuid,
  antes             jsonb,
  depois            jsonb,
  criado_em         timestamptz not null default now()
);

create index auditoria_registro_idx on auditoria (tabela, registro_id, criado_em desc);
