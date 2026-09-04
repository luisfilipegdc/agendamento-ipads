# Fluxo de logística — proposta

> Este documento define o fluxo que hoje não existe: quem leva, quem busca,
> quem é cobrado e quando. É a regra de negócio central do sistema.

## 1. O problema atual

Hoje a planilha registra **intenção** ("Vinicius - 2ºD, 15 iPads") mas não registra
**execução**. Ninguém sabe, olhando a planilha:

- se o carrinho saiu da coordenação;
- se o professor recebeu;
- se devolveu, e com quantos equipamentos;
- quem estava de plantão naquele horário.

Resultado: alguém precisa ir até o professor levar, e depois ir buscar. O trabalho
é reativo e depende de memória.

## 2. Estados de uma reserva

```
SOLICITADA ──auto(há saldo)──> CONFIRMADA ──> EM_SEPARACAO ──> ENTREGUE ──> DEVOLVIDA
     │                              │                             │
     │                              │                             └─(passou do horário)─> ATRASADA
     └──sem saldo──> LISTA_ESPERA   └──> CANCELADA / NAO_COMPARECEU
```

- **CONFIRMADA** é automática quando há saldo. Não existe aprovação manual — isso é o
  que hoje trava o processo.
- **LISTA_ESPERA**: se outro professor cancelar, o primeiro da fila é promovido
  automaticamente e notificado.
- **NAO_COMPARECEU**: registrado pelo estagiário. Reincidência entra no relatório.
- **ATRASADA**: gerado automaticamente pelo relógio, não por alguém lembrar.

## 3. Modos de atendimento (por unidade)

A regra é diferente em cada unidade — e o sistema respeita isso:

| Unidade | Modo | Regra |
|---|---|---|
| Maristão | `ENTREGA_EM_SALA` | Estagiária leva e busca na sala |
| Maristinha | `ENTREGA_EM_SALA` | Estagiária leva e busca na sala |
| Pio XII | `RETIRADA_BALCAO` | Professor busca e devolve na Coordenação (Bloco B) |

O modo é um campo da unidade, não código. Mudou a regra, muda o cadastro.

## 4. Janela de cobertura do estagiário — a regra que resolve o gargalo

O estagiário existe **segunda a quinta, no turno da manhã**. Isso é cadastrado como
`janela_apoio`.

Quando um professor agenda **fora dessa janela**, o sistema:

1. rebaixa aquela reserva para `RETIRADA_BALCAO` automaticamente;
2. avisa **no momento do agendamento**, na tela:
   > "Neste horário não há estagiário de plantão. Você deve retirar e devolver os
   > iPads na Coordenação."
3. escreve isso no e-mail de confirmação e no evento do calendário.

Isso elimina a expectativa errada antes dela virar problema. Hoje o professor agenda
achando que alguém vai levar, e não vai.

## 5. Tarefas logísticas — geradas, não digitadas

Cada reserva confirmada gera automaticamente as tarefas do estagiário:

- `ENTREGA` — 10 min antes do início, no local da aula
- `COLETA` — no fim do horário, no local da aula

### 5.1 Transferência direta (otimização)

Se a mesma frota vai da sala A (horário N) para a sala B (horário N+1), levar de volta
ao depósito e sair de novo é trabalho jogado fora. O sistema detecta o encadeamento e
funde `COLETA(A)` + `ENTREGA(B)` em uma única tarefa:

```
TRANSFERENCIA — 3ºB (sala 12) ➜ 2ºA (sala 7) — 20 iPads — 10h25
```

Com 5 horários por turno, isso corta boa parte das viagens.

### 5.2 Conferência na devolução

A tarefa de `COLETA`/`DEVOLUCAO` pede a **quantidade conferida**. Se for menor que a
entregue, o sistema abre uma **ocorrência** vinculada ao professor e à reserva, e
notifica a coordenação na hora. Hoje a falta só aparece quando o próximo professor
reclama.

## 6. Linha do tempo de notificações

| Quando | Para quem | O quê |
|---|---|---|
| No agendamento | Professor | Confirmação + regra de retirada + evento no Outlook |
| No agendamento | Coordenação | "Novo agendamento" (resolve o *"os professores agendam e não sou notificado"*) |
| Véspera, 17h | Professor | "Amanhã você tem 20 iPads às 8h" |
| Dia, 06h30 | Estagiário + Coordenação | Fila do dia completa (entregas, coletas, transferências) |
| 15 min antes | Estagiário | Tarefa de entrega |
| 20 min após o fim | Professor + Coordenação | Devolução em atraso |
| Sexta, 16h | Coordenação | Resumo semanal: uso, no-shows, ocorrências |

Todas as regras de horário são configuráveis — nenhuma está escrita no código.

## 7. O que deixa de existir

- Criar aba de mês na planilha (a grade é recorrente, o calendário é gerado)
- Calcular saldo à mão (saldo é derivado, não digitado)
- Descobrir overbooking depois (o banco recusa a reserva)
- Lembrar de cobrar devolução (o relógio cobra)
