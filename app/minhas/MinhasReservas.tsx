"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { criaClienteNavegador } from "@/lib/supabase-browser";
import type { ReservaResumo, StatusReserva } from "@/lib/tipos";

const ESTILO: Record<StatusReserva, string> = {
  CONFIRMADA: "ok",
  EM_SEPARACAO: "neutra",
  ENTREGUE: "ok",
  DEVOLVIDA: "neutra",
  ATRASADA: "erro",
  LISTA_ESPERA: "alerta",
  NAO_COMPARECEU: "erro",
  CANCELADA: "neutra",
};

const TEXTO: Record<StatusReserva, string> = {
  CONFIRMADA: "confirmada",
  EM_SEPARACAO: "em separação",
  ENTREGUE: "com você",
  DEVOLVIDA: "devolvida",
  ATRASADA: "devolução atrasada",
  LISTA_ESPERA: "lista de espera",
  NAO_COMPARECEU: "não compareceu",
  CANCELADA: "cancelada",
};

function formata(iso: string): string {
  const [a, m, d] = iso.split("-");
  return `${d}/${m}/${a}`;
}

export function MinhasReservas({ reservas }: { reservas: ReservaResumo[] }) {
  const router = useRouter();
  const [, iniciar] = useTransition();
  const [ocupado, setOcupado] = useState<string | null>(null);
  const [falha, setFalha] = useState<string | null>(null);

  async function cancelar(id: string) {
    if (!confirm("Cancelar esta reserva? A vaga volta para os outros professores."))
      return;

    setOcupado(id);
    setFalha(null);
    const { error } = await criaClienteNavegador()
      .from("reserva")
      .update({ status: "CANCELADA" })
      .eq("id", id);

    setOcupado(null);
    if (error) { setFalha(error.message); return; }
    iniciar(() => router.refresh());
  }

  if (reservas.length === 0) {
    return <div className="painel"><div className="vazio">
      Você não tem reservas. Vá em <strong>Agenda</strong> para criar uma.
    </div></div>;
  }

  const hoje = new Date().toLocaleDateString("en-CA", {
    timeZone: "America/Sao_Paulo",
  });

  return (
    <>
      {falha && <div className="aviso erro">{falha}</div>}
      <div className="painel">
        <table>
          <thead>
            <tr>
              <th>Data</th>
              <th>Horário</th>
              <th className="esconde-movel">Frota</th>
              <th>Turma</th>
              <th>Qtd</th>
              <th>Situação</th>
              <th />
            </tr>
          </thead>
          <tbody>
            {reservas.map((r) => {
              const futura = r.data >= hoje;
              const cancelavel = futura &&
                (r.status === "CONFIRMADA" || r.status === "LISTA_ESPERA");

              return (
                <tr key={r.id} style={futura ? undefined : { color: "var(--suave)" }}>
                  <td>{formata(r.data)}</td>
                  <td>{r.horario?.rotulo ?? "—"}</td>
                  <td className="esconde-movel">{r.pool?.nome ?? "—"}</td>
                  <td>{r.turma?.nome ?? r.turma_texto ?? "—"}</td>
                  <td>{r.quantidade}</td>
                  <td>
                    <span className={`etiqueta ${ESTILO[r.status]}`}>
                      {TEXTO[r.status]}
                    </span>
                    {r.modo === "RETIRADA_BALCAO" && (
                      <div style={{ fontSize: 12, color: "var(--alerta)", marginTop: 2 }}>
                        retirar no balcão
                      </div>
                    )}
                  </td>
                  <td style={{ textAlign: "right" }}>
                    {cancelavel && (
                      <button
                        onClick={() => cancelar(r.id)}
                        disabled={ocupado === r.id}
                      >
                        {ocupado === r.id ? "…" : "Cancelar"}
                      </button>
                    )}
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>
    </>
  );
}
