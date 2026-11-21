-- Publica em licitacoes_externas (lista do dashboard de oportunidades) o que a busca do PNCP espelhada em
-- cg_pncp_busca já trouxe, sem GitHub Actions. Substitui o coletor-pncp.py para as oportunidades novas.
-- Idempotente: só grava se payload_hash mudou; prioridade só avança (leads -> monitorar -> historico);
-- nunca sobrescreve categoria_escopo, interesse_borracha nem termos_busca de linha existente.
-- Só service_role executa.

create or replace function public.licext_publicar_de_pncp_busca(p_dias integer default 60)
 returns table(candidatos integer, inseridos integer, atualizados integer)
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare
  v_cand int; v_ins int; v_upd int;
begin
  create temp table _lic_pub on commit drop as
  with t(termo, padrao, cat, ord) as (values
    ('borracha granulada',        'BORRACHA GRANULADA',                         'borracha', 1),
    ('granulado de borracha',     'GRANULADO DE BORRACHA',                      'borracha', 2),
    ('raspa de borracha',         'RASPA DE BORRACHA',                          'borracha', 3),
    ('piso emborrachado',         'PISO EMBORRACHADO',                          'piso',     4),
    ('grama sintética',           'GRAMA SINTETICA',                            'piso',     5),
    ('campo society',             'CAMPO SOCIETY',                              'piso',     6),
    ('equipamentos de musculação','EQUIPAMENTOS? DE MUSCULACAO',                'fraco',    7),
    ('equipamentos de academia',  'EQUIPAMENTOS? DE ACADEMIA',                  'fraco',    8),
    ('aparelhos de ginástica',    'APARELHOS? DE GINASTICA',                    'fraco',    9),
    ('material esportivo',        'MATERIAL ESPORTIVO|MATERIAIS ESPORTIVOS',    'fraco',   10),
    ('parque infantil',           'PARQUE INFANTIL|PARQUES INFANTIS',           'fraco',   11),
    ('academia ao ar livre',      'ACADEMIA AO AR LIVRE|ACADEMIAS AO AR LIVRE', 'fraco',   12)
  ),
  base as (
    select b.*, public.objeto_normalizar(coalesce(b.raw->>'description','')) o
      from public.cg_pncp_busca b
     where b.data_atualizacao_pncp >= now() - make_interval(days => p_dias)
  ),
  casados as (
    select b.numero_controle_pncp,
           array_agg(t.termo order by t.ord) termos,
           (array_agg(t.cat order by t.ord))[1] cat_base
      from base b join t on b.o ~ t.padrao
     group by 1
  )
  select b.*, c.termos,
         case when c.cat_base = 'piso'
                   and b.o ~ 'OBRA|CONSTRUCAO|REFORMA|ENGENHARIA|IMPLANTACAO|REVITALIZ|CONSTRUIR'
              then 'obra_piso' else c.cat_base end cat_final
    from base b join casados c using (numero_controle_pncp);

  select count(*) into v_cand from _lic_pub;

  with up as (
    insert into public.licitacoes_externas as l (
      fonte, modulo, id_externo, codigo_externo, numero_processo, numero_edital,
      objeto, unidade_compradora, modalidade, fase, situacao, data_inicio, data_fim, data_publicacao,
      valor_total, orgao_cnpj, orgao_nome, municipio, uf, categoria_escopo, interesse_borracha,
      termos_busca, prioridade, link_sistema_origem, pncp_data_atualizacao, amparo_legal, raw,
      payload_hash, ingestao_origem, ingestao_em, last_synced_at)
    select 'pncp', null, null, p.numero_controle_pncp,
           nullif(coalesce(p.raw->>'numero','') || '/' || coalesce(p.raw->>'ano',''), '/'),
           coalesce(p.raw->>'modalidade_licitacao_nome','') || ' nº ' || regexp_replace(coalesce(p.raw->>'title',''), '^[^º]*º\s*', ''),
           p.raw->>'description', p.unidade_nome, p.raw->>'modalidade_licitacao_nome',
           case when p.tem_resultado then 'Homologada / com resultado'
                when p.status_pncp = 'recebendo_proposta' then 'Recebendo propostas'
                when p.status_pncp = 'propostas_encerradas' then 'Em julgamento'
                else 'Encerrada (itens finalizados)' end,
           p.situacao_nome, p.data_inicio_vigencia, p.data_fim_vigencia, p.data_publicacao_pncp,
           p.valor_total_estimado, p.orgao_cnpj, p.orgao_nome, p.raw->>'municipio_nome', p.uf,
           p.cat_final, (p.cat_final <> 'fraco'), p.termos,
           case when p.tem_resultado or p.cancelado then 'historico'
                when p.status_pncp = 'recebendo_proposta' then 'leads'
                when p.status_pncp = 'propostas_encerradas' then 'monitorar'
                else 'historico' end,
           nullif(btrim(p.link_sistema_origem), ''), p.data_atualizacao_pncp,
           case when p.raw->'amparo_legal_nome'->>0 is not null
                then jsonb_build_object('nome', p.raw->'amparo_legal_nome'->>0,
                                        'codigo', nullif(p.raw->'amparo_legal_id'->>0,'')::int) end,
           p.raw, p.payload_hash, 'cron', now(), now()
      from _lic_pub p
    on conflict (fonte, codigo_externo) do update set
      fase = excluded.fase, situacao = excluded.situacao,
      data_inicio = excluded.data_inicio, data_fim = excluded.data_fim,
      valor_total = excluded.valor_total, pncp_data_atualizacao = excluded.pncp_data_atualizacao,
      link_sistema_origem = coalesce(excluded.link_sistema_origem, l.link_sistema_origem),
      raw = excluded.raw, payload_hash = excluded.payload_hash,
      prioridade = case
        when coalesce(array_position(array['leads','monitorar','historico'], excluded.prioridade),0)
           > coalesce(array_position(array['leads','monitorar','historico'], l.prioridade),0)
        then excluded.prioridade else l.prioridade end,
      last_synced_at = now(), updated_at = now()
    where l.payload_hash is distinct from excluded.payload_hash
    returning (xmax = 0) as ins
  )
  select count(*) filter (where ins), count(*) filter (where not ins) into v_ins, v_upd from up;

  return query select v_cand, v_ins, v_upd;
end
$function$;

revoke all on function public.licext_publicar_de_pncp_busca(integer) from public, anon, authenticated;
grant execute on function public.licext_publicar_de_pncp_busca(integer) to service_role;
