-- Cruzamento cg_orgaos (Compras.gov) x orgaos_compradores (view agregada de licitacoes_externas) por CNPJ (14 dígitos).
-- orgaos_compradores tem 1 CNPJ duplicado: dedup pela linha com mais licitações.
create or replace view public.cg_orgaos_compradores_v with (security_invoker = true) as
with oc as (
  select distinct on (regexp_replace(cnpj,'\D','','g'))
         regexp_replace(cnpj,'\D','','g') as cnpj_norm, id, nome, uf, municipio, qtd_licitacoes, valor_estimado_total,
         qtd_homologadas, valor_homologado, ultima_publicacao
  from public.orgaos_compradores
  where cnpj is not null
  order by regexp_replace(cnpj,'\D','','g'), qtd_licitacoes desc nulls last
)
select o.cnpj, o.razao_social, o.codigo_orgao, o.esfera_id, o.poder_id,
       oc.id as comprador_id, oc.nome as comprador_nome, oc.uf as comprador_uf, oc.municipio as comprador_municipio,
       oc.qtd_licitacoes, oc.valor_estimado_total, oc.qtd_homologadas, oc.valor_homologado, oc.ultima_publicacao,
       (oc.cnpj_norm is not null) as casou
from public.cg_orgaos o
left join oc on oc.cnpj_norm = o.cnpj;
comment on view public.cg_orgaos_compradores_v is 'cg_orgaos enriquecido com orgaos_compradores por CNPJ; casou=false quando o órgão do Compras.gov não aparece nas licitações externas.';
