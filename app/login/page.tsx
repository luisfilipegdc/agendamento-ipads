import { FormularioLogin } from "./FormularioLogin";

export default async function Login({
  searchParams,
}: {
  searchParams: Promise<{ de?: string; erro?: string }>;
}) {
  const sp = await searchParams;

  // Só caminhos internos: um `de` externo viraria redirecionamento aberto.
  const destino = sp.de?.startsWith("/") && !sp.de.startsWith("//")
    ? sp.de
    : "/agenda";

  return (
    <div className="container" style={{ maxWidth: 400, paddingTop: 60 }}>
      <FormularioLogin destino={destino} erroInicial={sp.erro ?? null} />
    </div>
  );
}
