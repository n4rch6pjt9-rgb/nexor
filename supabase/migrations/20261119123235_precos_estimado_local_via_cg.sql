-- Estimado da /precos passa a vir do Compras.gov módulo 07 (cg_*), sem consulta ao PNCP.
-- 1) fila por idCompra (só compras de precos_praticados_itens que ainda NÃO existem em cg_*), 2) ponte cg_* -> precos_*.

create table public.cg_sync_compras_id_fila (
  id_compra text not null,
  parte text not null check (parte in ('contratacao','item')),
  pagina integer not null default 1 check (pagina >= 1),
  estado text not null default 'pendente' check (estado in ('pendente','em_execucao','ok','vazio','erro')),
  tentativas integer not null default 0,
  req_id bigint, linhas integer, erro text,
  iniciado_em timestamptz, concluido_em timestamptz,
  created_at timestamptz not null default now(),
  primary key (id_compra, parte, pagina)
);
create index cg_sync_compras_id_fila_estado_idx on public.cg_sync_compras_id_fila (estado, parte);
alter table public.cg_sync_compras_id_fila enable row level security;
revoke all on table public.cg_sync_compras_id_fila from anon, authenticated;
comment on table public.cg_sync_compras_id_fila is 'Backfill por idCompra do Compras.gov módulo 07 para compras de precos_praticados_itens. vazio = compra fora do módulo (ex.: Lei 8.666) ou item ainda não indexado; nunca é refeito, exceto vazio de item de compra recente.';

create or replace function public.cg_sync_compras_id_url(p_parte text, p_id text, p_pagina integer) returns text
language sql immutable set search_path = '' as $$
  select 'https://dadosabertos.compras.gov.br/modulo-contratacoes/' ||
    case p_parte when 'contratacao' then '1.1_consultarContratacoes_PNCP_14133_Id?tipo=idCompra&codigo=' || p_id || '&tamanhoPagina=10'
                 else '2.1_consultarItensContratacoes_PNCP_14133_Id?tipo=idCompra&codigo=' || p_id || '&tamanhoPagina=500' end
    || '&pagina=' || p_pagina $$;

-- Ponte: copia de cg_* para as tabelas que a api-precos já lê (idempotente; só compras presentes em precos_praticados_itens).
create or replace function public.precos_sincronizar_de_cg(p_ids text[] default null) returns integer
language plpgsql security definer set search_path = public as $$
declare n1 integer; n2 integer; n3 integer;
begin
  insert into precos_compras_contratacao (id_compra, encontrada, numero_controle_pncp, orgao_entidade_cnpj, ano_compra_pncp,
         sequencial_compra_pncp, link_sistema_origem, data_hora_atualizacao_compra, consultado_em)
  select c.id_compra, true, c.numero_controle_pncp, c.orgao_entidade_cnpj, c.ano_compra_pncp, c.sequencial_compra_pncp,
         nullif(btrim(c.link_sistema_origem), ''), c.data_atualizacao_pncp, now()
    from cg_contratacoes c
   where (p_ids is null or c.id_compra = any(p_ids))
     and exists (select 1 from precos_praticados_itens p where p.id_compra = c.id_compra)
  on conflict (id_compra) do update set encontrada = true, numero_controle_pncp = excluded.numero_controle_pncp,
         orgao_entidade_cnpj = excluded.orgao_entidade_cnpj, ano_compra_pncp = excluded.ano_compra_pncp,
         sequencial_compra_pncp = excluded.sequencial_compra_pncp, link_sistema_origem = excluded.link_sistema_origem,
         data_hora_atualizacao_compra = excluded.data_hora_atualizacao_compra, consultado_em = now(), updated_at = now();
  get diagnostics n1 = row_count;

  -- compra fora do módulo 07: marca como não encontrada (a api-precos mostra o motivo e segue com o link montado)
  insert into precos_compras_contratacao (id_compra, encontrada, consultado_em)
  select f.id_compra, false, now() from cg_sync_compras_id_fila f
   where f.parte = 'contratacao' and f.pagina = 1 and f.estado = 'vazio'
     and (p_ids is null or f.id_compra = any(p_ids))
     and not exists (select 1 from cg_contratacoes c where c.id_compra = f.id_compra)
  on conflict (id_compra) do update set encontrada = false, consultado_em = now(), updated_at = now()
   where precos_compras_contratacao.encontrada = false;
  get diagnostics n2 = row_count;

  insert into precos_itens_contratacao (id_compra, numero_item_compra, valor_unitario_estimado, valor_unitario_resultado,
         tem_resultado, numero_controle_pncp, data_atualizacao_pncp, last_synced_at)
  select distinct on (i.id_compra, i.numero_item_compra)
         i.id_compra, i.numero_item_compra, i.valor_unitario_estimado, i.valor_unitario_resultado,
         coalesce(i.valor_unitario_resultado > 0, false), c.numero_controle_pncp, c.data_atualizacao_pncp, now()
    from cg_contratacao_itens i
    left join cg_contratacoes c on c.id_compra = i.id_compra
   where i.numero_item_compra is not null
     and (p_ids is null or i.id_compra = any(p_ids))
     and exists (select 1 from precos_praticados_itens p where p.id_compra = i.id_compra)
   order by i.id_compra, i.numero_item_compra
  on conflict (id_compra, numero_item_compra) do update set valor_unitario_estimado = excluded.valor_unitario_estimado,
         valor_unitario_resultado = excluded.valor_unitario_resultado, tem_resultado = excluded.tem_resultado,
         numero_controle_pncp = excluded.numero_controle_pncp, data_atualizacao_pncp = excluded.data_atualizacao_pncp,
         last_synced_at = now(), updated_at = now();
  get diagnostics n3 = row_count;
  return n1 + n2 + n3;
end $$;

create or replace function public.cg_sync_compras_id_planejar() returns integer
language plpgsql security definer set search_path = public as $$
declare n integer; n2 integer;
begin
  insert into cg_sync_compras_id_fila (id_compra, parte, pagina)
  select distinct p.id_compra, x.parte, 1
    from precos_praticados_itens p cross join (values ('contratacao'), ('item')) x(parte)
   where p.id_compra ~ '^[0-9]{17}$'
     and ((x.parte = 'contratacao' and not exists (select 1 from cg_contratacoes c where c.id_compra = p.id_compra))
       or (x.parte = 'item' and not exists (select 1 from cg_contratacao_itens i where i.id_compra = p.id_compra)))
  on conflict do nothing;
  get diagnostics n = row_count;
  -- única reabertura: itens vazios de compra recente (defasagem de indexação de ~1 semana)
  update cg_sync_compras_id_fila set estado = 'pendente', tentativas = 0, erro = null, req_id = null
   where parte = 'item' and estado = 'vazio' and concluido_em < now() - interval '1 day'
     and id_compra in (select id_compra from precos_praticados_itens group by 1 having max(data_resultado) >= current_date - 14);
  get diagnostics n2 = row_count;
  return n + n2;
end $$;

create or replace function public.cg_sync_compras_id_tick() returns text
language plpgsql security definer set search_path = public, net as $$
declare v_parte text; r record; j jsonb; arr jsonb; acc jsonb := '[]'::jsonb; res jsonb := '[]'::jsonb; x jsonb;
        n integer; rest integer; livres integer; d record; msg text := ''; ids text[] := '{}';
begin
  update cg_sync_compras_id_fila set estado = case when tentativas >= 5 then 'erro' else 'pendente' end,
         erro = coalesce(erro, '') || ' [sem resposta]', req_id = null
   where estado = 'em_execucao' and iniciado_em < now() - interval '8 minutes';

  -- compra não encontrada: seus itens não existem, sem gastar requisição
  update cg_sync_compras_id_fila i set estado = 'vazio', linhas = 0, concluido_em = now()
   where i.parte = 'item' and i.estado = 'pendente'
     and exists (select 1 from cg_sync_compras_id_fila c where c.id_compra = i.id_compra and c.parte = 'contratacao'
                    and c.pagina = 1 and c.estado = 'vazio');

  -- coleta em lote: junta as respostas prontas de UMA parte e ingere uma vez (cg_ingest_* usam tabela temporária por transação)
  select f.parte into v_parte from cg_sync_compras_id_fila f join net._http_response h on h.id = f.req_id
   where f.estado = 'em_execucao' order by (f.parte = 'contratacao') desc, f.iniciado_em limit 1;
  if v_parte is not null then
    begin
      for r in select f.id_compra, f.pagina, h.status_code, h.content, h.error_msg
                 from cg_sync_compras_id_fila f join net._http_response h on h.id = f.req_id
                where f.estado = 'em_execucao' and f.parte = v_parte order by f.iniciado_em limit 25
                  for update of f skip locked loop
        begin
          if r.status_code is distinct from 200 or r.content is null then
            raise exception 'http %: %', coalesce(r.status_code::text, 'sem status'), left(coalesce(r.error_msg, r.content, ''), 100);
          end if;
          j := r.content::jsonb;
          arr := coalesce(j->'resultado', '[]'::jsonb);
          n := jsonb_array_length(arr);
          rest := coalesce((j->>'paginasRestantes')::integer, 0);
          acc := acc || arr;
          res := res || jsonb_build_array(jsonb_build_object('id', r.id_compra, 'pag', r.pagina, 'ok', true, 'n', n, 'rest', rest));
        exception when others then
          res := res || jsonb_build_array(jsonb_build_object('id', r.id_compra, 'pag', r.pagina, 'ok', false, 'erro', left(sqlerrm, 200)));
        end;
      end loop;

      if jsonb_array_length(acc) > 0 then
        if v_parte = 'contratacao' then perform public.cg_ingest_contratacoes(acc);
        else perform public.cg_ingest_itens(acc); end if;
      end if;

      for x in select * from jsonb_array_elements(res) loop
        if (x->>'ok')::boolean then
          update cg_sync_compras_id_fila
             set estado = case when (x->>'n')::integer = 0 and pagina = 1 then 'vazio' else 'ok' end,
                 linhas = (x->>'n')::integer, erro = null, req_id = null, concluido_em = now()
           where id_compra = x->>'id' and parte = v_parte and pagina = (x->>'pag')::integer;
          if (x->>'rest')::integer > 0 then
            insert into cg_sync_compras_id_fila (id_compra, parte, pagina) values (x->>'id', v_parte, (x->>'pag')::integer + 1) on conflict do nothing;
          end if;
          ids := ids || (x->>'id');
        else
          update cg_sync_compras_id_fila
             set estado = case when tentativas >= 5 then 'erro' else 'pendente' end, erro = x->>'erro', req_id = null
           where id_compra = x->>'id' and parte = v_parte and pagina = (x->>'pag')::integer;
        end if;
      end loop;
      if array_length(ids, 1) > 0 then perform public.precos_sincronizar_de_cg(ids); end if;
      msg := format('coletou %s: %s compras, %s linhas', v_parte, jsonb_array_length(res), jsonb_array_length(acc));
    exception when others then
      update cg_sync_compras_id_fila set estado = case when tentativas >= 5 then 'erro' else 'pendente' end,
             erro = left(sqlerrm, 300), req_id = null
       where estado = 'em_execucao' and parte = v_parte and req_id in (select id from net._http_response);
      msg := 'falha no lote ' || v_parte || ': ' || left(sqlerrm, 80);
    end;
  end if;

  -- despacho: até 24 requisições em voo; item só depois que a contratação existe em cg_contratacoes
  select count(*) into livres from cg_sync_compras_id_fila where estado = 'em_execucao';
  if livres < 24 then
    for d in select f.id_compra, f.parte, f.pagina from cg_sync_compras_id_fila f
              where f.estado = 'pendente'
                and (f.parte = 'contratacao' or exists (select 1 from cg_contratacoes c where c.id_compra = f.id_compra))
              order by (f.parte = 'contratacao') desc, f.id_compra limit (24 - livres)
                for update of f skip locked loop
      update cg_sync_compras_id_fila set estado = 'em_execucao', tentativas = tentativas + 1, iniciado_em = now(),
             req_id = net.http_get(url := public.cg_sync_compras_id_url(d.parte, d.id_compra, d.pagina), timeout_milliseconds := 110000)
       where id_compra = d.id_compra and parte = d.parte and pagina = d.pagina;
    end loop;
  end if;
  return msg;
end $$;

revoke execute on function public.cg_sync_compras_id_url(text, text, integer), public.precos_sincronizar_de_cg(text[]),
  public.cg_sync_compras_id_planejar(), public.cg_sync_compras_id_tick() from public, anon, authenticated;