import { criaClienteServidor } from "@/lib/supabase-server";
import { Cabecalho } from "@/componentes/Cabecalho";
import { ConfiguracaoPendente } from "@/componentes/ConfiguracaoPendente";
import { configurado } from "@/lib/config";
import { ListaFila } from "./ListaFila";
import type { LinhaFila } from "@/lib/tipos";

function hoje(): string {
  return new Date().toLocaleDateString("en-CA", {
    timeZone: "America/Sao_Paulo",
  });
}

export default async function Fila({
  searchParams,
}: {
  searchParams: Promise<{ unidade?: string; data?: string }>;
}) {
  if (!configurado()) return <ConfiguracaoPendente />;

  const sp = await searchParams;
  const supabase = await criaClienteServidor();

  const { data: unidades } = await supabase
    .from("unidade")
    .select("id, nome, ponto_apoio")
    .eq("ativo", true)
    .order("nome");

  const lista = unidades ?? [];
  const unidadeId = sp.unidade && lista.some((u) => u.id === sp.unidade)
    ? sp.unidade
    : lista[0]?.id;
  const data = sp.data ?? hoje();

  if (!unidadeId) {
    return (
      <>
        <Cabecalho atual="/fila" />
        <div className="container">
          <div className="vazio">Nenhuma unidade disponível.</div>
        </div>
      </>
    );
  }

  const { data: tarefas, error } = await supabase
    .rpc("fila_do_dia", { p_unidade: unidadeId, p_data: data });

  return (
    <>
      <Cabecalho atual="/fila" />
      <div className="container">
        <h1>Fila do dia</h1>
        <p className="subtitulo">
          Marque cada tarefa conforme executa. Transferências vão direto de uma
          sala para a outra, sem passar pelo depósito.
        </p>

        <ListaFila
          unidades={lista}
          unidadeId={unidadeId}
          data={data}
          tarefas={(tarefas ?? []) as LinhaFila[]}
          erro={error?.message ?? null}
        />
      </div>
    </>
  );
}
