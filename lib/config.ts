/**
 * Configuração do Supabase.
 *
 * O Supabase renomeou as chaves: `anon` virou `publishable` (sb_publishable_…).
 * As duas funcionam, e a integração da Vercel injeta nomes diferentes conforme
 * a forma da conexão. Aceitamos ambos para não travar o deploy pelo nome de
 * uma variável.
 *
 * A validação acontece na hora de criar o cliente, não ao carregar o módulo:
 * um throw no topo do arquivo derruba o `next build` inteiro quando a variável
 * ainda não foi definida, e um deploy vermelho esconde a causa real.
 */

const URL_CANDIDATOS = [
  "NEXT_PUBLIC_SUPABASE_URL",
  "SUPABASE_URL",
] as const;

const CHAVE_CANDIDATOS = [
  "NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY",
  "NEXT_PUBLIC_SUPABASE_ANON_KEY",
] as const;

// O acesso precisa ser literal: o Next substitui `process.env.NOME` em tempo de
// build e uma indexação dinâmica não seria trocada pelo valor no bundle.
function primeiroDefinido(valores: (string | undefined)[]): string | undefined {
  return valores.find((v) => typeof v === "string" && v.length > 0);
}

export function supabaseUrl(): string {
  const v = primeiroDefinido([
    process.env.NEXT_PUBLIC_SUPABASE_URL,
    process.env.SUPABASE_URL,
  ]);
  if (!v) {
    throw new Error(
      `Configuração ausente. Defina uma destas variáveis de ambiente: ` +
        URL_CANDIDATOS.join(", "),
    );
  }
  return v;
}

export function supabaseChavePublica(): string {
  const v = primeiroDefinido([
    process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY,
  ]);
  if (!v) {
    throw new Error(
      `Configuração ausente. Defina uma destas variáveis de ambiente: ` +
        CHAVE_CANDIDATOS.join(", "),
    );
  }
  return v;
}

/** true quando as duas variáveis estão presentes. */
export function configurado(): boolean {
  try {
    supabaseUrl();
    supabaseChavePublica();
    return true;
  } catch {
    return false;
  }
}
