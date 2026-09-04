// Geração de convite de calendário (RFC 5545).
// Anexado ao e-mail de confirmação: o professor adiciona ao Outlook em um clique
// e o alarme dispara no aparelho dele, sem o sistema depender de nada.

export interface DadosConvite {
  uid: string;
  sequence: number;
  metodo: "REQUEST" | "CANCEL";
  titulo: string;
  descricao: string;
  local: string;
  data: string;        // YYYY-MM-DD
  inicio: string;      // HH:MM:SS
  fim: string;         // HH:MM:SS
  organizador: string;
  participante: string;
  alarmeMinutos: number;
}

/** Escapa conforme RFC 5545 §3.3.11. A ordem importa: a barra invertida primeiro. */
function esc(v: string): string {
  return v
    .replace(/\\/g, "\\\\")
    .replace(/;/g, "\\;")
    .replace(/,/g, "\\,")
    .replace(/\r?\n/g, "\\n");
}

/** Linhas com mais de 75 octetos precisam ser dobradas, senão o Outlook rejeita. */
function dobra(linha: string): string {
  const bytes = new TextEncoder().encode(linha);
  if (bytes.length <= 75) return linha;

  const partes: string[] = [];
  let atual = "";
  let tam = 0;
  for (const ch of linha) {
    const n = new TextEncoder().encode(ch).length;
    // A partir da segunda linha há um espaço de continuação, que também conta.
    const limite = partes.length === 0 ? 75 : 74;
    if (tam + n > limite) {
      partes.push(atual);
      atual = "";
      tam = 0;
    }
    atual += ch;
    tam += n;
  }
  if (atual) partes.push(atual);
  return partes.join("\r\n ");
}

/** 2026-03-02 + 08:00:00 → 20260302T080000 (horário local, com TZID). */
function carimbo(data: string, hora: string): string {
  return `${data.replace(/-/g, "")}T${hora.replace(/:/g, "").padEnd(6, "0")}`;
}

function agoraUTC(): string {
  return new Date().toISOString().replace(/[-:]/g, "").replace(/\.\d{3}/, "");
}

export function montaIcs(d: DadosConvite, fuso = "America/Sao_Paulo"): string {
  const linhas = [
    "BEGIN:VCALENDAR",
    "VERSION:2.0",
    "PRODID:-//Rede Marista//Agendamento de Equipamentos//PT",
    "CALSCALE:GREGORIAN",
    `METHOD:${d.metodo}`,
    "BEGIN:VEVENT",
    `UID:${d.uid}`,
    `SEQUENCE:${d.sequence}`,
    `DTSTAMP:${agoraUTC()}`,
    `DTSTART;TZID=${fuso}:${carimbo(d.data, d.inicio)}`,
    `DTEND;TZID=${fuso}:${carimbo(d.data, d.fim)}`,
    `SUMMARY:${esc(d.titulo)}`,
    `DESCRIPTION:${esc(d.descricao)}`,
    `LOCATION:${esc(d.local)}`,
    `ORGANIZER;CN=Agendamento de Equipamentos:mailto:${d.organizador}`,
    `ATTENDEE;CUTYPE=INDIVIDUAL;ROLE=REQ-PARTICIPANT;PARTSTAT=ACCEPTED;` +
      `RSVP=FALSE:mailto:${d.participante}`,
    // CANCEL precisa de STATUS:CANCELLED, senão o Outlook ignora o cancelamento.
    d.metodo === "CANCEL" ? "STATUS:CANCELLED" : "STATUS:CONFIRMED",
    "TRANSP:OPAQUE",
  ];

  if (d.metodo === "REQUEST" && d.alarmeMinutos > 0) {
    linhas.push(
      "BEGIN:VALARM",
      "ACTION:DISPLAY",
      `TRIGGER:-PT${d.alarmeMinutos}M`,
      `DESCRIPTION:${esc(d.titulo)}`,
      "END:VALARM",
    );
  }

  linhas.push("END:VEVENT", "END:VCALENDAR");
  return linhas.map(dobra).join("\r\n") + "\r\n";
}
