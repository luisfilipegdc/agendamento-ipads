import { criaClienteServidor } from "@/lib/supabase-server";
import { Cabecalho } from "@/componentes/Cabecalho";
import { ListaAvisos } from "./ListaAvisos";

export default async function Avisos() {
  const supabase = await criaClienteServidor();
  const { data, error } = await supabase.rpc("meus_avisos", { p_limite: 50 });

  const { data: config } = await supabase
    .from("config_sistema")
    .select("email_ativo")
    .single();

  return (
    <>
      <Cabecalho atual="/avisos" />
      <div className="container">
        <h1>Avisos</h1>
        <p className="subtitulo">
          {config?.email_ativo
            ? "Estes avisos também são enviados para o seu e-mail."
            : "O envio por e-mail ainda não está configurado — os avisos ficam aqui."}
        </p>
        {error && <div className="aviso erro">{error.message}</div>}
        <ListaAvisos
          avisos={(data ?? []) as {
            id: string;
            assunto: string;
            corpo: string;
            agendada_para: string;
            lida_em: string | null;
          }[]}
        />
      </div>
    </>
  );
}
