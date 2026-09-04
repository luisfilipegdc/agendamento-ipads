import { createServerClient } from "@supabase/ssr";
import { cookies } from "next/headers";
import { supabaseChavePublica, supabaseUrl } from "./config";

export async function criaClienteServidor() {
  const store = await cookies();

  return createServerClient(
    supabaseUrl(),
    supabaseChavePublica(),
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
