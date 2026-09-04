"use client";

import { Fragment, useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { criaClienteNavegador } from "@/lib/supabase-browser";
import type { LinhaFila } from "@/lib/tipos";

interface Props {
  unidades: { id: string; nome: string; ponto_apoio: string | null }[];
  unidadeId: string;
  data: string;
  tarefas: LinhaFila[];
  erro: string | null;
}

const ROTULO: Record<string, string> = {
  ENTREGA: "Levar",
  COLETA: "Buscar",
  TRANSFERENCIA: "Transferir",
};

export function ListaFila(
  { unidades, unidadeId, data, tarefas, erro }: Props,
) {
  const router = useRouter();
  const [, iniciar] = useTransition();
  const [conferindo, setConferindo] = useState<string | null>(null);
  const [qtd, setQtd] = useState("");
  const [ocupado, setOcupado] = useState<string | null>(null);
  const [falha, setFalha] = useState<string | null>(null);

  function navega(p: Record<string, string>) {
    const q = new URLSearchParams({ unidade: unidadeId, data, ...p });
    iniciar(() => router.push(`/fila?${q}`));
  }

  /** ENTREGA e TRANSFERENCIA: marca como feita e a reserva como ENTREGUE. */
  async function concluirEntrega(t: LinhaFila) {
    setOcupado(t.tarefa_id);
    setFalha(null);
    const supabase = criaClienteNavegador();
    const { data: sessao } = await supabase.auth.getUser();

    const { error } = await supabase
      .from("tarefa")
      .update({
        status: "CONCLUIDA",
        concluida_em: new Date().toISOString(),
        responsavel_id: sessao.user?.id ?? null,
      })
      .eq("id", t.tarefa_id);

    setOcupado(null);
    if (error) { setFalha(error.message); return; }
    iniciar(() => router.refresh());
  }

  /** COLETA: exige a quantidade conferida — é onde a falta é detectada. */
  async function confirmarDevolucao(t: LinhaFila) {
    setOcupado(t.tarefa_id);
    setFalha(null);
    const supabase = criaClienteNavegador();
    const { data: sessao } = await supabase.auth.getUser();

    const { error } = await supabase.rpc("confere_devolucao", {
      p_tarefa: t.tarefa_id,
      p_qtd_conferida: Number(qtd),
      p_por: sessao.user?.id ?? null,
      p_obs: null,
    });

    setOcupado(null);
    if (error) { setFalha(error.message); return; }
    setConferindo(null);
    iniciar(() => router.refresh());
  }

  const pendentes = tarefas.filter((t) => t.status === "PENDENTE");
  const feitas = tarefas.filter((t) => t.status !== "PENDENTE");

  return (
    <>
      <div className="painel">
        <div className="filtros">
          <div className="campo">
            <label htmlFor="unidade">Unidade</label>
            <select
              id="unidade"
              value={unidadeId}
              onChange={(e) => navega({ unidade: e.target.value })}
            >
              {unidades.map((u) => (
                <option key={u.id} value={u.id}>{u.nome}</option>
              ))}
            </select>
          </div>
          <div className="campo">
            <label htmlFor="data">Data</label>
            <input
              id="data"
              type="date"
              value={data}
              onChange={(e) => navega({ data: e.target.value })}
            />
          </div>
        </div>
      </div>

      {erro && <div className="aviso erro">{erro}</div>}
      {falha && <div className="aviso erro">{falha}</div>}

      <div className="painel">
        <p style={{ margin: "0 0 12px", fontWeight: 600 }}>
          {pendentes.length === 0
            ? "Nada pendente"
            : `${pendentes.length} tarefa${pendentes.length > 1 ? "s" : ""} pendente${pendentes.length > 1 ? "s" : ""}`}
        </p>

        {pendentes.length === 0 && feitas.length === 0 && (
          <div className="vazio">Nenhuma tarefa para esta data.</div>
        )}

        {pendentes.length > 0 && (
          <table>
            <thead>
              <tr>
                <th>Hora</th>
                <th>O quê</th>
                <th>Trajeto</th>
                <th className="esconde-movel">Quem</th>
                <th />
              </tr>
            </thead>
            <tbody>
              {pendentes.map((t) => (
                <Fragment key={t.tarefa_id}>
                  <tr>
                    <td style={{ fontVariantNumeric: "tabular-nums" }}>
                      {t.hora.slice(0, 5)}
                    </td>
                    <td>
                      <span
                        className={`etiqueta ${
                          t.tipo === "TRANSFERENCIA" ? "alerta" : "neutra"
                        }`}
                      >
                        {ROTULO[t.tipo]}
                      </span>{" "}
                      {t.quantidade} un.
                    </td>
                    <td>
                      {t.origem} <span style={{ color: "var(--suave)" }}>→</span>{" "}
                      {t.destino}
                    </td>
                    <td className="esconde-movel">
                      {t.professor}
                      {t.turma && (
                        <span style={{ color: "var(--suave)" }}> · {t.turma}</span>
                      )}
                    </td>
                    <td style={{ textAlign: "right" }}>
                      {t.tipo === "COLETA" ? (
                        <button
                          onClick={() => {
                            setConferindo(
                              conferindo === t.tarefa_id ? null : t.tarefa_id,
                            );
                            setQtd(String(t.quantidade));
                          }}
                        >
                          Conferir devolução
                        </button>
                      ) : (
                        <button
                          className="primario"
                          onClick={() => concluirEntrega(t)}
                          disabled={ocupado === t.tarefa_id}
                        >
                          {ocupado === t.tarefa_id ? "…" : "Feito"}
                        </button>
                      )}
                    </td>
                  </tr>

                  {conferindo === t.tarefa_id && (
                    <tr>
                      <td colSpan={5} style={{ background: "#fafafa" }}>
                        <div className="filtros">
                          <div className="campo">
                            <label htmlFor={`q-${t.tarefa_id}`}>
                              Quantos voltaram? (saíram {t.quantidade})
                            </label>
                            <input
                              id={`q-${t.tarefa_id}`}
                              type="number"
                              min={0}
                              max={t.quantidade}
                              value={qtd}
                              onChange={(e) => setQtd(e.target.value)}
                              style={{ width: 90 }}
                            />
                          </div>
                          <button
                            className="primario"
                            onClick={() => confirmarDevolucao(t)}
                            disabled={ocupado === t.tarefa_id || qtd === ""}
                          >
                            {ocupado === t.tarefa_id ? "…" : "Confirmar"}
                          </button>
                          {Number(qtd) < t.quantidade && (
                            <span style={{ color: "var(--erro)", fontSize: 13 }}>
                              Faltam {t.quantidade - Number(qtd)} — será aberta
                              uma ocorrência.
                            </span>
                          )}
                        </div>
                      </td>
                    </tr>
                  )}
                </Fragment>
              ))}
            </tbody>
          </table>
        )}
      </div>

      {feitas.length > 0 && (
        <div className="painel">
          <p style={{ margin: "0 0 12px", color: "var(--suave)", fontSize: 13 }}>
            Concluídas hoje ({feitas.length})
          </p>
          <table>
            <tbody>
              {feitas.map((t) => (
                <tr key={t.tarefa_id} style={{ color: "var(--suave)" }}>
                  <td>{t.hora.slice(0, 5)}</td>
                  <td>{ROTULO[t.tipo]} {t.quantidade} un.</td>
                  <td>{t.origem} → {t.destino}</td>
                  <td>{t.professor}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </>
  );
}
