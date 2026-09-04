/**
 * Mostrado quando faltam as variáveis de ambiente do Supabase.
 * Um 500 opaco obriga a caçar log; esta tela nomeia o que falta e onde põe.
 */
export function ConfiguracaoPendente() {
  const temUrl = Boolean(
    process.env.NEXT_PUBLIC_SUPABASE_URL || process.env.SUPABASE_URL,
  );
  const temChave = Boolean(
    process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY ||
      process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY,
  );

  const faltando = [
    ...(temUrl ? [] : ["NEXT_PUBLIC_SUPABASE_URL"]),
    ...(temChave ? [] : ["NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY"]),
  ];

  return (
    <div className="container" style={{ maxWidth: 560, paddingTop: 48 }}>
      <div className="painel">
        <h1>Configuração pendente</h1>
        <p className="subtitulo">
          O aplicativo subiu, mas ainda não sabe onde fica o banco de dados.
        </p>

        <p style={{ fontSize: 14, marginBottom: 8 }}>
          {faltando.length === 2
            ? "Faltam as duas variáveis de ambiente:"
            : "Falta esta variável de ambiente:"}
        </p>

        <ul style={{ fontSize: 14, lineHeight: 1.8, marginTop: 0 }}>
          {faltando.map((v) => (
            <li key={v}>
              <code style={{
                background: "#f4f4f5", padding: "2px 6px", borderRadius: 4,
              }}>
                {v}
              </code>
            </li>
          ))}
        </ul>

        <div className="aviso alerta">
          Na Vercel: <strong>Settings → Environment Variables</strong>. Marque
          o ambiente <strong>Production</strong> e faça um novo deploy — variáveis
          novas só valem para builds seguintes.
        </div>

        <p style={{ fontSize: 13, color: "var(--suave)", marginBottom: 0 }}>
          Os valores estão no Supabase, em Settings → API Keys. Use a chave
          <strong> publicável</strong> (<code>sb_publishable_…</code>), nunca a
          secreta: a secreta ignora todas as regras de acesso do banco.
        </p>
      </div>
    </div>
  );
}
