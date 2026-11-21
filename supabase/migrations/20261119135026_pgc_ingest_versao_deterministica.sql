
create or replace function public.pgc_versao(r jsonb)
returns text language sql immutable set search_path = ''
as $$ select greatest(coalesce(r->>'dataHoraAtualizacaoItem',''), coalesce(r->>'dataHoraAtualizacaoDfd',''),
                      coalesce(r->>'dataHoraAtualizacaoArtefato',''), coalesce(r->>'dataHoraAtualizacaoProjetoCompra','')) $$;

create or replace function public.pgc_ingest_itens(p jsonb)
returns integer
language plpgsql
security definer
set search_path = public
as $fn$
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

  update public.pca_pgc_itens t set last_synced_at = now()
    from _pgc_m m
   where t.orgao_cnpj = m.orgao_cnpj and t.codigo_uasg = m.codigo_uasg
     and t.ano_pca_projeto_compra = m.ano_pca_projeto_compra
     and t.numero_item_pncp is not distinct from m.numero_item_pncp
     and t.codigo_item_catalogo is not distinct from m.codigo_item_catalogo
     and t.last_synced_at < now();

  return v_gravadas;
end
$fn$;
revoke all on function public.pgc_ingest_itens(jsonb), public.pgc_versao(jsonb) from public, anon, authenticated;
