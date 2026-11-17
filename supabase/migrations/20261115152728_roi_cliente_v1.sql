-- ROI do cliente, v1 (specs/roi-cliente.md)
-- Aditiva: função roi_cnpj_raiz, coluna pipeline_oportunidades.origem, view v_roi_oportunidade, função roi_cliente_resumo.
-- Acesso: só service_role.

create or replace function public.roi_cnpj_raiz(p_cnpj text)
returns text
language sql
immutable
parallel safe
as $$
  select case when length(d.v) = 14 then left(d.v, 8) end
    from (select regexp_replace(coalesce(p_cnpj, ''), '\D', '', 'g') as v) d
$$;

comment on function public.roi_cnpj_raiz(text) is
  'Raiz do CNPJ (8 primeiros dígitos) ou NULL se não houver 14 dígitos. Vencedor de licitação costuma ser filial; o casamento com o tenant é pela raiz.';

alter table public.pipeline_oportunidades
  add column if not exists origem text check (origem in ('plataforma', 'manual'));

comment on column public.pipeline_oportunidades.origem is
  'plataforma | manual | NULL (não classificada). Base da atribuição do ROI: só origem = plataforma entra no ROI atribuído.';

create or replace view public.v_roi_oportunidade as
select
  po.tenant_id,
  po.licitacao_id,
  cn.canonica_id,
  e.nome                                   as etapa_nome,
  e.desfecho,
  po.origem,
  po.adicionada_em,
  case when e.desfecho is not null
       then coalesce(h.desfecho_em, po.atualizada_em) end   as desfecho_em,
  po.preco_ofertado_centavos,
  po.motivo_perda,
  coalesce(g.itens_ganhos, 0)              as itens_ganhos,
  coalesce(rs.n_vencedores, 0)             as n_vencedores_oficiais,
  g.valor_homologado_ganho                 as valor_vitoria_oficial,
  g.hom_com_estimado,
  g.valor_estimado_ganho,
  case when e.desfecho = 'vencida' then
         case when coalesce(g.itens_ganhos, 0) > 0 then g.valor_homologado_ganho
              else po.preco_ofertado_centavos / 100.0 end
  end                                      as valor_ganho,
  case when e.desfecho = 'vencida' then
         case when coalesce(g.itens_ganhos, 0) > 0 then 'oficial'
              when po.preco_ofertado_centavos is not null then 'manual' end
  end                                      as fonte_valor,
  case when e.desfecho = 'perdida'
        and po.preco_ofertado_centavos > 0
        and rs.n_vencedores = 1
        and rs.valor_vencedor_total > 0
       then round(po.preco_ofertado_centavos / 100.0 / rs.valor_vencedor_total - 1, 4)
  end                                      as gap_preco_pct,
  case
    when e.desfecho = 'descartada'                                    then 'descartada'
    when e.desfecho = 'vencida' and coalesce(g.itens_ganhos, 0) > 0   then 'vencida_confirmada'
    when e.desfecho = 'vencida' and rs.n_vencedores > 0               then 'divergencia_vencida_sem_vitoria_oficial'
    when e.desfecho = 'vencida'                                       then 'vencida_sem_fonte'
    when e.desfecho = 'perdida' and coalesce(g.itens_ganhos, 0) > 0   then 'divergencia_perdida_com_vitoria_oficial'
    when e.desfecho = 'perdida' and rs.n_vencedores > 0               then 'perdida_confirmada'
    when e.desfecho = 'perdida'                                       then 'perdida_sem_fonte'
    when coalesce(g.itens_ganhos, 0) > 0                              then 'vitoria_nao_registrada'
    else 'em_andamento'
  end                                      as situacao_roi
from pipeline_oportunidades po
join pipeline_etapas e on e.id = po.etapa_id and e.tenant_id = po.tenant_id
join tenants t on t.id = po.tenant_id
join licitacoes_pncp_canonica cn on cn.id = po.licitacao_id
left join lateral (
  select max(x.em) as desfecho_em
    from pipeline_historico x
   where x.tenant_id = po.tenant_id
     and x.licitacao_id = po.licitacao_id
     and x.etapa_para = po.etapa_id
) h on true
left join lateral (
  select count(*)                          filter (where r.vencedor is true) as n_vencedores,
         sum(r.valor_total_homologado)     filter (where r.vencedor is true) as valor_vencedor_total
    from licitacao_resultados r
   where r.licitacao_id = cn.canonica_id
     and coalesce(r.situacao, '') <> 'Cancelado'
) rs on true
left join lateral (
  select count(*)                                          as itens_ganhos,
         sum(x.hom)                                        as valor_homologado_ganho,
         sum(x.hom) filter (where x.est > 0)               as hom_com_estimado,
         sum(x.est) filter (where x.est > 0)               as valor_estimado_ganho
    from (
      select r.numero_item,
             sum(r.valor_total_homologado)  as hom,
             max(i.valor_total_estimado)    as est
        from licitacao_resultados r
        left join licitacao_itens i
               on i.licitacao_id = r.licitacao_id and i.numero_item = r.numero_item
       where r.licitacao_id = cn.canonica_id
         and r.vencedor is true
         and coalesce(r.situacao, '') <> 'Cancelado'
         and public.roi_cnpj_raiz(r.fornecedor_cnpj) = public.roi_cnpj_raiz(t.cnpj)
       group by r.numero_item
    ) x
) g on true;

comment on view public.v_roi_oportunidade is
  'ROI do cliente v1: uma linha por oportunidade do pipeline. situacao_roi cruza o desfecho do time com o resultado oficial (CNPJ raiz do tenant). Só service_role.';

create or replace function public.roi_cliente_resumo(
  p_tenant bigint,
  p_desde  timestamptz default date_trunc('year', now()),
  p_ate    timestamptz default now()
)
returns table (
  captadas               bigint,
  decididas              bigint,
  vencidas               bigint,
  perdidas               bigint,
  descartadas            bigint,
  taxa_vitoria           numeric,
  valor_ganho            numeric,
  valor_ganho_oficial    numeric,
  valor_ganho_manual     numeric,
  valor_ganho_originado  numeric,
  ticket_medio           numeric,
  desconto_medio         numeric,
  vencidas_sem_fonte     bigint,
  alertas_divergencia    bigint
)
language sql
stable
set search_path to 'public', 'pg_temp'
as $$
  with b as (
    select v.*,
           (v.desfecho_em >= p_desde and v.desfecho_em <= p_ate) as no_periodo
      from public.v_roi_oportunidade v
     where v.tenant_id = p_tenant
  )
  select
    count(*) filter (where adicionada_em >= p_desde and adicionada_em <= p_ate),
    count(*) filter (where desfecho in ('vencida', 'perdida') and no_periodo),
    count(*) filter (where desfecho = 'vencida'    and no_periodo),
    count(*) filter (where desfecho = 'perdida'    and no_periodo),
    count(*) filter (where desfecho = 'descartada' and no_periodo),
    (count(*) filter (where desfecho = 'vencida' and no_periodo))::numeric
      / nullif(count(*) filter (where desfecho in ('vencida', 'perdida') and no_periodo), 0),
    coalesce(sum(valor_ganho) filter (where desfecho = 'vencida' and no_periodo), 0),
    coalesce(sum(valor_ganho) filter (where desfecho = 'vencida' and no_periodo and fonte_valor = 'oficial'), 0),
    coalesce(sum(valor_ganho) filter (where desfecho = 'vencida' and no_periodo and fonte_valor = 'manual'), 0),
    coalesce(sum(valor_ganho) filter (where desfecho = 'vencida' and no_periodo and origem = 'plataforma'), 0),
    sum(valor_ganho) filter (where desfecho = 'vencida' and no_periodo)
      / nullif(count(*) filter (where desfecho = 'vencida' and no_periodo and valor_ganho is not null), 0),
    1 - sum(hom_com_estimado)    filter (where desfecho = 'vencida' and no_periodo and fonte_valor = 'oficial')
      / nullif(sum(valor_estimado_ganho) filter (where desfecho = 'vencida' and no_periodo and fonte_valor = 'oficial'), 0),
    count(*) filter (where situacao_roi = 'vencida_sem_fonte' and no_periodo),
    count(*) filter (where situacao_roi in (
      'vitoria_nao_registrada',
      'divergencia_vencida_sem_vitoria_oficial',
      'divergencia_perdida_com_vitoria_oficial'))
  from b
$$;

comment on function public.roi_cliente_resumo(bigint, timestamptz, timestamptz) is
  'Números do painel de ROI do cliente (valor ganho, taxa de vitória, ticket, desconto) para um tenant e período. Só service_role.';

revoke all on public.v_roi_oportunidade from public, anon, authenticated;
grant select on public.v_roi_oportunidade to service_role;

revoke all on function public.roi_cliente_resumo(bigint, timestamptz, timestamptz) from public, anon, authenticated;
grant execute on function public.roi_cliente_resumo(bigint, timestamptz, timestamptz) to service_role;
