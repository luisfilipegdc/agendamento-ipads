import { createServerClient } from "@supabase/ssr";
import { NextResponse, type NextRequest } from "next/server";

const PUBLICAS = ["/login", "/auth"];

export async function middleware(req: NextRequest) {
  let res = NextResponse.next({ request: req });

  const supabase = createServerClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
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

  return res;
}

export const config = {
  matcher: ["/((?!_next/static|_next/image|favicon.ico|.*\\.(?:svg|png|jpg)$).*)"],
};
