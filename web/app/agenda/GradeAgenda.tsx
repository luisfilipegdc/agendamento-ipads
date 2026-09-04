"use client";

import { Fragment, useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { criaClienteNavegador } from "@/lib/supabase-browser";
import type { LinhaAgenda } from "@/lib/tipos";

interface PoolItem {
  id: string;
  nome: string;
  quantidade_total: number;
  unidade_nome: string;
  ponto_apoio: string | null;
}

interface Props {
  pools: PoolItem[];
  poolId: string;
  data: string;
  linhas: LinhaAgenda[];
  erro: string | null;
  turmas: { id: string; nome: string }[];
}

/** Traduz o erro cru do Postgres para algo acionável pelo professor. */
function humaniza(msg: string): string {
  if (/saldo insuficiente/i.test(msg)) return msg;
  if (/antecedência/i.test(msg)) return msg;
  if (/duplicat|reserva_sem_duplicata/i.test(msg)) {
    return "Você já tem uma reserva desta frota neste horário.";
  }
  if (/row-level security|permission denied/i.test(msg)) {
    return "Você não tem permissão para agendar nesta frota.";
  }
  return msg;
}

export function GradeAgenda(
  { pools, poolId, data, linhas, erro, turmas }: Props,
) {
  const router = useRouter();
  const [pendente, iniciar] = useTransition();
  const [abertoEm, setAbertoEm] = useState<string | null>(null);
  const [quantidade, setQuantidade] = useState("");
  const [turmaId, setTurmaId] = useState("");
  const [turmaTexto, setTurmaTexto] = useState("");
  const [salvando, setSalvando] = useState(false);
  const [falha, setFalha] = useState<string | null>(null);
  const [sucesso, setSucesso] = useState<string | null>(null);

  const pool = pools.find((p) => p.id === poolId)!;

  function navega(p: Record<string, string>) {
    const q = new URLSearchParams({ pool: poolId, data, ...p });
    iniciar(() => router.push(`/agenda?${q}`));
  }

  function moveDia(dias: number) {
    const d = new Date(`${data}T12:00:00`);
    d.setDate(d.getDate() + dias);
    navega({ data: d.toLocaleDateString("en-CA") });
  }

  function abrir(l: LinhaAgenda) {
    setAbertoEm(l.horario_id);
    setQuantidade(String(Math.min(l.disponivel, pool.quantidade_total)));
    setTurmaId("");
    setTurmaTexto("");
    setFalha(null);
    setSucesso(null);
  }

  async function reservar(l: LinhaAgenda) {
    setSalvando(true);
    setFalha(null);
    const supabase = criaClienteNavegador();

    const { data: sessao } = await supabase.auth.getUser();
    if (!sessao.user) {
      setFalha("Sessão expirada. Entre novamente.");
      setSalvando(false);
      return;
    }

    const { error } = await supabase.from("reserva").insert({
      pool_id: poolId,
      horario_id: l.horario_id,
      data,
      professor_id: sessao.user.id,
      quantidade: Number(quantidade),
      ...(turmaId ? { turma_id: turmaId } : { turma_texto: turmaTexto.trim() }),
    });

    setSalvando(false);

    if (error) {
      setFalha(humaniza(error.message));
      return;
    }

    setAbertoEm(null);
    setSucesso(
      l.tem_estagiario
        ? `Reservado para ${l.rotulo}. A estagiária levará os equipamentos até a sala.`
        : `Reservado para ${l.rotulo}. Neste horário não há estagiário — ` +
          `retire e devolva em ${pool.ponto_apoio ?? "Coordenação"}.`,
    );
    iniciar(() => router.refresh());
  }

  const porTurno = linhas.reduce<Record<string, LinhaAgenda[]>>((acc, l) => {
    (acc[l.turno] ??= []).push(l);
    return acc;
  }, {});

  const diaSemana = new Date(`${data}T12:00:00`).toLocaleDateString("pt-BR", {
    weekday: "long", day: "2-digit", month: "long",
  });

  return (
    <>
      <div className="painel">
        <div className="filtros">
          <div className="campo">
            <label htmlFor="pool">Frota</label>
            <select
              id="pool"
              value={poolId}
              onChange={(e) => navega({ pool: e.target.value })}
            >
              {pools.map((p) => (
                <option key={p.id} value={p.id}>
                  {p.unidade_nome} — {p.nome} ({p.quantidade_total})
                </option>
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

          <button onClick={() => moveDia(-1)} disabled={pendente}>‹ Dia anterior</button>
          <button onClick={() => moveDia(1)} disabled={pendente}>Próximo dia ›</button>
        </div>
      </div>

      {sucesso && <div className="aviso ok">{sucesso}</div>}
      {erro && <div className="aviso erro">{erro}</div>}

      <div className="painel">
        <p style={{ margin: "0 0 12px", fontWeight: 600, textTransform: "capitalize" }}>
          {diaSemana}
        </p>

        {linhas.length === 0 && (
          <div className="vazio">
            Não há aula nesta data — feriado, recesso ou dia sem grade.
          </div>
        )}

        {Object.entries(porTurno).map(([turno, lista]) => (
          <div key={turno}>
            <div className="turno">{turno}</div>
            <table>
              <thead>
                <tr>
                  <th>Horário</th>
                  <th>Disponível</th>
                  <th className="esconde-movel">Apoio</th>
                  <th />
                </tr>
              </thead>
              <tbody>
                {lista.map((l) => {
                  const pct = l.capacidade === 0
                    ? 0
                    : (l.reservado / l.capacidade) * 100;
                  const lotado = l.disponivel <= 0;

                  return (
                    <Fragment key={l.horario_id}>
                      <tr className={l.eh_intervalo ? "intervalo" : ""}>
                        <td>{l.rotulo}</td>
                        <td>
                          {l.eh_intervalo ? (
                            "—"
                          ) : (
                            <>
                              <span className={`medidor${lotado ? " cheio" : ""}`}>
                                <span style={{ width: `${pct}%` }} />
                              </span>
                              <strong>{l.disponivel}</strong>
                              <span style={{ color: "var(--suave)" }}>
                                {" "}/ {l.capacidade}
                              </span>
                            </>
                          )}
                        </td>
                        <td className="esconde-movel">
                          {l.eh_intervalo ? null : l.tem_estagiario ? (
                            <span className="etiqueta ok">entrega em sala</span>
                          ) : (
                            <span className="etiqueta alerta">retirada no balcão</span>
                          )}
                        </td>
                        <td style={{ textAlign: "right" }}>
                          {!l.eh_intervalo && (
                            <button
                              onClick={() =>
                                abertoEm === l.horario_id
                                  ? setAbertoEm(null)
                                  : abrir(l)}
                              disabled={lotado}
                            >
                              {lotado
                                ? "Lotado"
                                : abertoEm === l.horario_id
                                ? "Cancelar"
                                : "Reservar"}
                            </button>
                          )}
                        </td>
                      </tr>

                      {abertoEm === l.horario_id && (
                        <tr>
                          <td colSpan={4} style={{ background: "#fafafa" }}>
                            {!l.tem_estagiario && (
                              <div className="aviso alerta" style={{ marginTop: 0 }}>
                                Neste horário não há estagiário de plantão. Você
                                deve retirar e devolver os equipamentos em{" "}
                                <strong>{pool.ponto_apoio ?? "Coordenação"}</strong>.
                              </div>
                            )}
                            {falha && <div className="aviso erro">{falha}</div>}

                            <div className="filtros">
                              <div className="campo">
                                <label htmlFor="qtd">Quantidade</label>
                                <input
                                  id="qtd"
                                  type="number"
                                  min={1}
                                  max={l.disponivel}
                                  value={quantidade}
                                  onChange={(e) => setQuantidade(e.target.value)}
                                  style={{ width: 90 }}
                                />
                              </div>

                              <div className="campo">
                                <label htmlFor="turma">Turma</label>
                                {turmas.length > 0 ? (
                                  <select
                                    id="turma"
                                    value={turmaId}
                                    onChange={(e) => setTurmaId(e.target.value)}
                                  >
                                    <option value="">Selecione…</option>
                                    {turmas.map((t) => (
                                      <option key={t.id} value={t.id}>{t.nome}</option>
                                    ))}
                                  </select>
                                ) : (
                                  <input
                                    id="turma"
                                    placeholder="Ex.: 2ºD"
                                    value={turmaTexto}
                                    onChange={(e) => setTurmaTexto(e.target.value)}
                                  />
                                )}
                              </div>

                              <button
                                className="primario"
                                onClick={() => reservar(l)}
                                disabled={
                                  salvando ||
                                  !quantidade ||
                                  Number(quantidade) < 1 ||
                                  Number(quantidade) > l.disponivel ||
                                  (!turmaId && !turmaTexto.trim())
                                }
                              >
                                {salvando ? "Reservando…" : "Confirmar reserva"}
                              </button>
                            </div>
                          </td>
                        </tr>
                      )}
                    </Fragment>
                  );
                })}
              </tbody>
            </table>
          </div>
        ))}
      </div>
    </>
  );
}
