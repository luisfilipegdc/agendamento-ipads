// Worker de notificações.
// Lê a fila, envia por e-mail e marca como enviada. Idempotente: a chave de
// dedupe em `notificacao` garante que reprocessar não reenvia nada.
//
// Invocação: cron do Supabase, a cada 5 minutos.
//   select cron.schedule('notificar', '*/5 * * * *',
//     $$select net.http_post(url := '<FUNCTION_URL>',
//         headers := '{"Authorization":"Bearer <SERVICE_ROLE>"}'::jsonb)$$);

import { createClient } from "jsr:@supabase/supabase-js@2";
import { montaIcs } from "../_shared/ics.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const RESEND_KEY = Deno.env.get("RESEND_API_KEY")!;
const REMETENTE = Deno.env.get("EMAIL_REMETENTE") ??
  "Agendamento <agendamento@exemplo.com.br>";
const APP_URL = Deno.env.get("APP_URL") ?? "";
const LOTE = Number(Deno.env.get("LOTE") ?? "50");

const db = createClient(SUPABASE_URL, SERVICE_KEY, {
  auth: { persistSession: false },
});

interface Pendente {
  id: string;
  chave: string;
  assunto: string;
  corpo: string;
  canal: string;
  destinatario_email: string;
  tentativas: number;
  reserva_id: string | null;
  reserva_data: string | null;
  quantidade: number | null;
  modo: string | null;
  horario_rotulo: string | null;
  horario_inicio: string | null;
  horario_fim: string | null;
  pool_nome: string | null;
  unidade_nome: string | null;
  fuso: string | null;
  ponto_apoio: string | null;
  turma: string | null;
  sala: string | null;
  professor_nome: string | null;
  ics_uid: string | null;
  ics_sequence: number | null;
  ics_metodo: "REQUEST" | "CANCEL" | null;
}

function escapaHtml(v: string): string {
  return v.replace(/[&<>"']/g, (c) => ({
    "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
  }[c]!));
}

function montaHtml(n: Pendente): string {
  const linhas: [string, string][] = [];
  if (n.pool_nome) linhas.push(["Equipamento", n.pool_nome]);
  if (n.reserva_data) {
    const [a, m, d] = n.reserva_data.split("-");
    linhas.push(["Data", `${d}/${m}/${a}`]);
  }
  if (n.horario_rotulo) linhas.push(["Horário", n.horario_rotulo]);
  if (n.turma) linhas.push(["Turma", n.turma]);
  if (n.quantidade) linhas.push(["Quantidade", String(n.quantidade)]);
  if (n.sala) linhas.push(["Local", n.sala]);

  const tabela = linhas.length === 0 ? "" : `
    <table style="border-collapse:collapse;margin:16px 0;font-size:14px">
      ${linhas.map(([k, v]) => `
        <tr>
          <td style="padding:4px 16px 4px 0;color:#666">${escapaHtml(k)}</td>
          <td style="padding:4px 0;font-weight:600">${escapaHtml(v)}</td>
        </tr>`).join("")}
    </table>`;

  const aviso = n.modo === "RETIRADA_BALCAO"
    ? `<p style="background:#FFF4E5;border-left:3px solid #E8A33D;padding:10px 14px;
         margin:16px 0;font-size:14px">
         <strong>Retirada por sua conta.</strong> Neste horário não há estagiário de
         plantão. Retire e devolva em
         <strong>${escapaHtml(n.ponto_apoio ?? "Coordenação")}</strong>.
       </p>`
    : "";

  const link = APP_URL
    ? `<p style="font-size:13px;margin-top:20px">
         <a href="${APP_URL}" style="color:#0B6BCB">Abrir o agendamento</a></p>`
    : "";

  return `<!doctype html><html lang="pt-BR"><body style="margin:0;
    font-family:-apple-system,Segoe UI,Roboto,sans-serif;color:#1a1a1a">
    <div style="max-width:560px;margin:0 auto;padding:24px">
      <p style="font-size:12px;letter-spacing:.06em;text-transform:uppercase;
        color:#888;margin:0 0 4px">${escapaHtml(n.unidade_nome ?? "")}</p>
      <h1 style="font-size:19px;margin:0 0 12px">${escapaHtml(n.assunto)}</h1>
      <p style="font-size:14px;line-height:1.55;white-space:pre-line;margin:0">
        ${escapaHtml(n.corpo)}</p>
      ${tabela}${aviso}${link}
    </div></body></html>`;
}

function montaAnexoIcs(n: Pendente): { filename: string; content: string } | null {
  if (
    !n.ics_uid || !n.reserva_data || !n.horario_inicio || !n.horario_fim ||
    !n.chave.startsWith("confirmacao:")
  ) return null;

  const ics = montaIcs({
    uid: n.ics_uid,
    sequence: n.ics_sequence ?? 0,
    metodo: n.ics_metodo ?? "REQUEST",
    titulo: `${n.pool_nome ?? "Equipamentos"} — ${n.quantidade} un.` +
      (n.turma ? ` (${n.turma})` : ""),
    descricao: n.modo === "RETIRADA_BALCAO"
      ? `Retire e devolva em ${n.ponto_apoio ?? "Coordenação"}.`
      : "A estagiária levará os equipamentos até a sala.",
    local: n.sala ?? n.ponto_apoio ?? n.unidade_nome ?? "",
    data: n.reserva_data,
    inicio: n.horario_inicio,
    fim: n.horario_fim,
    organizador: REMETENTE.replace(/.*<|>.*/g, ""),
    participante: n.destinatario_email,
    alarmeMinutos: 15,
  }, n.fuso ?? "America/Sao_Paulo");

  return {
    filename: "agendamento.ics",
    content: btoa(String.fromCharCode(...new TextEncoder().encode(ics))),
  };
}

async function envia(n: Pendente): Promise<void> {
  const anexo = montaAnexoIcs(n);
  const resp = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${RESEND_KEY}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      from: REMETENTE,
      to: [n.destinatario_email],
      subject: n.assunto,
      html: montaHtml(n),
      ...(anexo ? { attachments: [anexo] } : {}),
    }),
  });

  if (!resp.ok) {
    throw new Error(`Resend ${resp.status}: ${(await resp.text()).slice(0, 300)}`);
  }
}

Deno.serve(async () => {
  const { data, error } = await db
    .from("notificacao_pendente")
    .select("*")
    .eq("canal", "EMAIL")
    .limit(LOTE);

  if (error) {
    return Response.json({ erro: error.message }, { status: 500 });
  }

  let enviadas = 0;
  let falhas = 0;

  for (const n of (data ?? []) as Pendente[]) {
    try {
      await envia(n);
      await db.from("notificacao")
        .update({ enviada_em: new Date().toISOString(), erro: null })
        .eq("id", n.id);
      enviadas++;
    } catch (e) {
      // Sem enviada_em, a linha volta na próxima rodada. Após 5 tentativas a
      // view para de devolvê-la, para não ficar em laço infinito.
      await db.from("notificacao")
        .update({
          tentativas: n.tentativas + 1,
          erro: e instanceof Error ? e.message : String(e),
        })
        .eq("id", n.id);
      falhas++;
    }
  }

  return Response.json({ enviadas, falhas, lote: data?.length ?? 0 });
});
