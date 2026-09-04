-- Agendamento dos jobs. Rodar APÓS habilitar a extensão pg_cron no projeto.
-- Horários em UTC (America/Sao_Paulo = UTC-3).
select cron.unschedule(jobname)
  from cron.job where jobname in ('fila-do-dia', 'marca-atrasadas');

-- 06:30 BRT: fila do dia para estagiário e coordenação
select cron.schedule('fila-do-dia', '30 9 * * 1-6',
                     $$select enfileira_fila_do_dia();$$);

-- A cada 10 min durante o expediente: marca devoluções em atraso
select cron.schedule('marca-atrasadas', '*/10 10-23 * * 1-6',
                     $$select marca_atrasadas();$$);
