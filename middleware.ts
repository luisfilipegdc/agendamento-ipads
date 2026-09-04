import { createServerClient } from "@supabase/ssr";
import { NextResponse, type NextRequest } from "next/server";
import { configurado, supabaseChavePublica, supabaseUrl } from "@/lib/config";

const PUBLICAS = ["/login", "/auth"];
// Alcançáveis por quem ainda não escolheu unidade.
const SEM_UNIDADE = ["/unidade", "/avisos"];

export async function middleware(req: NextRequest) {
  // Sem as variáveis, não há sessão para validar. Deixa passar para que a
  // página mostre o erro de configuração, em vez de virar laço de redirect.
  if (!configurado()) return NextResponse.next({ request: req });

  let res = NextResponse.next({ request: req });

  const supabase = createServerClient(
    supabaseUrl(),
    supabaseChavePublica(),
    {
      cookies: {
        getAll: () => req.cookies.getAll(),
        setAll: (lista) => {
          for (const { name, value } of lista) req.cookies.set(name, value);
          res = NextResponse.next({ request: req });
          for (const { name, value, options } of lista) {
            res.cookies.set(name, value, options);
          }
        },
      },
    },
  );

  // getUser() valida o token no servidor. getSession() apenas lê o cookie e
  // aceitaria um token forjado.
  const { data: { user } } = await supabase.auth.getUser();
  const caminho = req.nextUrl.pathname;

  if (!user && !PUBLICAS.some((p) => caminho.startsWith(p))) {
    const url = req.nextUrl.clone();
    url.pathname = "/login";
    url.searchParams.set("de", caminho);
    return NextResponse.redirect(url);
  }

  if (user && caminho === "/login") {
    const url = req.nextUrl.clone();
    url.pathname = "/agenda";
    url.search = "";
    return NextResponse.redirect(url);
  }

  // As três unidades dividem o mesmo domínio de e-mail, então o primeiro acesso
  // não sabe onde a pessoa trabalha. Sem unidade, o RLS recusaria toda reserva;
  // mandamos escolher antes que ela esbarre nisso.
  if (user && !PUBLICAS.some((p) => caminho.startsWith(p)) &&
      !SEM_UNIDADE.some((p) => caminho.startsWith(p))) {
    const { data: perfil } = await supabase
      .rpc("meu_perfil")
      .single<{ precisa_escolher_unidade: boolean }>();

    if (perfil?.precisa_escolher_unidade) {
      const url = req.nextUrl.clone();
      url.pathname = "/unidade";
      url.search = "";
      return NextResponse.redirect(url);
    }
  }

  return res;
}

export const config = {
  matcher: ["/((?!_next/static|_next/image|favicon.ico|.*\\.(?:svg|png|jpg)$).*)"],
};
