-- Spec 0071 (fase 3, K-8): tick e jobs de cron do Sistema S, criados DESLIGADOS.
--
-- O tick roda a cada minuto por fonte e decide uma ação, sem fazer chamada ao portal:
--   fora      fonte_externa_pode_coletar(slug) é falso (inativa, cron_ligado = false, perfil não certificado,
--             pausada, robots proíbe sem mural_autorizado);
--   ocupada   há execução 'executando' da fonte iniciada há menos de 10 min (uma chamada por vez por fonte);
--   descobrir não houve descoberta nesta fonte na última hora (mural lido do mais novo para o mais velho);
--   carregar  há processo pendente na fila (a função lê até max_processos_por_tick da fonte);
--   ocioso    nada a fazer.
-- Só descobrir e carregar chamam a Edge Function sync-sistema-s (pg_net, Bearer do Vault), que repete a checagem
-- de fonte_externa_pode_coletar antes de falar com o portal.
--
-- Os jobs nascem com active = false. Ligar uma fonte tem dois passos, nesta ordem, feitos pelo Marcelo:
--   1) update public.fontes_externas set cron_ligado = true where slug = 'sescdn';
--   2) select cron.alter_job(jobid, active := true) from cron.job where jobname = 'licitagym-sistema-s-sescdn';
-- Desligar é o inverso (cron_ligado = false já basta: o tick devolve 'fora').
--
-- Reversão:
--   select cron.unschedule(jobid) from cron.job where jobname like 'licitagym-sistema-s-%';
--   drop function if exists private.sistema_s_tick(text);
--   drop function if exists private.sistema_s_tick_acao(text);

create or replace function private.sistema_s_tick_acao(p_slug text)
returns text
language plpgsql
stable
security invoker
set search_path = pg_catalog, pg_temp
as $fn$
begin
  if p_slug is null or not public.fonte_externa_pode_coletar(p_slug) then
    return 'fora';
  end if;
  if exists (
    select 1 from private.coleta_externa_run r
     where r.fonte = p_slug and r.status = 'executando' and r.started_at > now() - interval '10 minutes'
  ) then
    return 'ocupada';
  end if;
  if not exists (
    select 1 from private.coleta_externa_run r
     where r.fonte = p_slug and r.modo = 'descoberta' and r.started_at > now() - interval '1 hour'
  ) then
    return 'descobrir';
  end if;
  if exists (
    select 1 from private.coleta_externa_fila f where f.fonte = p_slug and f.status = 'pendente'
  ) then
    return 'carregar';
  end if;
  return 'ocioso';
end
$fn$;

create or replace function private.sistema_s_tick(p_slug text)
returns text
language plpgsql
volatile
security invoker
set search_path = pg_catalog, pg_temp
as $fn$
declare
  v_acao text := private.sistema_s_tick_acao(p_slug);
begin
  if v_acao in ('descobrir', 'carregar') then
    perform private.cron_chamar_edge(
      'sistema-s-' || p_slug,
      'sync-sistema-s',
      jsonb_build_object('acao', v_acao, 'fontes', jsonb_build_array(p_slug)),
      150000
    );
  end if;
  return v_acao;
end
$fn$;

revoke all on function private.sistema_s_tick_acao(text) from public, anon, authenticated;
revoke all on function private.sistema_s_tick(text) from public, anon, authenticated;

comment on function private.sistema_s_tick_acao(text) is
  'Spec 0071 K-8: decide a ação do minuto para a fonte (fora, ocupada, descobrir, carregar, ocioso). Não chama o portal.';
comment on function private.sistema_s_tick(text) is
  'Spec 0071 K-8: executa a ação decidida por sistema_s_tick_acao chamando a Edge Function sync-sistema-s. Devolve a ação.';

-- Um job por fonte piloto, todos desligados. Fora do Supabase (banco de teste sem pg_cron) o bloco não faz nada.
do $jobs$
declare
  v_slug text;
  v_nome text;
  v_id bigint;
begin
  if to_regnamespace('cron') is null then
    raise notice 'pg_cron ausente: jobs do Sistema S não criados';
    return;
  end if;
  foreach v_slug in array array['sescdn', 'firjan', 'sescsp'] loop
    v_nome := 'licitagym-sistema-s-' || v_slug;
    perform cron.unschedule(c.jobid) from cron.job c where c.jobname = v_nome;
    v_id := cron.schedule(v_nome, '* * * * *', format('select private.sistema_s_tick(%L)', v_slug));
    perform cron.alter_job(v_id, active := false);
  end loop;
end
$jobs$;
