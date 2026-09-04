"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { criaClienteNavegador } from "@/lib/supabase-browser";

interface Aviso {
  id: string;
  assunto: string;
  corpo: string;
  agendada_para: string;
  lida_em: string | null;
}

function quando(iso: string): string {
  return new Date(iso).toLocaleString("pt-BR", {
    timeZone: "America/Sao_Paulo",
    day: "2-digit", month: "2-digit", hour: "2-digit", minute: "2-digit",
  });
}

export function ListaAvisos({ avisos }: { avisos: Aviso[] }) {
  const router = useRouter();
  const [, iniciar] = useTransition();
  const [ocupado, setOcupado] = useState(false);

  const naoLidos = avisos.filter((a) => !a.lida_em).length;

  async function marcarTodos() {
    setOcupado(true);
    await criaClienteNavegador().rpc("marca_todos_avisos_lidos");
    setOcupado(false);
    iniciar(() => router.refresh());
  }

  async function marcarUm(id: string) {
    await criaClienteNavegador().rpc("marca_aviso_lido", { p_id: id });
    iniciar(() => router.refresh());
  }

  if (avisos.length === 0) {
    return (
      <div className="painel">
        <div className="vazio">Nenhum aviso por enquanto.</div>
      </div>
    );
  }

  return (
    <>
      {naoLidos > 0 && (
        <div style={{ marginBottom: 12 }}>
          <button onClick={marcarTodos} disabled={ocupado}>
            Marcar {naoLidos} como lido{naoLidos > 1 ? "s" : ""}
          </button>
        </div>
      )}

      {avisos.map((a) => (
        <div
          key={a.id}
          className="painel"
          style={{
            marginBottom: 8,
            borderLeft: a.lida_em ? undefined : "3px solid var(--acento)",
          }}
        >
          <div style={{
            display: "flex", justifyContent: "space-between",
            alignItems: "baseline", gap: 12,
          }}>
            <strong style={{ fontSize: 15 }}>{a.assunto}</strong>
            <span style={{ color: "var(--suave)", fontSize: 12, flexShrink: 0 }}>
              {quando(a.agendada_para)}
            </span>
          </div>
          <p style={{
            margin: "6px 0 0", fontSize: 14, whiteSpace: "pre-line",
            color: "var(--suave)",
          }}>
            {a.corpo}
          </p>
          {!a.lida_em && (
            <button
              onClick={() => marcarUm(a.id)}
              style={{
                border: "none", background: "none", padding: "8px 0 0",
                color: "var(--acento)", fontSize: 13, textDecoration: "underline",
              }}
            >
              marcar como lido
            </button>
          )}
        </div>
      ))}
    </>
  );
}
