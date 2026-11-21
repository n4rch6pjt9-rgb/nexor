-- Coleta do PGC (Compras.gov Dados Abertos, módulo PGC) dentro do banco: fila + tick via pg_net + pg_cron.
-- Substitui o coletor do GitHub Actions. Escopo: classes de material 7830 e 7220, ano atual e o seguinte.
-- Idempotente. Tudo fechado para anon/authenticated; só service_role executa.

create table if not exists public.pgc_sync_fila (
  id bigint generated always as identity primary key,
  ano integer not null,
  classe integer not null,
  pagina integer not null default 1,
  estado text not null default 'pendente',
  tentativas integer not null default 0,
  req_id bigint,
  total_paginas integer,
  linhas integer,
  erro text,
  iniciado_em timestamp with time zone,
  concluido_em timestamp with time zone,
  created_at timestamp with time zone not null default now(),
  unique (ano, classe, pagina),
  constraint pgc_sync_fila_estado_check check (estado in ('pendente', 'em_execucao', 'ok', 'vazio', 'erro'))
);

alter table public.pgc_sync_fila enable row level security;
revoke all on table public.pgc_sync_fila from public, anon, authenticated;
grant all on table public.pgc_sync_fila to service_role;

-- Versão de um registro do PGC: o maior timestamp de atualização entre item, DFD, artefato e projeto.
create or replace function public.pgc_versao(r jsonb)
 returns text
 language sql
 immutable
 set search_path to ''
as $function$ select greatest(coalesce(r->>'dataHoraAtualizacaoItem',''), coalesce(r->>'dataHoraAtualizacaoDfd',''),
                      coalesce(r->>'dataHoraAtualizacaoArtefato',''), coalesce(r->>'dataHoraAtualizacaoProjetoCompra','')) $function$;

create or replace function public.pgc_sync_url(p_ano integer, p_classe integer, p_pagina integer)
 returns text
 language sql
 immutable
 set search_path to ''
as $function$ select 'https://dadosabertos.compras.gov.br/modulo-pgc/2_consultarPgcDetalheCatalogo?tipo=Material&codigo=' || p_classe
  || '&anoPcaProjetoCompra=' || p_ano || '&tamanhoPagina=500&pagina=' || p_pagina $function$;

-- Grava uma página do PGC em pca_pgc_itens. Idempotente: só grava se mudou e se a versão que chegou é a mais nova.
create or replace function public.pgc_ingest_itens(p jsonb)
 returns integer
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare v_gravadas integer;
begin
  create temp table _pgc_m on commit drop as
  select distinct on (orgao_cnpj, codigo_uasg, ano_pca_projeto_compra, numero_item_pncp, codigo_item_catalogo) *
  from (
    select
      r->>'codigoUasg' as codigo_uasg, r->>'nomeUasg' as nome_uasg, r->>'orgao' as orgao_cnpj,
      nullif(r->>'numeroArtefato','')::int as numero_artefato, nullif(r->>'anoArtefato','')::int as ano_artefato,
      nullif(r->>'codigoEstadoArtefato','')::int as codigo_estado_artefato,
      nullif(r->>'codigoCategoriaArtefato','')::int as codigo_categoria_artefato,
      r->>'descricaoArtefato' as descricao_artefato, nullif(r->>'codigoTipoArtefato','')::int as codigo_tipo_artefato,
      nullif(r->>'ordemDfd','')::int as ordem_dfd, r->>'descricaoObjetoDfd' as descricao_objeto_dfd,
      r->>'nivelPrioridadeDfd' as nivel_prioridade_dfd,
      (nullif(r->>'dataPrevistaFormalizacaoDemanda','')::timestamp)::date as data_prevista_formalizacao_demanda,
      nullif(r->>'codigoAreaDfd','')::int as codigo_area_dfd, r->>'tipoItem' as tipo_item,
      nullif(r->>'itemSustentavel','')::boolean as item_sustentavel,
      nullif(r->>'codigoGrupoMaterial','')::int as codigo_grupo_material, r->>'nomeGrupoMaterial' as nome_grupo_material,
      nullif(r->>'codigoClasseMaterial','')::int as codigo_classe_material, r->>'nomeClasseMaterial' as nome_classe_material,
      r->>'codigoPdmMaterial' as codigo_pdm_material, r->>'nomePdmMaterial' as nome_pdm_material,
      nullif(r->>'codigoItemCatalogo','')::int as codigo_item_catalogo, r->>'descricaoItemCatalogo' as descricao_item_catalogo,
      r->>'siglaUnidadeFornecimento' as sigla_unidade_fornecimento, r->>'nomeUnidadeFornecimento' as nome_unidade_fornecimento,
      nullif(r->>'quantidadeItem','')::numeric as quantidade_item, nullif(r->>'valorUnitarioItem','')::numeric as valor_unitario_item,
      nullif(r->>'valorTotalItem','')::numeric as valor_total_item,
      r->>'tituloProjetoCompra' as titulo_projeto_compra, r->>'descricaoProjetoCompra' as descricao_projeto_compra,
      nullif(r->>'anoPcaProjetoCompra','')::int as ano_pca_projeto_compra,
      (nullif(r->>'dataInicioProcessoCompra','')::timestamp)::date as data_inicio_processo_compra,
      (nullif(r->>'dataFimProcessoCompra','')::timestamp)::date as data_fim_processo_compra,
      nullif(r->>'duracaoProcessoCompra','')::int as duracao_processo_compra,
      nullif(r->>'numeroItemPncp','')::int as numero_item_pncp, r->>'statusContratacaoExecucao' as status_contratacao_execucao,
      (nullif(r->>'dataHoraPublicacaoPncp','')::timestamp) at time zone 'UTC' as data_hora_publicacao_pncp,
      (nullif(r->>'dataHoraAtualizacaoItem','')::timestamp) at time zone 'UTC' as data_hora_atualizacao_item,
      r as raw, encode(sha256(convert_to(r::text, 'UTF8')), 'hex') as payload_hash, public.pgc_versao(r) as versao
    from jsonb_array_elements(p) e(r)
  ) s
  where orgao_cnpj is not null and codigo_uasg is not null and ano_pca_projeto_compra is not null
  order by orgao_cnpj, codigo_uasg, ano_pca_projeto_compra, numero_item_pncp, codigo_item_catalogo,
           versao desc, payload_hash desc;

  with up as (
    insert into public.pca_pgc_itens as t (
      codigo_uasg, nome_uasg, orgao_cnpj, numero_artefato, ano_artefato, codigo_estado_artefato, codigo_categoria_artefato,
      descricao_artefato, codigo_tipo_artefato, ordem_dfd, descricao_objeto_dfd, nivel_prioridade_dfd,
      data_prevista_formalizacao_demanda, codigo_area_dfd, tipo_item, item_sustentavel, codigo_grupo_material,
      nome_grupo_material, codigo_classe_material, nome_classe_material, codigo_pdm_material, nome_pdm_material,
      codigo_item_catalogo, descricao_item_catalogo, sigla_unidade_fornecimento, nome_unidade_fornecimento,
      quantidade_item, valor_unitario_item, valor_total_item, titulo_projeto_compra, descricao_projeto_compra,
      ano_pca_projeto_compra, data_inicio_processo_compra, data_fim_processo_compra, duracao_processo_compra,
      numero_item_pncp, status_contratacao_execucao, data_hora_publicacao_pncp, data_hora_atualizacao_item,
      raw, payload_hash, last_synced_at, updated_at)
    select codigo_uasg, nome_uasg, orgao_cnpj, numero_artefato, ano_artefato, codigo_estado_artefato, codigo_categoria_artefato,
      descricao_artefato, codigo_tipo_artefato, ordem_dfd, descricao_objeto_dfd, nivel_prioridade_dfd,
      data_prevista_formalizacao_demanda, codigo_area_dfd, tipo_item, item_sustentavel, codigo_grupo_material,
      nome_grupo_material, codigo_classe_material, nome_classe_material, codigo_pdm_material, nome_pdm_material,
      codigo_item_catalogo, descricao_item_catalogo, sigla_unidade_fornecimento, nome_unidade_fornecimento,
      quantidade_item, valor_unitario_item, valor_total_item, titulo_projeto_compra, descricao_projeto_compra,
      ano_pca_projeto_compra, data_inicio_processo_compra, data_fim_processo_compra, duracao_processo_compra,
      numero_item_pncp, status_contratacao_execucao, data_hora_publicacao_pncp, data_hora_atualizacao_item,
      raw, payload_hash, now(), now()
    from _pgc_m
    on conflict on constraint uq_pca_pgc_item do update set
      nome_uasg = excluded.nome_uasg, numero_artefato = excluded.numero_artefato, ano_artefato = excluded.ano_artefato,
      codigo_estado_artefato = excluded.codigo_estado_artefato, codigo_categoria_artefato = excluded.codigo_categoria_artefato,
      descricao_artefato = excluded.descricao_artefato, codigo_tipo_artefato = excluded.codigo_tipo_artefato,
      ordem_dfd = excluded.ordem_dfd, descricao_objeto_dfd = excluded.descricao_objeto_dfd,
      nivel_prioridade_dfd = excluded.nivel_prioridade_dfd,
      data_prevista_formalizacao_demanda = excluded.data_prevista_formalizacao_demanda,
      codigo_area_dfd = excluded.codigo_area_dfd, tipo_item = excluded.tipo_item, item_sustentavel = excluded.item_sustentavel,
      codigo_grupo_material = excluded.codigo_grupo_material, nome_grupo_material = excluded.nome_grupo_material,
      codigo_classe_material = excluded.codigo_classe_material, nome_classe_material = excluded.nome_classe_material,
      codigo_pdm_material = excluded.codigo_pdm_material, nome_pdm_material = excluded.nome_pdm_material,
      descricao_item_catalogo = excluded.descricao_item_catalogo, sigla_unidade_fornecimento = excluded.sigla_unidade_fornecimento,
      nome_unidade_fornecimento = excluded.nome_unidade_fornecimento, quantidade_item = excluded.quantidade_item,
      valor_unitario_item = excluded.valor_unitario_item, valor_total_item = excluded.valor_total_item,
      titulo_projeto_compra = excluded.titulo_projeto_compra, descricao_projeto_compra = excluded.descricao_projeto_compra,
      data_inicio_processo_compra = excluded.data_inicio_processo_compra, data_fim_processo_compra = excluded.data_fim_processo_compra,
      duracao_processo_compra = excluded.duracao_processo_compra, status_contratacao_execucao = excluded.status_contratacao_execucao,
      data_hora_publicacao_pncp = excluded.data_hora_publicacao_pncp, data_hora_atualizacao_item = excluded.data_hora_atualizacao_item,
      raw = excluded.raw, payload_hash = excluded.payload_hash, last_synced_at = now(), updated_at = now()
    -- Só grava se mudou E a versão que chegou é a mais nova (timestamp, depois hash): a API repete a mesma chave em
    -- páginas diferentes com conteúdos diferentes, e a ordem das páginas não pode decidir o resultado.
    where t.payload_hash is distinct from excluded.payload_hash
      and (public.pgc_versao(excluded.raw), excluded.payload_hash) > (public.pgc_versao(t.raw), t.payload_hash)
    returning 1
  )
  select count(*) into v_gravadas from up;

  -- Renova last_synced_at de toda linha lida e inalterada: o alerta "dias sem coleta do PGC" usa max(last_synced_at).
  update public.pca_pgc_itens t set last_synced_at = now()
    from _pgc_m m
   where t.orgao_cnpj = m.orgao_cnpj and t.codigo_uasg = m.codigo_uasg
     and t.ano_pca_projeto_compra = m.ano_pca_projeto_compra
     and t.numero_item_pncp is not distinct from m.numero_item_pncp
     and t.codigo_item_catalogo is not distinct from m.codigo_item_catalogo
     and t.last_synced_at < now();

  return v_gravadas;
end
$function$;

create or replace function public.pgc_sync_planejar()
 returns integer
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare n integer;
begin
  -- Rodadas concluídas há mais de 12h saem da fila para a coleta se repetir (diária).
  delete from pgc_sync_fila where estado in ('ok','vazio','erro') and coalesce(concluido_em, created_at) < now() - interval '12 hours';
  -- Escopo do catálogo: classes de material 7830 (equipamento de ginástica e recreação) e 7220 (revestimentos para pisos).
  insert into pgc_sync_fila (ano, classe, pagina)
  select a, c, 1
    from unnest(array[extract(year from current_date)::int, extract(year from current_date)::int + 1]) a,
         unnest(array[7830, 7220]) c
  on conflict do nothing;
  get diagnostics n = row_count;
  return n;
end $function$;

create or replace function public.pgc_sync_tick()
 returns text
 language plpgsql
 security definer
 set search_path to 'public', 'net'
as $function$
declare r record; j jsonb; arr jsonb; n integer; rest integer; gravadas integer; livres integer; d record; msg text := '';
begin
  update pgc_sync_fila set estado = case when tentativas >= 5 then 'erro' else 'pendente' end,
         erro = coalesce(erro,'') || ' [sem resposta]', req_id = null
   where estado = 'em_execucao' and iniciado_em < now() - interval '8 minutes';

  for r in select f.id, f.ano, f.classe, f.pagina, f.tentativas, h.status_code, h.content, h.error_msg
             from pgc_sync_fila f join net._http_response h on h.id = f.req_id
            where f.estado = 'em_execucao' order by f.id limit 3 for update of f skip locked loop
    begin
      if r.status_code is distinct from 200 or r.content is null then
        raise exception 'http %: %', coalesce(r.status_code::text,'sem status'), left(coalesce(r.error_msg, r.content, ''), 120);
      end if;
      j := r.content::jsonb;
      arr := coalesce(j->'resultado', '[]'::jsonb);
      n := jsonb_array_length(arr);
      rest := coalesce((j->>'paginasRestantes')::integer, 0);
      if n > 0 then
        drop table if exists pg_temp._pgc_m;
        gravadas := public.pgc_ingest_itens(arr);
      else
        gravadas := 0;
      end if;
      update pgc_sync_fila set estado = case when n = 0 and pagina = 1 then 'vazio' else 'ok' end, linhas = n,
             total_paginas = (j->>'totalPaginas')::integer, erro = null, req_id = null, concluido_em = now() where id = r.id;
      if rest > 0 then
        insert into pgc_sync_fila (ano, classe, pagina) values (r.ano, r.classe, r.pagina + 1) on conflict do nothing;
      end if;
      msg := msg || format('%s/%s p%s: %s lidas, %s gravadas; ', r.ano, r.classe, r.pagina, n, gravadas);
    exception when others then
      update pgc_sync_fila set estado = case when r.tentativas >= 5 then 'erro' else 'pendente' end,
             erro = left(sqlerrm, 300), req_id = null where id = r.id;
      msg := msg || 'falha ' || r.id || ': ' || left(sqlerrm, 80) || '; ';
    end;
  end loop;

  select count(*) into livres from pgc_sync_fila where estado = 'em_execucao';
  if livres < 2 then
    for d in select id, ano, classe, pagina from pgc_sync_fila where estado = 'pendente' order by id
              limit (2 - livres) for update skip locked loop
      update pgc_sync_fila set estado = 'em_execucao', tentativas = tentativas + 1, iniciado_em = now(),
             req_id = net.http_get(url := public.pgc_sync_url(d.ano, d.classe, d.pagina), timeout_milliseconds := 110000)
       where id = d.id;
    end loop;
  end if;
  return msg;
end $function$;

-- ACL: nada de EXECUTE herdado de PUBLIC nem de anon/authenticated (funcoes_acl_check); só service_role executa.
revoke all on function public.pgc_versao(jsonb) from public, anon, authenticated;
revoke all on function public.pgc_sync_url(integer, integer, integer) from public, anon, authenticated;
revoke all on function public.pgc_ingest_itens(jsonb) from public, anon, authenticated;
revoke all on function public.pgc_sync_planejar() from public, anon, authenticated;
revoke all on function public.pgc_sync_tick() from public, anon, authenticated;
grant execute on function public.pgc_versao(jsonb) to service_role;
grant execute on function public.pgc_sync_url(integer, integer, integer) to service_role;
grant execute on function public.pgc_ingest_itens(jsonb) to service_role;
grant execute on function public.pgc_sync_planejar() to service_role;
grant execute on function public.pgc_sync_tick() to service_role;
