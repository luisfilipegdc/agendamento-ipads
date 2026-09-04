"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { criaClienteNavegador } from "@/lib/supabase-browser";

export function EscolhaUnidade(
  { unidades }: { unidades: { id: string; nome: string; sigla: string }[] },
) {
  const router = useRouter();
  const [escolhida, setEscolhida] = useState<string | null>(null);
  const [salvando, setSalvando] = useState(false);
  const [erro, setErro] = useState<string | null>(null);

  async function confirmar() {
    if (!escolhida) return;
    setSalvando(true);
    setErro(null);

    const { error } = await criaClienteNavegador()
      .rpc("define_minha_unidade", { p_unidade: escolhida });

    if (error) {
      setErro(error.message);
      setSalvando(false);
      return;
    }

    router.push("/agenda");
    router.refresh();
  }

  return (
    <div className="container" style={{ maxWidth: 460, paddingTop: 56 }}>
      <div className="painel">
        <h1>Em qual unidade você trabalha?</h1>
        <p className="subtitulo">
          Precisamos disso para mostrar a agenda e os equipamentos certos. A
          coordenação pode alterar depois.
        </p>

        {erro && <div className="aviso erro">{erro}</div>}

        <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
          {unidades.map((u) => (
            <label
              key={u.id}
              style={{
                display: "flex", alignItems: "center", gap: 10, padding: "12px 14px",
                border: `1px solid ${
                  escolhida === u.id ? "var(--acento)" : "var(--borda)"
                }`,
                borderRadius: 6, cursor: "pointer",
                background: escolhida === u.id ? "#f0f7ff" : "transparent",
              }}
            >
              <input
                type="radio"
                name="unidade"
                value={u.id}
                checked={escolhida === u.id}
                onChange={() => setEscolhida(u.id)}
                style={{ margin: 0, width: "auto" }}
              />
              <span style={{ fontWeight: 500 }}>{u.nome}</span>
            </label>
          ))}
        </div>

        <button
          className="primario"
          onClick={confirmar}
          disabled={!escolhida || salvando}
          style={{ marginTop: 16 }}
        >
          {salvando ? "Salvando…" : "Continuar"}
        </button>
      </div>
    </div>
  );
}
