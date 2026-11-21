create or replace function public.cg_link_comprasnet(id_compra text) returns text
language sql immutable parallel safe set search_path = '' as $$
  select case when id_compra ~ '^[0-9]{10,}$'
    then 'https://cnetmobile.estaleiro.serpro.gov.br/comprasnet-web/public/compras/acompanhamento-compra?compra=' || id_compra end $$;

alter table public.cg_contratacoes
  add column if not exists link_comprasnet text generated always as (public.cg_link_comprasnet(id_compra)) stored;
comment on column public.cg_contratacoes.link_comprasnet is 'Link do acompanhamento da compra no ComprasNet, derivado de id_compra (padrão visto em 22/22 links reais do PNCP). Não substitui link_sistema_origem.';

create or replace view public.cg_contratacoes_pncp_v with (security_invoker = true) as
select v.*,
  b.site_url, b.pncp_orgao_id, b.pncp_unidade_id, b.pncp_municipio_id,
  b.fonte_orcamentaria_ids, b.normativo_base_ids, b.amparo_legal_ids, b.criterio_julgamento_ids,
  b.possui_emenda_parlamentar, b.exigencia_conteudo_nacional, b.permite_adesao, b.incentivo_produtivo_basico,
  b.tipo_margem_preferencia_id, b.tipo_margem_preferencia_nome, b.indicador_orcamento_sigiloso,
  b.link_sistema_origem, b.link_processo_eletronico,
  public.cg_link_pncp(v.numero_controle_pncp) as link_pncp,
  public.cg_link_especifico(b.link_sistema_origem) as link_origem_especifico,
  case when public.cg_link_especifico(b.link_sistema_origem) then btrim(b.link_sistema_origem)
       else coalesce(public.cg_link_comprasnet(v.id_compra), public.cg_link_pncp(v.numero_controle_pncp)) end as link_efetivo,
  public.cg_link_comprasnet(v.id_compra) as link_comprasnet
from public.cg_contratacoes_v v
left join public.cg_pncp_busca b on b.numero_controle_pncp = v.numero_controle_pncp;
revoke all on public.cg_contratacoes_pncp_v from anon, authenticated;