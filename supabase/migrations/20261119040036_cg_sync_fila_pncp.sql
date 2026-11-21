-- Fila de sync da busca do PNCP (status x UF x página). O worker é a Edge Function cg-sync-pncp-busca; o segredo fica só no Vault.
create table public.cg_sync_fila (
  id bigint generated always as identity primary key,
  lote date not null,
  status text not null check (status in ('recebendo_proposta','propostas_encerradas','encerradas')),
  uf text,
  modalidade text,
  pagina integer not null check (pagina >= 1),
  estado text not null default 'pendente' check (estado in ('pendente','em_execucao','ok','erro')),
  tentativas integer not null default 0,
  itens integer, total_pncp integer, truncado boolean not null default false,
  erro text, iniciado_em timestamptz, concluido_em timestamptz,
  created_at timestamptz not null default now()
);
create unique index cg_sync_fila_uk on public.cg_sync_fila (lote, status, coalesce(uf,''), coalesce(modalidade,''), pagina);
create index cg_sync_fila_estado_idx on public.cg_sync_fila (estado, id);
alter table public.cg_sync_fila enable row level security;
revoke all on table public.cg_sync_fila from anon, authenticated;
comment on table public.cg_sync_fila is 'Fila do sync da busca do PNCP. Uma linha = uma página (100 editais) de status x UF. O worker enfileira a página seguinte enquanto houver itens (teto de 10.000 por consulta marca truncado).';

-- segredo próprio no Vault (não passa pelo chat)
do $$ begin
  if not exists (select 1 from vault.secrets where name = 'cg_sync_secret') then
    perform vault.create_secret(replace(gen_random_uuid()::text,'-','') || replace(gen_random_uuid()::text,'-',''), 'cg_sync_secret', 'Autentica cron/DB -> Edge Function cg-sync-pncp-busca');
  end if;
end $$;

create or replace function public.cg_sync_validar(p text) returns boolean
language sql security definer set search_path = public, vault as $$
  select coalesce(p is not null and exists (select 1 from vault.decrypted_secrets where name = 'cg_sync_secret' and decrypted_secret = p), false) $$;
revoke execute on function public.cg_sync_validar(text) from public, anon, authenticated;
grant execute on function public.cg_sync_validar(text) to service_role;

create or replace function public.cg_sync_planejar(p_status text default 'recebendo_proposta') returns integer
language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  insert into cg_sync_fila (lote, status, uf, pagina)
  select (now() at time zone 'America/Sao_Paulo')::date, p_status, u.sigla, 1 from cg_ufs u
  on conflict do nothing;
  get diagnostics n = row_count;
  return n;
end $$;

create or replace function public.cg_sync_tick() returns integer
language plpgsql security definer set search_path = public, vault, net as $$
declare ids bigint[]; seg text;
begin
  -- recupera tarefas travadas (worker morreu)
  update cg_sync_fila set estado = case when tentativas >= 5 then 'erro' else 'pendente' end,
         erro = coalesce(erro,'') || ' [travada]'
   where estado = 'em_execucao' and iniciado_em < now() - interval '5 minutes';
  -- uma execução por vez (o PNCP derruba chamadas simultâneas)
  if exists (select 1 from cg_sync_fila where estado = 'em_execucao') then return 0; end if;
  select array_agg(id) into ids from (select id from cg_sync_fila where estado = 'pendente' order by lote, id limit 8) x;
  if ids is null then return 0; end if;
  select decrypted_secret into seg from vault.decrypted_secrets where name = 'cg_sync_secret';
  update cg_sync_fila set estado = 'em_execucao', iniciado_em = now(), tentativas = tentativas + 1 where id = any(ids);
  perform net.http_post(
    url := 'https://wrfumpboqablxkjmllfp.supabase.co/functions/v1/cg-sync-pncp-busca',
    headers := jsonb_build_object('Authorization','Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6IndyZnVtcGJvcWFibHhram1sbGZwIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTQ1MTc3OTAsImV4cCI6MjExMDA5Mzc5MH0.Pgjg8NLLGv8lwFv649xXOP_mHICmu7U8iLIzn3tgn1w','x-sync-secret',seg,'Content-Type','application/json'),
    body := jsonb_build_object('fila', ids), timeout_milliseconds := 145000);
  return coalesce(array_length(ids,1),0);
end $$;
revoke execute on function public.cg_sync_planejar(text), public.cg_sync_tick() from public, anon, authenticated;