import Link from "next/link";
import { criaClienteServidor } from "@/lib/supabase-server";
import { Sair } from "./Sair";

export async function Cabecalho({ atual }: { atual: string }) {
  const supabase = await criaClienteServidor();
  const { data: { user } } = await supabase.auth.getUser();

  const { data: perfil } = await supabase
    .from("pessoa")
    .select("nome, pessoa_papel(papel)")
    .eq("id", user?.id ?? "")
    .single();

  const papeis = new Set(
    (perfil?.pessoa_papel as { papel: string }[] | null)?.map((p) => p.papel) ?? [],
  );
  const operacional = papeis.has("ESTAGIARIO") || papeis.has("COORDENACAO") ||
    papeis.has("ADMIN");

  const { count: naoLidos } = await supabase
    .from("notificacao")
    .select("id", { count: "exact", head: true })
    .eq("destinatario_id", user?.id ?? "")
    .is("lida_em", null)
    .lte("agendada_para", new Date().toISOString());

  const itens = [
    { href: "/agenda", texto: "Agenda" },
    { href: "/minhas", texto: "Minhas reservas" },
    ...(operacional ? [{ href: "/fila", texto: "Fila do dia" }] : []),
    {
      href: "/avisos",
      texto: naoLidos ? `Avisos (${naoLidos})` : "Avisos",
    },
  ];

  return (
    <header className="cabecalho">
      <nav>
        {itens.map((i) => (
          <Link
            key={i.href}
            href={i.href}
            aria-current={atual === i.href ? "page" : undefined}
          >
            {i.texto}
          </Link>
        ))}
      </nav>
      <span className="quem">
        {perfil?.nome ?? user?.email} <Sair />
      </span>
    </header>
  );
}
