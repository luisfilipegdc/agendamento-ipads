import { criaClienteServidor } from "@/lib/supabase-server";
import { Cabecalho } from "@/componentes/Cabecalho";
import { ConfiguracaoPendente } from "@/componentes/ConfiguracaoPendente";
import { configurado } from "@/lib/config";
import { GradeAgenda } from "./GradeAgenda";
import type { LinhaAgenda } from "@/lib/tipos";

function hoje(): string {
  return new Date().toLocaleDateString("en-CA", {
    timeZone: "America/Sao_Paulo",
  });
}

export default async function Agenda({
  searchParams,
}: {
  searchParams: Promise<{ pool?: string; data?: string }>;
}) {
  if (!configurado()) return <ConfiguracaoPendente />;

  const sp = await searchParams;
  const supabase = await criaClienteServidor();

  const { data: pools } = await supabase
    .from("pool")
    .select("id, nome, tipo, quantidade_total, unidade_id, unidade(nome, sigla, ponto_apoio)")
    .eq("ativo", true)
    .order("nome");

  const lista = pools ?? [];
  const poolId = sp.pool && lista.some((p) => p.id === sp.pool)
    ? sp.pool
    : lista[0]?.id;
  const data = sp.data ?? hoje();

  if (!poolId) {
    return (
      <>
        <Cabecalho atual="/agenda" />
        <div className="container">
          <div className="vazio">
            Nenhuma frota disponível para o seu usuário.
            <br />
            Procure a coordenação.
          </div>
        </div>
      </>
    );
  }

  const { data: linhas, error } = await supabase
    .rpc("agenda_do_dia", { p_pool: poolId, p_data: data });

  const { data: turmas } = await supabase
    .from("turma")
    .select("id, nome, segmento(unidade_id)")
    .order("nome");

  const pool = lista.find((p) => p.id === poolId)!;
  const turmasDaUnidade = (turmas ?? []).filter(
    (t) => (t.segmento as unknown as { unidade_id: string } | null)
      ?.unidade_id === pool.unidade_id,
  );

  return (
    <>
      <Cabecalho atual="/agenda" />
      <div className="container">
        <h1>Agenda</h1>
        <p className="subtitulo">
          O saldo de cada horário é calculado na hora. Se aparece disponível,
          a reserva é aceita.
        </p>

        <GradeAgenda
          pools={lista.map((p) => ({
            id: p.id,
            nome: p.nome,
            quantidade_total: p.quantidade_total,
            unidade_nome:
              (p.unidade as unknown as { nome: string } | null)?.nome ?? "",
            ponto_apoio:
              (p.unidade as unknown as { ponto_apoio: string | null } | null)
                ?.ponto_apoio ?? null,
          }))}
          poolId={poolId}
          data={data}
          linhas={(linhas ?? []) as LinhaAgenda[]}
          erro={error?.message ?? null}
          turmas={turmasDaUnidade.map((t) => ({ id: t.id, nome: t.nome }))}
        />
      </div>
    </>
  );
}
