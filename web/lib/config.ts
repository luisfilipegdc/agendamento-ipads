/**
 * Configuração do Supabase.
 *
 * O Supabase renomeou as chaves: `anon` virou `publishable` (sb_publishable_…).
 * As duas funcionam, e a integração da Vercel injeta nomes diferentes dependendo
 * de como o projeto foi conectado. Aceitamos ambos para não travar o deploy por
 * causa do nome de uma variável.
 */

function exigido(nomes: string[], valores: (string | undefined)[]): string {
  const achado = valores.find((v) => v && v.length > 0);
  if (!achado) {
    throw new Error(
      `Variável de ambiente ausente. Defina uma destas: ${nomes.join(", ")}`,
    );
  }
  return achado;
}

export const SUPABASE_URL = exigido(
  ["NEXT_PUBLIC_SUPABASE_URL"],
  [
    process.env.NEXT_PUBLIC_SUPABASE_URL,
    process.env.SUPABASE_URL,
  ],
);

export const SUPABASE_CHAVE_PUBLICA = exigido(
  ["NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY", "NEXT_PUBLIC_SUPABASE_ANON_KEY"],
  [
    process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY,
    process.env.SUPABASE_PUBLISHABLE_KEY,
    process.env.SUPABASE_ANON_KEY,
  ],
);
