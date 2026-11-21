-- Sync diário do Compras.gov (módulo 07, Lei 14.133). Tudo dentro do banco: pg_net faz o HTTP, cg_ingest_* grava.
-- Uma tarefa = (tipo, dia, modalidade, página). A data final da API é EXCLUSIVA: janela [dia, dia+1] traz só o dia.
create table public.cg_sync_compras_fila (
  id bigint generated always as identity primary key,
  tipo text not null check (tipo in ('contratacao','item','resultado')),
  dia date not null,
  modalidade integer,
  pagina integer not null default 1 check (pagina >= 1),
  estado text not null default 'pendente' check (estado in ('pendente','em_execucao','ok','vazio','erro')),
  tentativas integer not null default 0,
  req_id bigint,
  total_paginas integer, linhas integer, erro text,
  iniciado_em timestamptz, concluido_em timestamptz,
  created_at timestamptz not null default now()
);
create unique index cg_sync_compras_fila_uk on public.cg_sync_compras_fila (tipo, dia, coalesce(modalidade,0), pagina);
create index cg_sync_compras_fila_estado_idx on public.cg_sync_compras_fila (estado, id);
alter table public.cg_sync_compras_fila enable row level security;
revoke all on table public.cg_sync_compras_fila from anon, authenticated;
comment on table public.cg_sync_compras_fila is 'Fila do sync do Compras.gov (módulo 07). vazio = dia sem dados na API (itens/resultados têm defasagem de ~1 semana); o planejador reabre os vazios dos últimos dias.';

create or replace function public.cg_sync_compras_url(p_tipo text, p_dia date, p_modalidade integer, p_pagina integer) returns text
language sql immutable set search_path = '' as $$
  select 'https://dadosabertos.compras.gov.br/modulo-contratacoes/' ||
    case p_tipo
      when 'contratacao' then '1_consultarContratacoes_PNCP_14133?dataPublicacaoPncpInicial=' || p_dia || '&dataPublicacaoPncpFinal=' || (p_dia + 1) || '&codigoModalidade=' || p_modalidade
      when 'item'        then '2_consultarItensContratacoes_PNCP_14133?dataInclusaoPncpInicial=' || p_dia || '&dataInclusaoPncpFinal=' || (p_dia + 1)
      else                    '3_consultarResultadoItensContratacoes_PNCP_14133?dataResultadoPncpInicial=' || p_dia || '&dataResultadoPncpFinal=' || (p_dia + 1)
    end || '&tamanhoPagina=500&pagina=' || p_pagina $$;

create or replace function public.cg_sync_compras_planejar(p_dias integer default 10) returns integer
language plpgsql security definer set search_path = public as $$
declare n integer; hoje date := (now() at time zone 'America/Sao_Paulo')::date;
begin
  insert into cg_sync_compras_fila (tipo, dia, modalidade, pagina)
  select x.tipo, d::date, m, 1
  from generate_series(hoje - p_dias, hoje, interval '1 day') d
  cross join (values ('contratacao'),('item'),('resultado')) x(tipo)
  left join generate_series(1,14) m on x.tipo = 'contratacao'
  on conflict (tipo, dia, coalesce(modalidade,0), pagina)
  do update set estado = 'pendente', tentativas = 0, erro = null, req_id = null
  where cg_sync_compras_fila.estado = 'vazio';
  get diagnostics n = row_count;
  return n;
end $$;

create or replace function public.cg_sync_compras_tick() returns text
language plpgsql security definer set search_path = public, net as $$
declare t cg_sync_compras_fila%rowtype; r record; j jsonb; arr jsonb; n integer; rest integer; ing integer;
        livres integer; msg text := ''; d record;
begin
  -- tarefas sem resposta há muito tempo voltam para a fila
  update cg_sync_compras_fila set estado = case when tentativas >= 5 then 'erro' else 'pendente' end,
         erro = coalesce(erro,'') || ' [sem resposta]', req_id = null
   where estado = 'em_execucao' and iniciado_em < now() - interval '8 minutes';

  -- 1) coleta: grava UMA resposta pronta por chamada (as cg_ingest_* usam tabela temporária por transação)
  select f.* into t from cg_sync_compras_fila f join net._http_response h on h.id = f.req_id
   where f.estado = 'em_execucao' order by f.id limit 1 for update of f skip locked;
  if found then
    select * into r from net._http_response where id = t.req_id;
    begin
      if r.status_code is distinct from 200 or r.content is null then
        raise exception 'http %: %', coalesce(r.status_code::text,'sem status'), left(coalesce(r.error_msg, r.content, ''), 120);
      end if;
      j := r.content::jsonb;
      arr := coalesce(j->'resultado', '[]'::jsonb);
      n := jsonb_array_length(arr);
      rest := coalesce((j->>'paginasRestantes')::integer, 0);
      ing := 0;
      if n > 0 then
        ing := case t.tipo when 'contratacao' then public.cg_ingest_contratacoes(arr)
                           when 'item' then public.cg_ingest_itens(arr)
                           else public.cg_ingest_resultados(arr) end;
      end if;
      update cg_sync_compras_fila set estado = case when n = 0 and t.pagina = 1 then 'vazio' else 'ok' end,
             linhas = n, total_paginas = (j->>'totalPaginas')::integer, erro = null, req_id = null, concluido_em = now()
       where id = t.id;
      if rest > 0 then
        insert into cg_sync_compras_fila (tipo, dia, modalidade, pagina) values (t.tipo, t.dia, t.modalidade, t.pagina + 1) on conflict do nothing;
      end if;
      msg := format('coletou %s %s mod=%s p%s: %s linhas', t.tipo, t.dia, coalesce(t.modalidade::text,'-'), t.pagina, n);
    exception when others then
      update cg_sync_compras_fila set estado = case when t.tentativas >= 5 then 'erro' else 'pendente' end,
             erro = left(sqlerrm, 300), req_id = null where id = t.id;
      msg := 'falha ' || t.id || ': ' || left(sqlerrm, 80);
    end;
  end if;

  -- 2) despacho: até 3 requisições em voo
  select count(*) into livres from cg_sync_compras_fila where estado = 'em_execucao';
  if livres < 3 then
    for d in select id, tipo, dia, modalidade, pagina from cg_sync_compras_fila
              where estado = 'pendente' order by id limit (3 - livres) for update skip locked loop
      update cg_sync_compras_fila set estado = 'em_execucao', tentativas = tentativas + 1, iniciado_em = now(),
             req_id = net.http_get(url := public.cg_sync_compras_url(d.tipo, d.dia, d.modalidade, d.pagina), timeout_milliseconds := 110000)
       where id = d.id;
    end loop;
  end if;
  return msg;
end $$;

revoke execute on function public.cg_sync_compras_planejar(integer), public.cg_sync_compras_tick(), public.cg_sync_compras_url(text, date, integer, integer) from public, anon, authenticated;