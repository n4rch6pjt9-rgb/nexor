-- Status do último run dos jobs do pg_cron para a tela Sincronizações (Edge Function api-syncs).
-- Idempotente. Só service_role executa (api-syncs usa a service role).

-- O corpo lê cron.*; a extensão só existe no Supabase, não no Postgres descartável de scripts/validar-migrations.sh.
set check_function_bodies = off;

create or replace function public.sync_status_cron(p_jobs text[])
 returns table(jobname text, schedule text, ativo boolean, run_id bigint, status text,
               inicio timestamp with time zone, fim timestamp with time zone, mensagem text)
 language sql
 stable security definer
 set search_path to 'pg_catalog', 'public', 'cron', 'pg_temp'
as $function$
  select j.jobname::text, j.schedule::text, j.active, d.runid, d.status::text, d.start_time, d.end_time,
         left(d.return_message, 300)
    from unnest(p_jobs) n(nome)
    join cron.job j on j.jobname = n.nome
    left join lateral (
      select r.runid, r.status, r.start_time, r.end_time, r.return_message
        from cron.job_run_details r
       where r.jobid = j.jobid
       order by r.start_time desc
       limit 1
    ) d on true
$function$;

reset check_function_bodies;

revoke all on function public.sync_status_cron(text[]) from public, anon, authenticated;
grant execute on function public.sync_status_cron(text[]) to service_role;
