# Agendamento de iPads e Notebooks — Rede Marista

Substitui as 5 planilhas mensais (Maristão, Maristinha e Pio XII) por um sistema
onde o calendário é gerado, o saldo é calculado e os avisos saem sozinhos.

## Os quatro problemas que isso resolve

| Antes | Agora |
|---|---|
| Criar uma aba nova a cada mês, em 5 planilhas | A grade horária é cadastrada uma vez; qualquer data é gerada a partir dela |
| Professores agendam e a coordenação não fica sabendo | E-mail para a coordenação a cada novo agendamento |
| Ninguém lembra de levar/buscar os iPads | Convite `.ics` no calendário do professor + lembrete na véspera + fila do dia para o estagiário |
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
- **Edge Function (Deno)** — worker que envia os e-mails e monta o `.ics`.
- **Resend** — envio. Não exige admin do Microsoft 365.
- **Login por magic link** — o professor entra com o e-mail institucional, sem senha
  nova e sem app registrado no Entra ID.

### Por que não SSO Microsoft

Registrar app no Entra ID e conceder permissões do Graph exige administrador do
tenant. O magic link entrega o mesmo resultado prático (sem senha nova) e o `.ics`
entrega o lembrete no calendário sem tocar no Graph — funcionando também no Google
e no celular.

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

## Testes

```bash
./supabase/tests/run.sh                                    # regras + RLS
node supabase/functions/_shared/__tests__/ics.test.mjs     # geração do .ics
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
