# Agendamento de iPads e Notebooks — Rede Marista

Substitui as 5 planilhas mensais (Maristão, Maristinha e Pio XII) por um sistema
onde o calendário é gerado, o saldo é calculado e os avisos saem sozinhos.

## Os quatro problemas que isso resolve

| Antes | Agora |
|---|---|
| Criar uma aba nova a cada mês, em 5 planilhas | A grade horária é cadastrada uma vez; qualquer data é gerada a partir dela |
| Professores agendam e a coordenação não fica sabendo | Aviso para a coordenação a cada novo agendamento |
| Ninguém lembra de levar/buscar os iPads | Lembrete de véspera, fila do dia para o estagiário e cobrança automática de devolução em atraso |
| Ir até o professor levar e depois buscar | Fila com check-in/check-out e **transferência direta** entre salas em horários consecutivos |

O fluxo completo está em [`docs/FLUXO-LOGISTICA.md`](docs/FLUXO-LOGISTICA.md).

## Decisões de modelagem

**O saldo não é um número digitado.** Na planilha, cada célula guarda `35` e alguém
subtrai à mão. Aqui a capacidade está na frota (`pool.quantidade_total`) e o saldo de
cada horário é a função `saldo_disponivel()`. A tela e o trigger de validação usam a
**mesma** função, então o que o professor vê é exatamente o que o banco aceita.

**O calendário é derivado, não digitado.** `horario` guarda a grade recorrente por
unidade e turno, com os dias da semana em que vale. Novembro de 2027 já existe.

**As tarefas do estagiário são geradas.** Cada reserva confirmada produz as tarefas de
entrega e coleta. Quando a mesma frota, na mesma quantidade, sai de uma sala num
horário e entra em outra no horário seguinte, as duas viram uma `TRANSFERENCIA` —
uma viagem em vez de duas.

**A cobertura do estagiário é uma regra, não um combinado.** `janela_apoio` diz que há
estagiário de segunda a quinta pela manhã. Fora dela a reserva cai automaticamente
para retirada no balcão e o professor é avisado no ato do agendamento — antes de criar
a expectativa errada.

## Stack

- **Postgres (Supabase)** — schema, regras e RLS. A lógica está no banco, então
  nenhum cliente consegue burlá-la.
- **Next.js na Vercel** — as telas.
- **Edge Function (Deno)** — worker de e-mail, pronto mas desligado (veja abaixo).

### Nenhuma dependência do TI

Registrar app no Entra ID e conceder permissões do Microsoft Graph exige
administrador do tenant, que não temos. Então nada aqui depende da Microsoft:

- **Login**: senha criada pela coordenação **ou** magic link. A senha funciona sem
  nenhum e-mail configurado, então o sistema roda desde o primeiro dia.
- **Avisos**: hoje aparecem na aba **Avisos** dentro do próprio sistema.

### Ligando o e-mail depois

Toda notificação já nasce numa fila (`notificacao`). Com `email_ativo = false`, ela
fica só no app. Quando houver um remetente configurado:

```sql
update config_sistema set email_ativo = true;
```

A partir daí os novos avisos saem também por e-mail, com anexo `.ics` para o
calendário do professor. Nenhuma regra muda — só a chave.

Para isso é preciso um domínio de envio (próprio ou o institucional, com dois
registros DNS) e a chave do Resend nos secrets.

## Instalação

### 1. Banco

```bash
supabase link --project-ref <ref>
supabase db push
```

Depois, no SQL Editor:

```sql
-- Domínio institucional. Sem esta linha, ninguém consegue entrar.
insert into dominio_permitido (dominio, papel_padrao)
values ('seudominio.edu.br', 'PROFESSOR');

-- Seu usuário como ADMIN (após o primeiro login)
insert into pessoa_papel (pessoa_id, papel, unidade_id)
select id, 'ADMIN', unidade_id from pessoa where email = 'voce@seudominio.edu.br';
```

### 2. Jobs

Habilite `pg_cron` em Database → Extensions e rode `supabase/jobs.sql`.

### 3. Worker

```bash
supabase secrets set RESEND_API_KEY=re_xxx \
                     EMAIL_REMETENTE="Agendamento <agendamento@seudominio.edu.br>" \
                     APP_URL=https://seuapp.vercel.app
supabase functions deploy notificar
```

E agende a chamada a cada 5 minutos (veja o cabeçalho de
`supabase/functions/notificar/index.ts`).

### 4. App

```bash
cd web
cp .env.example .env.local     # e preencha com a URL e a anon key do projeto
npm install
npm run dev
```

Deploy na Vercel: apontar para a pasta `web/` e definir as duas variáveis
`NEXT_PUBLIC_SUPABASE_*`.

## Telas

| Rota | Quem usa | Para quê |
|---|---|---|
| `/agenda` | Professor | Escolhe frota e data, vê o saldo de cada horário e reserva |
| `/minhas` | Professor | Suas reservas e cancelamento |
| `/fila` | Estagiário, coordenação | Fila do dia com check-out e conferência de devolução |
| `/avisos` | Todos | Confirmações, lembretes e alertas de atraso |

## Testes

```bash
./supabase/tests/run.sh                                    # regras + RLS
node supabase/functions/_shared/__tests__/ics.test.mjs     # geração do .ics
cd web && npm run typecheck && npm run build                # app
```

A suíte de RLS roda como `authenticated`, não como superusuário — superusuário ignora
RLS e daria falso positivo.

## Pendências de conferência

Duas divergências vieram das planilhas e estão marcadas com `CONFERIR` no seed:

1. **Intervalo do Maristão.** A planilha de iPads traz `9h50-10h15`, que colide com o
   3º Horário (`9h40-10h25`). A de notebooks traz `10h25-10h50`, coerente com a grade.
   Adotamos a segunda.
2. **Quantidade de notebooks do Maristão.** A planilha não traz saldo, só texto livre.
   Valor provisório: 20.
