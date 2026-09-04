import { createServerClient } from "@supabase/ssr";
import { cookies } from "next/headers";
import { SUPABASE_CHAVE_PUBLICA, SUPABASE_URL } from "./config";

export async function criaClienteServidor() {
  const store = await cookies();

  return createServerClient(
    SUPABASE_URL,
    SUPABASE_CHAVE_PUBLICA,
    {
      cookies: {
        getAll: () => store.getAll(),
        setAll: (lista) => {
          try {
            for (const { name, value, options } of lista) {
              store.set(name, value, options);
            }
          } catch {
            // Server Component não pode escrever cookie. O middleware renova a
            // sessão, então aqui é seguro ignorar.
          }
        },
      },
    },
  );
}
