-- Coleta de preços praticados (Pesquisa de Preço do Compras.gov) dentro do Supabase, sem GitHub Actions.
-- Por PDM do catálogo, janela de compra dos últimos 60 dias (resultado chega com atraso). Upsert só reescreve se o conteúdo mudou.

create table public.precos_sync_fila (
  id bigint generated always as identity primary key,
  pdm integer not null,
  ini date not null, fim date not null,
  pagina integer not null default 1 check (pagina >= 1),
  estado text not null default 'pendente' check (estado in ('pendente','em_execucao','ok','vazio','erro')),
  tentativas integer not null default 0,
  req_id bigint, total_paginas integer, linhas integer, erro text,
  iniciado_em timestamptz, concluido_em timestamptz,
  created_at timestamptz not null default now(),
  unique (pdm, ini, fim, pagina)
);
create index precos_sync_fila_estado_idx on public.precos_sync_fila (estado, id);
alter table public.precos_sync_fila enable row level security;
revoke all on table public.precos_sync_fila from anon, authenticated;

create or replace function public.precos_sync_url(p_pdm integer, p_ini date, p_fim date, p_pagina integer) returns text
language sql immutable set search_path = '' as $$
  select 'https://dadosabertos.compras.gov.br/modulo-pesquisa-preco/1_consultarMaterial?tipo=codigoPdm&codigo=' || p_pdm
      || '&dataCompraInicio=' || p_ini || '&dataCompraFim=' || p_fim || '&tamanhoPagina=500&pagina=' || p_pagina $$;

create or replace function public.precos_ingest_praticados(p jsonb) returns integer
language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  with src as (
    select distinct on (e->>'idCompra', e->>'idItemCompra') e
      from jsonb_array_elements(p) e
     where nullif(e->>'idCompra','') is not null and nullif(e->>'idItemCompra','') is not null
     order by e->>'idCompra', e->>'idItemCompra', e->>'dataHoraAtualizacaoItem' desc nulls last
  )
  insert into precos_praticados_itens (
    id_compra, id_item_compra, numero_item_compra, codigo_item_catalogo, data_compra, forma, modalidade, criterio_julgamento,
    objeto_compra, data_hora_atualizacao_compra, quantidade, preco_unitario, percentual_maior_desconto, descricao_item,
    descricao_detalhada_item, marca, data_resultado, data_hora_atualizacao_item, sigla_unidade_fornecimento,
    nome_unidade_fornecimento, capacidade_unidade_fornecimento, sigla_unidade_medida, nome_unidade_medida, ni_fornecedor,
    nome_fornecedor, codigo_uasg, nome_uasg, codigo_orgao, nome_orgao, estado, codigo_municipio, municipio, poder, esfera,
    data_hora_atualizacao_uasg, codigo_classe, nome_classe, codigo_pdm, nome_pdm, id_compra_item, data_atualizacao_fato,
    payload_hash, last_synced_at)
  select e->>'idCompra', (e->>'idItemCompra')::bigint, nullif(e->>'numeroItemCompra','')::integer,
         nullif(e->>'codigoItemCatalogo','')::integer, nullif(e->>'dataCompra','')::date, nullif(btrim(e->>'forma'),''),
         nullif(e->>'modalidade','')::integer, nullif(btrim(e->>'criterioJulgamento'),''), nullif(btrim(e->>'objetoCompra'),''),
         nullif(e->>'dataHoraAtualizacaoCompra','')::timestamptz, nullif(e->>'quantidade','')::numeric,
         nullif(e->>'precoUnitario','')::numeric, nullif(e->>'percentualMaiorDesconto','')::numeric,
         nullif(btrim(e->>'descricaoItem'),''), nullif(btrim(e->>'descricaoDetalhadaItem'),''), nullif(btrim(e->>'marca'),''),
         nullif(e->>'dataResultado','')::date, nullif(e->>'dataHoraAtualizacaoItem','')::timestamptz,
         nullif(btrim(e->>'siglaUnidadeFornecimento'),''), nullif(btrim(e->>'nomeUnidadeFornecimento'),''),
         nullif(e->>'capacidadeUnidadeFornecimento','')::numeric, nullif(btrim(e->>'siglaUnidadeMedida'),''),
         nullif(btrim(e->>'nomeUnidadeMedida'),''), nullif(btrim(e->>'niFornecedor'),''), nullif(btrim(e->>'nomeFornecedor'),''),
         nullif(btrim(e->>'codigoUasg'),''), nullif(btrim(e->>'nomeUasg'),''), nullif(e->>'codigoOrgao','')::integer,
         nullif(btrim(e->>'nomeOrgao'),''), nullif(btrim(e->>'estado'),''), nullif(e->>'codigoMunicipio','')::integer,
         nullif(btrim(e->>'municipio'),''), nullif(btrim(e->>'poder'),''), nullif(btrim(e->>'esfera'),''),
         nullif(e->>'dataHoraAtualizacaoUasg','')::timestamptz, nullif(e->>'codigoClasse','')::integer,
         nullif(btrim(e->>'nomeClasse'),''), nullif(btrim(e->>'codigoPdm'),''), nullif(btrim(e->>'nomePdm'),''),
         nullif(btrim(e->>'idCompraItem'),''), nullif(e->>'dataAtualizacaoFato','')::timestamptz,
         encode(sha256(convert_to(e::text, 'UTF8')), 'hex'), now()
    from src
  on conflict (id_compra, id_item_compra) do update set
    numero_item_compra = excluded.numero_item_compra, codigo_item_catalogo = excluded.codigo_item_catalogo,
    data_compra = excluded.data_compra, forma = excluded.forma, modalidade = excluded.modalidade,
    criterio_julgamento = excluded.criterio_julgamento, objeto_compra = excluded.objeto_compra,
    data_hora_atualizacao_compra = excluded.data_hora_atualizacao_compra, quantidade = excluded.quantidade,
    preco_unitario = excluded.preco_unitario, percentual_maior_desconto = excluded.percentual_maior_desconto,
    descricao_item = excluded.descricao_item, descricao_detalhada_item = excluded.descricao_detalhada_item,
    marca = excluded.marca, data_resultado = excluded.data_resultado,
    data_hora_atualizacao_item = excluded.data_hora_atualizacao_item,
    sigla_unidade_fornecimento = excluded.sigla_unidade_fornecimento, nome_unidade_fornecimento = excluded.nome_unidade_fornecimento,
    capacidade_unidade_fornecimento = excluded.capacidade_unidade_fornecimento, sigla_unidade_medida = excluded.sigla_unidade_medida,
    nome_unidade_medida = excluded.nome_unidade_medida, ni_fornecedor = excluded.ni_fornecedor,
    nome_fornecedor = excluded.nome_fornecedor, codigo_uasg = excluded.codigo_uasg, nome_uasg = excluded.nome_uasg,
    codigo_orgao = excluded.codigo_orgao, nome_orgao = excluded.nome_orgao, estado = excluded.estado,
    codigo_municipio = excluded.codigo_municipio, municipio = excluded.municipio, poder = excluded.poder, esfera = excluded.esfera,
    data_hora_atualizacao_uasg = excluded.data_hora_atualizacao_uasg, codigo_classe = excluded.codigo_classe,
    nome_classe = excluded.nome_classe, codigo_pdm = excluded.codigo_pdm, nome_pdm = excluded.nome_pdm,
    id_compra_item = excluded.id_compra_item, data_atualizacao_fato = excluded.data_atualizacao_fato,
    payload_hash = excluded.payload_hash, last_synced_at = now(), updated_at = now()
  where precos_praticados_itens.payload_hash is distinct from excluded.payload_hash;
  get diagnostics n = row_count;
  return n;
end $$;

create or replace function public.precos_sync_planejar(p_dias integer default 60) returns integer
language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  delete from precos_sync_fila where estado in ('ok','vazio') and concluido_em < now() - interval '15 days';
  insert into precos_sync_fila (pdm, ini, fim, pagina)
  select pd.codigo_pdm::integer, current_date - p_dias, current_date + 1, 1
    from catalogo_catmat_pdms_efetivos() pd
  on conflict do nothing;
  get diagnostics n = row_count;
  return n;
end $$;

create or replace function public.precos_sync_tick() returns text
language plpgsql security definer set search_path = public, net as $$
declare r record; j jsonb; arr jsonb; n integer; rest integer; gravadas integer; livres integer; d record; msg text := '';
begin
  update precos_sync_fila set estado = case when tentativas >= 5 then 'erro' else 'pendente' end,
         erro = coalesce(erro,'') || ' [sem resposta]', req_id = null
   where estado = 'em_execucao' and iniciado_em < now() - interval '8 minutes';

  for r in select f.id, f.pdm, f.ini, f.fim, f.pagina, f.tentativas, h.status_code, h.content, h.error_msg
             from precos_sync_fila f join net._http_response h on h.id = f.req_id
            where f.estado = 'em_execucao' order by f.id limit 10 for update of f skip locked loop
    begin
      if r.status_code is distinct from 200 or r.content is null then
        raise exception 'http %: %', coalesce(r.status_code::text,'sem status'), left(coalesce(r.error_msg, r.content, ''), 120);
      end if;
      j := r.content::jsonb;
      arr := coalesce(j->'resultado', '[]'::jsonb);
      n := jsonb_array_length(arr);
      rest := coalesce((j->>'paginasRestantes')::integer, 0);
      gravadas := case when n > 0 then public.precos_ingest_praticados(arr) else 0 end;
      update precos_sync_fila set estado = case when n = 0 and pagina = 1 then 'vazio' else 'ok' end, linhas = n,
             total_paginas = (j->>'totalPaginas')::integer, erro = null, req_id = null, concluido_em = now() where id = r.id;
      if rest > 0 then
        insert into precos_sync_fila (pdm, ini, fim, pagina) values (r.pdm, r.ini, r.fim, r.pagina + 1) on conflict do nothing;
      end if;
      msg := msg || format('pdm %s p%s: %s recebidas, %s gravadas; ', r.pdm, r.pagina, n, gravadas);
    exception when others then
      update precos_sync_fila set estado = case when r.tentativas >= 5 then 'erro' else 'pendente' end,
             erro = left(sqlerrm, 300), req_id = null where id = r.id;
      msg := msg || 'falha ' || r.id || ': ' || left(sqlerrm, 80) || '; ';
    end;
  end loop;

  select count(*) into livres from precos_sync_fila where estado = 'em_execucao';
  if livres < 4 then
    for d in select id, pdm, ini, fim, pagina from precos_sync_fila where estado = 'pendente' order by id
              limit (4 - livres) for update skip locked loop
      update precos_sync_fila set estado = 'em_execucao', tentativas = tentativas + 1, iniciado_em = now(),
             req_id = net.http_get(url := public.precos_sync_url(d.pdm, d.ini, d.fim, d.pagina), timeout_milliseconds := 110000)
       where id = d.id;
    end loop;
  end if;
  return msg;
end $$;

revoke execute on function public.precos_sync_url(integer, date, date, integer), public.precos_ingest_praticados(jsonb),
  public.precos_sync_planejar(integer), public.precos_sync_tick() from public, anon, authenticated;