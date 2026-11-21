-- Preço homologado por item x modalidade (com órgão e fornecedor), detalhe por órgão/fornecedor
-- e fase do ciclo de vida da contratação (oportunidade / acompanhamento / historico).
-- Views somente-leitura sobre cg_* (nenhuma escrita). security_invoker=true + acesso só para service_role.
-- Guardado por to_regclass: as tabelas cg_* de produção não têm migration neste repo (drift conhecido);
-- em banco limpo (validar-migrations.sh) a migration é no-op.

do $mig$
begin
  if to_regclass('public.cg_contratacoes') is null
     or to_regclass('public.cg_contratacao_itens') is null
     or to_regclass('public.cg_item_resultados') is null
     or to_regclass('public.cg_modalidades') is null
     or to_regclass('public.cg_orgaos') is null
     or to_regclass('public.cg_unidades') is null then
    raise notice 'cg_* ausente: views de preco homologado nao criadas (no-op)';
    return;
  end if;

  execute $v1$
create or replace view public.v_preco_homologado_item with (security_invoker = true) as
with r as (
  select x.id_compra_item, x.id_compra, x.numero_item_pncp,
         x.ni_fornecedor::text as fornecedor_ni,
         x.valor_unitario_homologado::numeric as valor_unitario,
         x.quantidade_homologada::numeric as quantidade,
         x.data_resultado_pncp as data_ref,
         x.unidade_orgao_uf_sigla as uf_resultado,
         'cg_item_resultados'::text as fonte
    from public.cg_item_resultados x
   where x.situacao_resultado_id = 1
     and x.valor_unitario_homologado > 0 and x.valor_unitario_homologado < 100000000
), i as (
  select t.id_compra_item, t.id_compra, t.numero_item_pncp,
         t.cod_fornecedor::text as fornecedor_ni,
         t.valor_unitario_resultado::numeric as valor_unitario,
         t.quantidade_resultado::numeric as quantidade,
         t.data_resultado as data_ref,
         null::text as uf_resultado,
         'cg_contratacao_itens'::text as fonte
    from public.cg_contratacao_itens t
   where t.valor_unitario_resultado > 0 and t.valor_unitario_resultado < 100000000
     and coalesce(t.situacao_compra_item, '') not in ('3','4','5')
     and not exists (select 1 from public.cg_item_resultados x where x.id_compra_item = t.id_compra_item)
), u as (
  select * from r union all select * from i
), base as (
  select u.id_compra_item, u.id_compra, u.numero_item_pncp, it.cod_item_catalogo,
         c.modalidade_id_pncp, m.nome as modalidade_nome, c.srp,
         (c.modalidade_id_pncp = 9) as sem_competicao,
         c.orgao_entidade_cnpj as orgao_cnpj, c.codigo_orgao,
         o.razao_social as orgao_nome,
         coalesce(un.uf, u.uf_resultado) as orgao_uf,
         c.unidade_orgao_codigo_unidade as unidade_codigo, un.nome as unidade_nome,
         u.fornecedor_ni, it.nome_fornecedor as fornecedor_nome,
         coalesce(u.data_ref, c.data_publicacao_pncp) as data_referencia,
         u.valor_unitario, u.quantidade, it.unidade_medida, u.fonte
    from u
    join public.cg_contratacoes c on c.id_compra = u.id_compra
    left join public.cg_contratacao_itens it on it.id_compra_item = u.id_compra_item
    left join public.cg_modalidades m on m.modalidade_id_pncp = c.modalidade_id_pncp
    left join public.cg_orgaos o on o.cnpj = c.orgao_entidade_cnpj
    left join public.cg_unidades un on un.orgao_cnpj = c.orgao_entidade_cnpj and un.codigo_unidade = c.unidade_orgao_codigo_unidade
   where c.situacao_compra_id_pncp = 1 and not coalesce(c.contratacao_excluida, false)
), med as (
  select cod_item_catalogo, (percentile_cont(0.5) within group (order by valor_unitario))::numeric as mediana_item
    from base where cod_item_catalogo is not null group by cod_item_catalogo
)
select b.*, md.mediana_item,
       (md.mediana_item is not null and md.mediana_item > 0
        and (b.valor_unitario > 20 * md.mediana_item or b.valor_unitario < md.mediana_item / 20.0)) as eh_outlier
  from base b left join med md using (cod_item_catalogo)
  $v1$;

  execute $v2$
create or replace view public.v_preco_item_modalidade_resumo with (security_invoker = true) as
select cod_item_catalogo, modalidade_id_pncp, modalidade_nome, sem_competicao,
       count(*) filter (where not eh_outlier) as n_resultados,
       count(*) filter (where eh_outlier) as n_outliers,
       count(distinct fornecedor_ni) filter (where not eh_outlier) as n_fornecedores,
       count(distinct orgao_cnpj) filter (where not eh_outlier) as n_orgaos,
       min(valor_unitario) filter (where not eh_outlier) as preco_min,
       (percentile_cont(0.25) within group (order by valor_unitario) filter (where not eh_outlier))::numeric as preco_p25,
       (percentile_cont(0.5) within group (order by valor_unitario) filter (where not eh_outlier))::numeric as preco_mediana,
       (percentile_cont(0.75) within group (order by valor_unitario) filter (where not eh_outlier))::numeric as preco_p75,
       max(valor_unitario) filter (where not eh_outlier) as preco_max,
       (array_agg(valor_unitario order by data_referencia desc nulls last) filter (where not eh_outlier))[1] as preco_ultimo,
       max(data_referencia) filter (where not eh_outlier) as data_ultimo,
       case when (percentile_cont(0.5) within group (order by valor_unitario) filter (where not eh_outlier))::numeric > 0
            then max(valor_unitario) filter (where not eh_outlier)
               / ((percentile_cont(0.5) within group (order by valor_unitario) filter (where not eh_outlier))::numeric) end as razao_max_mediana,
       (array_agg(orgao_cnpj order by valor_unitario asc) filter (where not eh_outlier))[1] as orgao_cnpj_menor_preco,
       (array_agg(orgao_nome order by valor_unitario asc) filter (where not eh_outlier))[1] as orgao_nome_menor_preco,
       (array_agg(fornecedor_ni order by valor_unitario asc) filter (where not eh_outlier))[1] as fornecedor_ni_menor_preco,
       (array_agg(fornecedor_nome order by valor_unitario asc) filter (where not eh_outlier))[1] as fornecedor_nome_menor_preco,
       (array_agg(orgao_cnpj order by data_referencia desc nulls last) filter (where not eh_outlier))[1] as orgao_cnpj_ultimo,
       (array_agg(orgao_nome order by data_referencia desc nulls last) filter (where not eh_outlier))[1] as orgao_nome_ultimo,
       (array_agg(fornecedor_ni order by data_referencia desc nulls last) filter (where not eh_outlier))[1] as fornecedor_ni_ultimo,
       (array_agg(fornecedor_nome order by data_referencia desc nulls last) filter (where not eh_outlier))[1] as fornecedor_nome_ultimo
  from public.v_preco_homologado_item
 where cod_item_catalogo is not null
 group by cod_item_catalogo, modalidade_id_pncp, modalidade_nome, sem_competicao
  $v2$;

  execute $v3$
create or replace view public.v_preco_item_detalhe with (security_invoker = true) as
select cod_item_catalogo, 'orgao'::text as dimensao,
       orgao_cnpj as chave, max(orgao_nome) as nome, max(orgao_uf) as uf,
       count(*) filter (where not eh_outlier) as n_resultados,
       count(*) filter (where eh_outlier) as n_outliers,
       count(*) filter (where sem_competicao and not eh_outlier) as n_sem_competicao,
       (percentile_cont(0.5) within group (order by valor_unitario) filter (where not eh_outlier))::numeric as preco_mediana,
       min(valor_unitario) filter (where not eh_outlier) as preco_min,
       (array_agg(valor_unitario order by data_referencia desc nulls last) filter (where not eh_outlier))[1] as preco_ultimo,
       max(data_referencia) filter (where not eh_outlier) as data_ultimo
  from public.v_preco_homologado_item
 where cod_item_catalogo is not null and orgao_cnpj is not null
 group by cod_item_catalogo, orgao_cnpj
union all
select cod_item_catalogo, 'fornecedor'::text,
       fornecedor_ni, max(fornecedor_nome), null::text,
       count(*) filter (where not eh_outlier),
       count(*) filter (where eh_outlier),
       count(*) filter (where sem_competicao and not eh_outlier),
       (percentile_cont(0.5) within group (order by valor_unitario) filter (where not eh_outlier))::numeric,
       min(valor_unitario) filter (where not eh_outlier),
       (array_agg(valor_unitario order by data_referencia desc nulls last) filter (where not eh_outlier))[1],
       max(data_referencia) filter (where not eh_outlier)
  from public.v_preco_homologado_item
 where cod_item_catalogo is not null and fornecedor_ni is not null
 group by cod_item_catalogo, fornecedor_ni
  $v3$;

  execute $v4$
create or replace view public.v_contratacao_fase with (security_invoker = true) as
select c.id_compra, c.modalidade_id_pncp, m.nome as modalidade_nome, c.srp,
       c.situacao_compra_id_pncp, c.data_encerramento_proposta_pncp,
       c.orgao_entidade_cnpj as orgao_cnpj, c.codigo_orgao,
       (h.id_compra is not null) as tem_item_homologado,
       case
         when c.situacao_compra_id_pncp in (2,3,4) then 'acompanhamento'
         when h.id_compra is not null then 'historico'
         when c.modalidade_id_pncp in (8,9) and c.data_encerramento_proposta_pncp is null then 'historico'
         when c.data_encerramento_proposta_pncp > now() and c.situacao_compra_id_pncp = 1 then 'oportunidade'
         else 'acompanhamento'
       end as fase,
       (c.modalidade_id_pncp = 9) as sem_competicao,
       (c.modalidade_id_pncp = 8 and c.data_encerramento_proposta_pncp > now()
        and c.situacao_compra_id_pncp = 1) as eh_dispensa_aberta
  from public.cg_contratacoes c
  left join public.cg_modalidades m on m.modalidade_id_pncp = c.modalidade_id_pncp
  left join (
    select id_compra from public.cg_item_resultados
     where situacao_resultado_id = 1 and valor_unitario_homologado > 0 and valor_unitario_homologado < 100000000
    union
    select id_compra from public.cg_contratacao_itens
     where valor_unitario_resultado > 0 and valor_unitario_resultado < 100000000
       and coalesce(situacao_compra_item, '') not in ('3','4','5')
  ) h on h.id_compra = c.id_compra
 where not coalesce(c.contratacao_excluida, false)
  $v4$;

  execute 'revoke all on public.v_preco_homologado_item, public.v_preco_item_modalidade_resumo, public.v_preco_item_detalhe, public.v_contratacao_fase from public, anon, authenticated';
  execute 'grant select on public.v_preco_homologado_item, public.v_preco_item_modalidade_resumo, public.v_preco_item_detalhe, public.v_contratacao_fase to service_role';

  execute $c$comment on view public.v_preco_homologado_item is 'Preco unitario homologado por item (cg_item_resultados sit.1 + cg_contratacao_itens sem resultado detalhado). Inclui orgao, unidade, UF, fornecedor, sem_competicao (inexigibilidade) e eh_outlier (>20x ou <1/20 da mediana do item).'$c$;
  execute $c$comment on view public.v_preco_item_modalidade_resumo is 'Item catalogo x modalidade: n, orgaos/fornecedores distintos, min/p25/mediana/p75/max, ultimo, orgao e fornecedor do menor preco e do mais recente. Estatisticas sem outliers.'$c$;
  execute $c$comment on view public.v_preco_item_detalhe is 'Item x orgao e item x fornecedor (coluna dimensao): n, mediana, menor, ultimo preco, n_sem_competicao, n_outliers.'$c$;
  execute $c$comment on view public.v_contratacao_fase is 'Fase da contratacao: oportunidade (prazo aberto e sit.1), acompanhamento (prazo findado sem item homologado ou sit.2/3/4), historico (item homologado; dispensa/inexigibilidade sem prazo nascem em historico). eh_dispensa_aberta = dispensa com prazo aberto.'$c$;
end
$mig$;
