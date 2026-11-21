-- Agenda no pg_cron (horários em UTC; Brasília = UTC-3):
--   pgc-sync-planejar      09:10 UTC (06:10) enfileira as páginas do PGC do dia
--   pgc-sync-tick          a cada minuto: lê respostas do pg_net, grava e dispara as próximas páginas
--   licext-publicar-pncp   minuto 20 de cada hora: publica em licitacoes_externas o que a busca do PNCP trouxe
-- cron.schedule com o mesmo jobname atualiza o job (idempotente). Sem pg_cron (Postgres descartável de
-- scripts/validar-migrations.sh) o bloco não faz nada.

do $agenda$
begin
  if to_regnamespace('cron') is not null then
    perform cron.schedule('pgc-sync-planejar', '10 9 * * *', $$select public.pgc_sync_planejar()$$);
    perform cron.schedule('pgc-sync-tick', '* * * * *', $$select public.pgc_sync_tick()$$);
    perform cron.schedule('licext-publicar-pncp', '20 * * * *', $$select public.licext_publicar_de_pncp_busca(10)$$);
  end if;
end
$agenda$;
