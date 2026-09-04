import { redirect } from "next/navigation";
import { criaClienteServidor } from "@/lib/supabase-server";
import { ConfiguracaoPendente } from "@/componentes/ConfiguracaoPendente";
import { configurado } from "@/lib/config";
import { EscolhaUnidade } from "./EscolhaUnidade";

export default async function Unidade() {
  if (!configurado()) return <ConfiguracaoPendente />;

  const supabase = await criaClienteServidor();

  const { data: perfil } = await supabase.rpc("meu_perfil").single();

  // Já tem unidade (ou é ADMIN): não há o que escolher.
  if (perfil && !(perfil as { precisa_escolher_unidade: boolean })
        .precisa_escolher_unidade) {
    redirect("/agenda");
  }

  const { data: unidades } = await supabase.rpc("unidades_disponiveis");

  return (
    <EscolhaUnidade
      unidades={(unidades ?? []) as { id: string; nome: string; sigla: string }[]}
    />
  );
}
