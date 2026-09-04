import { criaClienteServidor } from "@/lib/supabase-server";
import { Cabecalho } from "@/componentes/Cabecalho";
import { MinhasReservas } from "./MinhasReservas";
import type { ReservaResumo } from "@/lib/tipos";

export default async function Minhas() {
  const supabase = await criaClienteServidor();
  const { data: { user } } = await supabase.auth.getUser();

  const { data, error } = await supabase
    .from("reserva")
    .select(
      "id, data, quantidade, status, modo, turma_texto," +
      " horario(rotulo, inicio, fim), pool(nome), turma(nome)",
    )
    .eq("professor_id", user?.id ?? "")
    .neq("status", "CANCELADA")
    .gte("data", new Date(Date.now() - 7 * 864e5).toISOString().slice(0, 10))
    .order("data", { ascending: true })
    .limit(100);

  return (
    <>
      <Cabecalho atual="/minhas" />
      <div className="container">
        <h1>Minhas reservas</h1>
        <p className="subtitulo">
          Últimos 7 dias e tudo que está por vir.
        </p>
        {error && <div className="aviso erro">{error.message}</div>}
        <MinhasReservas
          reservas={(data ?? []) as unknown as ReservaResumo[]}
        />
      </div>
    </>
  );
}
