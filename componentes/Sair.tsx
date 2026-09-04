"use client";

import { useRouter } from "next/navigation";
import { criaClienteNavegador } from "@/lib/supabase-browser";

export function Sair() {
  const router = useRouter();
  return (
    <button
      onClick={async () => {
        await criaClienteNavegador().auth.signOut();
        router.push("/login");
        router.refresh();
      }}
      style={{
        border: "none", background: "none", padding: "0 0 0 10px",
        color: "var(--suave)", textDecoration: "underline", fontSize: 13,
      }}
    >
      sair
    </button>
  );
}
