import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "Agendamento de Equipamentos",
  description: "Agendamento de iPads e notebooks da rede",
};

export default function RootLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <html lang="pt-BR">
      <body>{children}</body>
    </html>
  );
}
