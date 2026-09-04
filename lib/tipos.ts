export type Turno = "MATUTINO" | "VESPERTINO" | "NOTURNO" | "INTEGRAL";

export type ModoAtendimento = "ENTREGA_EM_SALA" | "RETIRADA_BALCAO";

export type StatusReserva =
  | "LISTA_ESPERA" | "CONFIRMADA" | "EM_SEPARACAO" | "ENTREGUE"
  | "DEVOLVIDA" | "ATRASADA" | "CANCELADA" | "NAO_COMPARECEU";

export type TipoTarefa = "ENTREGA" | "COLETA" | "TRANSFERENCIA";
export type StatusTarefa = "PENDENTE" | "EM_ANDAMENTO" | "CONCLUIDA" | "CANCELADA";

/** Uma linha de `agenda_do_dia()`. */
export interface LinhaAgenda {
  horario_id: string;
  rotulo: string;
  turno: Turno;
  inicio: string;
  fim: string;
  eh_intervalo: boolean;
  capacidade: number;
  reservado: number;
  disponivel: number;
  tem_estagiario: boolean;
}

/** Uma linha de `fila_do_dia()`. */
export interface LinhaFila {
  tarefa_id: string;
  tipo: TipoTarefa;
  hora: string;
  quantidade: number;
  origem: string;
  destino: string;
  professor: string | null;
  turma: string | null;
  status: StatusTarefa;
  observacao: string | null;
}

export interface Pool {
  id: string;
  nome: string;
  tipo: string;
  quantidade_total: number;
  unidade_id: string;
  unidade: { nome: string; sigla: string; ponto_apoio: string | null } | null;
}

export interface ReservaResumo {
  id: string;
  data: string;
  quantidade: number;
  status: StatusReserva;
  modo: ModoAtendimento;
  turma_texto: string | null;
  horario: { rotulo: string; inicio: string; fim: string } | null;
  pool: { nome: string } | null;
  turma: { nome: string } | null;
}
