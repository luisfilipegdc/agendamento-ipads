"use client";

import { useEffect } from "react";

/** Rede de segurança: mostra a causa em vez de um 500 sem explicação. */
export default function Erro({
  error,
  reset,
}: {
  error: Error & { digest?: string };
  reset: () => void;
}) {
  useEffect(() => {
    console.error(error);
  }, [error]);

  const configuracao = /Configuração ausente|variáveis de ambiente/i
    .test(error.message);

  return (
    <div className="container" style={{ maxWidth: 560, paddingTop: 48 }}>
      <div className="painel">
        <h1>{configuracao ? "Configuração pendente" : "Algo deu errado"}</h1>
        <p className="subtitulo">
          {configuracao
            ? "O aplicativo não conseguiu se conectar ao banco de dados."
            : "A página não pôde ser carregada."}
        </p>

        {error.message && (
          <pre style={{
            background: "#f4f4f5", padding: 12, borderRadius: 6,
            fontSize: 13, whiteSpace: "pre-wrap", overflowX: "auto",
          }}>
            {error.message}
          </pre>
        )}

        {error.digest && (
          <p style={{ fontSize: 12, color: "var(--suave)" }}>
            Código: {error.digest}
          </p>
        )}

        <button className="primario" onClick={reset}>Tentar de novo</button>
      </div>
    </div>
  );
}
