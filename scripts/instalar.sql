-- =============================================================================
-- INSTALAÇÃO COMPLETA — Agendamento de iPads e Notebooks
--
-- Cole este arquivo inteiro no SQL Editor do Supabase e execute uma vez.
-- Gerado a partir de supabase/migrations/. Não edite aqui: edite as migrations.
--
-- Depois de executar, faça o PASSO FINAL no fim do arquivo.
-- =============================================================================


-- ===========================================================================
-- 20260904090000_schema.sql
-- ===========================================================================
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

-- ===========================================================================
-- 20260904091000_regras.sql
-- ===========================================================================
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

-- ===========================================================================
-- 20260904092000_seed.sql
-- ===========================================================================
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

-- ===========================================================================
-- 20260904093000_rls.sql
-- ===========================================================================
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

-- ===========================================================================
-- 20260904094000_worker.sql
-- ===========================================================================
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

-- ===========================================================================
-- 20260904095000_avisos_no_app.sql
-- ===========================================================================
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

-- ===========================================================================
-- 20260904096000_escolha_unidade.sql
-- ===========================================================================
-- =============================================================================
-- Escolha de unidade no primeiro acesso.
--
-- As três unidades compartilham o mesmo domínio de e-mail, então o domínio não
-- diz a qual unidade o professor pertence. Sem unidade, minhas_unidades() volta
-- vazio e o RLS recusa qualquer reserva — sem explicação útil na tela.
--
-- O professor passa a escolher a unidade no primeiro acesso; a coordenação pode
-- corrigir depois.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- CORREÇÃO: o provisionamento quebrava para domínio compartilhado.
--
-- pessoa_papel tem unidade_id na chave primária, logo NOT NULL. Com um domínio
-- sem unidade (o caso real: as três unidades dividem o mesmo e-mail), o gatilho
-- tentava inserir o papel com unidade nula e a criação do usuário falhava por
-- inteiro — ninguém conseguia sequer entrar.
--
-- Agora o papel só é criado quando o domínio aponta uma unidade. Quem vem de
-- domínio compartilhado recebe o papel ao escolher a unidade, no primeiro
-- acesso.
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

  -- Só concede o papel quando há unidade. Sem isto, um domínio compartilhado
  -- entre unidades derruba a criação do usuário.
  if v_dom.unidade_id is not null then
    insert into pessoa_papel (pessoa_id, papel, unidade_id)
    values (new.id, v_dom.papel_padrao, v_dom.unidade_id)
    on conflict do nothing;
  end if;

  return new;
end;
$$;

-- Lista das unidades para a tela de escolha. Precisa funcionar para quem ainda
-- não tem unidade, então não depende de minhas_unidades().
create or replace function unidades_disponiveis()
returns table (id uuid, nome text, sigla text)
language sql stable security definer set search_path = public as $$
  select u.id, u.nome, u.sigla
    from unidade u
   where u.ativo
   order by u.nome;
$$;

-- O próprio usuário define sua unidade. Só entre as ativas, e o papel
-- acompanha: uma linha de pessoa_papel apontando para outra unidade daria
-- acesso indevido àquela unidade.
create or replace function define_minha_unidade(p_unidade uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare v_existe boolean;
begin
  if auth.uid() is null then
    raise exception 'Sessão inválida.';
  end if;

  select exists (select 1 from unidade where id = p_unidade and ativo)
    into v_existe;
  if not v_existe then
    raise exception 'Unidade inexistente ou inativa.';
  end if;

  update pessoa set unidade_id = p_unidade where id = auth.uid();

  -- Move os papéis sem unidade, e os que apontavam para outra unidade, para a
  -- escolhida. ADMIN é global e não se move.
  update pessoa_papel
     set unidade_id = p_unidade
   where pessoa_id = auth.uid()
     and papel <> 'ADMIN'
     and unidade_id is distinct from p_unidade;

  -- Garante ao menos o papel de professor.
  insert into pessoa_papel (pessoa_id, papel, unidade_id)
  values (auth.uid(), 'PROFESSOR', p_unidade)
  on conflict do nothing;
end $$;

comment on function define_minha_unidade is
  'Primeiro acesso: o professor escolhe a unidade. A coordenação pode corrigir '
  'depois pela gestão de pessoas.';

-- Perfil do usuário logado, para a tela decidir o que mostrar.
create or replace function meu_perfil()
returns table (
  id uuid, nome text, email text, unidade_id uuid, unidade_nome text,
  papeis papel[], precisa_escolher_unidade boolean
)
language sql stable security definer set search_path = public as $$
  select p.id, p.nome, p.email, p.unidade_id, u.nome,
         coalesce(array_agg(pp.papel) filter (where pp.papel is not null),
                  '{}'::papel[]),
         -- ADMIN alcança todas as unidades; não precisa escolher.
         p.unidade_id is null
           and not exists (select 1 from pessoa_papel a
                            where a.pessoa_id = p.id and a.papel = 'ADMIN')
    from pessoa p
    left join unidade u on u.id = p.unidade_id
    left join pessoa_papel pp on pp.pessoa_id = p.id
   where p.id = auth.uid()
   group by p.id, p.nome, p.email, p.unidade_id, u.nome;
$$;


-- =============================================================================
-- PASSO FINAL — obrigatório
-- =============================================================================
-- 1. Autorize o domínio de e-mail da rede. SEM ESTA LINHA NINGUÉM ENTRA.
--    Deixe unidade_id nulo quando as unidades dividem o mesmo domínio: o
--    professor escolhe a unidade no primeiro acesso.
--
--    insert into dominio_permitido (dominio, papel_padrao, unidade_id)
--    values ('seudominio.org', 'PROFESSOR', null);
--
-- 2. Crie seu usuário em Authentication → Users → Add user
--    (marque "Auto Confirm User" e defina uma senha).
--
-- 3. Promova-se a ADMIN:
--
--    insert into pessoa_papel (pessoa_id, papel, unidade_id)
--    select p.id, 'ADMIN', u.id
--      from pessoa p cross join unidade u
--     where p.email = 'voce@seudominio.org'
--    on conflict do nothing;
-- =============================================================================
