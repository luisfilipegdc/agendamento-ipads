import { createServerClient } from "@supabase/ssr";
import { cookies } from "next/headers";

export async function criaClienteServidor() {
  const store = await cookies();

  return createServerClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
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
