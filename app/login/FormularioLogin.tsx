"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { criaClienteNavegador } from "@/lib/supabase-browser";

type Modo = "senha" | "link";

export function FormularioLogin(
  { destino, erroInicial }: { destino: string; erroInicial: string | null },
) {
  const router = useRouter();
  const [modo, setModo] = useState<Modo>("senha");
  const [email, setEmail] = useState("");
  const [senha, setSenha] = useState("");
  const [carregando, setCarregando] = useState(false);
  const [erro, setErro] = useState<string | null>(erroInicial);
  const [enviado, setEnviado] = useState(false);

  async function enviar(e: React.FormEvent) {
    e.preventDefault();
    setErro(null);
    setCarregando(true);
    const supabase = criaClienteNavegador();

    try {
      if (modo === "senha") {
        const { error } = await supabase.auth.signInWithPassword({
          email: email.trim(),
          password: senha,
        });
        if (error) throw error;
        router.push(destino);
        router.refresh();
      } else {
        const { error } = await supabase.auth.signInWithOtp({
          email: email.trim(),
          options: {
            emailRedirectTo: `${window.location.origin}/auth/confirmar` +
              `?de=${encodeURIComponent(destino)}`,
          },
        });
        if (error) throw error;
        setEnviado(true);
      }
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      setErro(
        /invalid login credentials/i.test(msg)
          ? "E-mail ou senha incorretos."
          : /email not confirmed/i.test(msg)
          ? "Este e-mail ainda não foi confirmado. Procure a coordenação."
          : /rate limit|too many/i.test(msg)
          ? "Muitas tentativas. Aguarde alguns minutos."
          : msg,
      );
    } finally {
      setCarregando(false);
    }
  }

  if (enviado) {
    return (
      <div className="painel">
        <h1>Verifique seu e-mail</h1>
        <p className="subtitulo">
          Enviamos um link de acesso para <strong>{email}</strong>. Ele vale por
          uma hora.
        </p>
        <button onClick={() => setEnviado(false)}>Voltar</button>
      </div>
    );
  }

  return (
    <form className="painel" onSubmit={enviar}>
      <h1>Agendamento de Equipamentos</h1>
      <p className="subtitulo">Entre com seu e-mail institucional.</p>

      {erro && <div className="aviso erro">{erro}</div>}

      <div className="campo" style={{ marginBottom: 12 }}>
        <label htmlFor="email">E-mail</label>
        <input
          id="email"
          type="email"
          required
          autoComplete="email"
          value={email}
          onChange={(e) => setEmail(e.target.value)}
        />
      </div>

      {modo === "senha" && (
        <div className="campo" style={{ marginBottom: 12 }}>
          <label htmlFor="senha">Senha</label>
          <input
            id="senha"
            type="password"
            required
            autoComplete="current-password"
            value={senha}
            onChange={(e) => setSenha(e.target.value)}
          />
        </div>
      )}

      <button className="primario" type="submit" disabled={carregando}>
        {carregando
          ? "Aguarde…"
          : modo === "senha"
          ? "Entrar"
          : "Enviar link de acesso"}
      </button>

      <p style={{ fontSize: 13, marginTop: 16, marginBottom: 0 }}>
        <button
          type="button"
          onClick={() => { setModo(modo === "senha" ? "link" : "senha"); setErro(null); }}
          style={{
            border: "none", background: "none", padding: 0,
            color: "var(--acento)", textDecoration: "underline",
          }}
        >
          {modo === "senha" ? "Entrar por link no e-mail" : "Entrar com senha"}
        </button>
      </p>
    </form>
  );
}
