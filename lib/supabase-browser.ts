"use client";

import { createBrowserClient } from "@supabase/ssr";
import { supabaseChavePublica, supabaseUrl } from "./config";

export function criaClienteNavegador() {
  return createBrowserClient(supabaseUrl(), supabaseChavePublica());
}
