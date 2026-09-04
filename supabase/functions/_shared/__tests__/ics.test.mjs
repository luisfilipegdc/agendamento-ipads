// Testes do gerador de .ics. Rodar: node supabase/functions/_shared/__tests__/ics.test.mjs
import assert from "node:assert/strict";
import { readFileSync, writeFileSync, mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

// O módulo é TypeScript só nos tipos; removemos as anotações para rodar no Node.
const src = readFileSync(
  new URL("../ics.ts", import.meta.url), "utf8")
  .replace(/^export interface [\s\S]*?^}\n/m, "")
  .replace(/: (string|number|DadosConvite|"REQUEST" \| "CANCEL")(?=[,)\s=])/g, "")
  .replace(/\): string \{/g, ") {")
  .replace(/const partes: string\[\] = \[\]/, "const partes = []")
  .replace(/const linhas = \[/, "const linhas = [");
const dir = mkdtempSync(join(tmpdir(), "ics-"));
const f = join(dir, "ics.mjs");
writeFileSync(f, src);
const { montaIcs } = await import(`file://${f}`);

const base = {
  uid: "abc-123@agendamento.marista",
  sequence: 0,
  metodo: "REQUEST",
  titulo: "iPads — 20 unidades",
  descricao: "Turma 6ºA",
  local: "Sala 12",
  data: "2026-03-02",
  inicio: "07:30:00",
  fim: "08:15:00",
  organizador: "agendamento@escola.br",
  participante: "prof@escola.br",
  alarmeMinutos: 15,
};

let ok = 0;
const t = (nome, fn) => {
  fn(); console.log("PASS ", nome); ok++;
};

t("terminadores de linha são CRLF", () => {
  const s = montaIcs(base);
  assert.ok(s.includes("\r\n"));
  assert.ok(!/[^\r]\n/.test(s), "encontrou LF sem CR");
});

t("estrutura mínima do VEVENT", () => {
  const s = montaIcs(base);
  for (const l of ["BEGIN:VCALENDAR", "BEGIN:VEVENT", "END:VEVENT",
                   "END:VCALENDAR", "UID:abc-123@agendamento.marista",
                   "SEQUENCE:0", "METHOD:REQUEST", "STATUS:CONFIRMED"]) {
    assert.ok(s.includes(l), `faltou ${l}`);
  }
});

t("data e hora viram carimbo local com TZID", () => {
  const s = montaIcs(base);
  assert.ok(s.includes("DTSTART;TZID=America/Sao_Paulo:20260302T073000"));
  assert.ok(s.includes("DTEND;TZID=America/Sao_Paulo:20260302T081500"));
});

t("alarme é gerado com o offset pedido", () => {
  const s = montaIcs(base);
  assert.ok(s.includes("BEGIN:VALARM"));
  assert.ok(s.includes("TRIGGER:-PT15M"));
});

t("cancelamento sai como CANCEL/CANCELLED e sem alarme", () => {
  const s = montaIcs({ ...base, metodo: "CANCEL", sequence: 3 });
  assert.ok(s.includes("METHOD:CANCEL"));
  assert.ok(s.includes("STATUS:CANCELLED"));
  assert.ok(s.includes("SEQUENCE:3"));
  assert.ok(!s.includes("BEGIN:VALARM"), "cancelamento não deve ter alarme");
});

t("ponto e vírgula, vírgula e barra são escapados", () => {
  // String.raw evita a armadilha: em string comum, "\;" é apenas ";".
  const s = montaIcs({ ...base, titulo: String.raw`a;b,c\d`, descricao: "l1\nl2" });
  assert.equal(
    s.split("\r\n").find((l) => l.startsWith("SUMMARY:")),
    String.raw`SUMMARY:a\;b\,c\\d`,
    "escape de ; , e barra incorreto",
  );
  assert.ok(
    s.includes(String.raw`DESCRIPTION:l1\nl2`),
    "quebra de linha não escapada",
  );
});

t("linha longa é dobrada em no máximo 75 octetos", () => {
  const s = montaIcs({ ...base, descricao: "x".repeat(300) });
  for (const linha of s.split("\r\n")) {
    const n = Buffer.byteLength(linha, "utf8");
    assert.ok(n <= 75, `linha com ${n} octetos: ${linha.slice(0, 40)}…`);
  }
  // A continuação precisa começar com espaço, senão o parser junta errado.
  const cont = s.split("\r\n").filter((l) => l.startsWith(" "));
  assert.ok(cont.length > 0, "não houve dobra");
});

t("acento não é partido no meio de um caractere multibyte", () => {
  const s = montaIcs({ ...base, descricao: "ção ".repeat(60) });
  for (const linha of s.split("\r\n")) {
    assert.ok(Buffer.byteLength(linha, "utf8") <= 75);
    // Se a dobra cortasse no meio do UTF-8, apareceria U+FFFD ao reconstruir.
    assert.ok(!linha.includes("�"), "caractere multibyte partido");
  }
  const reconstruido = s.split("\r\n")
    .reduce((a, l) => (l.startsWith(" ") ? a + l.slice(1) : a + "\n" + l), "");
  assert.ok(reconstruido.includes("ção ção"), "conteúdo perdido na dobra");
});

console.log(`\n${ok} testes de .ics passaram`);
