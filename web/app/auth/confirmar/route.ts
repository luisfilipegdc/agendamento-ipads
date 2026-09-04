import { NextResponse, type NextRequest } from "next/server";
import { criaClienteServidor } from "@/lib/supabase-server";

/** Callback do magic link: troca o código pela sessão. */
export async function GET(req: NextRequest) {
  const { searchParams, origin } = new URL(req.url);
  const code = searchParams.get("code");
  const destino = searchParams.get("de") ?? "/agenda";

  if (!code) {
    return NextResponse.redirect(`${origin}/login?erro=link_invalido`);
  }

  const supabase = await criaClienteServidor();
  const { error } = await supabase.auth.exchangeCodeForSession(code);

  if (error) {
    return NextResponse.redirect(
      `${origin}/login?erro=${encodeURIComponent(error.message)}`,
    );
  }

  // Só caminhos internos: um `de` externo viraria redirecionamento aberto.
  const seguro = destino.startsWith("/") && !destino.startsWith("//")
    ? destino
    : "/agenda";

  return NextResponse.redirect(`${origin}${seguro}`);
}
