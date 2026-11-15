-- Nexor — backfill da reconciliação municipal (parte 2 de 3; DDL em 20261114100000).
-- Só dados: UPDATE/INSERT usam lock de linha, sem ACCESS EXCLUSIVE. Idempotente (on conflict / is null).
-- Backfill somente por campos explicitamente identificados como IBGE. Sem correspondência não inventa vínculo.
-- Não faz backfill de licitacoes_externas (lê o raw jsonb de todas as linhas): o coletor PNCP preenche
-- municipio_id nos próximos upserts, e um backfill em lote pode ser feito à parte se for necessário.

begin;
set local lock_timeout = '10s';

with observados as (
  select nullif(btrim(e.municipio_ibge), '') as codigo_ibge,
         nullif(btrim(e.municipio_nome), '') as nome, upper(nullif(btrim(e.uf), '')) as uf
    from public.entidades e
  union all
  select nullif(btrim(f.codigo_municipio_ibge::text), ''), nullif(btrim(f.municipio), ''),
         upper(nullif(btrim(f.uf), ''))
    from public.fornecedores f
  union all
  select nullif(btrim(u.codigo_municipio_ibge::text), ''), nullif(btrim(u.nome_municipio_ibge), ''),
         upper(nullif(btrim(u.sigla_uf), ''))
    from public.uasgs u
), validos as (
  -- Descarta nome que normaliza para NULL (ex.: '-', '.'): violaria municipios_nome_normalizado_chk.
  select codigo_ibge, nome, uf
    from observados
   where codigo_ibge ~ '^\d{7}$'
     and uf ~ '^[A-Z]{2}$'
     and private.normalizar_nome_municipio(nome) is not null
), unicos as (
  select codigo_ibge,
         -- Nome canônico determinístico: prefere variante que não está toda em caixa alta, depois ordem alfabética.
         (array_agg(nome order by (nome = upper(nome)), nome))[1] as nome,
         min(uf) as uf
    from validos
   group by codigo_ibge
  having count(distinct private.normalizar_nome_municipio(nome)) = 1
     and count(distinct uf) = 1
)
insert into public.municipios (codigo_ibge, nome, uf, status, fonte_canonica, evidencias)
select codigo_ibge, nome, uf, 'confirmado', 'codigo_ibge:backfill_fontes',
       jsonb_build_object('origem', 'backfill_migration_20261114100100', 'campos', 'codigo_municipio_ibge/codigo_ibge')
  from unicos
on conflict (codigo_ibge) where codigo_ibge is not null do nothing;

-- Caso de referência PNCP Navegantes. A chave IBGE é canônica; os dois suggest.id ficam pendentes,
-- pois o contrato semântico do campo id ainda não foi confirmado.
insert into public.municipios (codigo_ibge, nome, uf, status, fonte_canonica, evidencias)
values (
  '4211306', 'Navegantes', 'SC', 'confirmado', 'codigo_ibge:referencia_validada',
  jsonb_build_object('origem', 'caso_pncp_navegantes', 'data_evidencia', '2026-11-14')
)
on conflict (codigo_ibge) where codigo_ibge is not null do nothing;

insert into public.municipio_referencias_externas (
  fonte, namespace, valor_externo, municipio_id, candidato_municipio_id,
  nome_observado, uf_observada, status, metodo_resolucao, evidencias
)
select 'pncp', 'suggest_municipio', v.valor_externo, null, m.id,
       'Navegantes', 'SC', 'pendente', 'nome_uf',
       jsonb_build_object(
         'endpoint', '/api/search/suggest',
         'parametros', jsonb_build_object('tipos_documento', 'edital', 'campo', 'municipios', 'q', 'nave', 'tam_pagina', 200),
         'total_observado', v.total,
         'motivo_pendencia', 'semantica_de_suggest_id_ainda_nao_confirmada',
         'data_evidencia', '2026-11-14'
       )
  from (values ('4211306', 937), ('4480', 2)) as v(valor_externo, total)
  join public.municipios m on m.codigo_ibge = '4211306'
on conflict (fonte, namespace, valor_externo) do nothing;

-- FK a partir de IBGE já armazenado. Nunca usa codigo_municipio sem sufixo IBGE.
update public.entidades e
   set municipio_id = m.id
  from public.municipios m
 where e.municipio_id is null and e.municipio_ibge = m.codigo_ibge;

update public.unidades u
   set municipio_id = m.id
  from public.municipios m
 where u.municipio_id is null and u.municipio_ibge = m.codigo_ibge;

update public.orgaos o
   set municipio_id = m.id
  from public.municipios m
 where o.municipio_id is null and o.municipio_ibge = m.codigo_ibge;

update public.uasgs u
   set municipio_id = m.id
  from public.municipios m
 where u.municipio_id is null and u.codigo_municipio_ibge::text = m.codigo_ibge;

update public.fornecedores f
   set municipio_id = m.id
  from public.municipios m
 where f.municipio_id is null and f.codigo_municipio_ibge::text = m.codigo_ibge;

-- Referências verificadas geradas a partir dos campos IBGE existentes (fonte + namespace, sem misturar IDs).
insert into public.municipio_referencias_externas (
  fonte, namespace, valor_externo, municipio_id, nome_observado, uf_observada,
  status, metodo_resolucao, evidencias, verificado_em
)
select distinct 'pncp', 'codigo_ibge', m.codigo_ibge, m.id, m.nome, m.uf,
       'verificado', 'codigo_ibge', jsonb_build_object('origem', 'backfill_entidades_unidades'), now()
  from public.municipios m
 where exists (select 1 from public.entidades e where e.municipio_ibge = m.codigo_ibge)
    or exists (select 1 from public.unidades u where u.municipio_ibge = m.codigo_ibge)
    or exists (select 1 from public.orgaos o where o.municipio_ibge = m.codigo_ibge)
on conflict (fonte, namespace, valor_externo) do nothing;

insert into public.municipio_referencias_externas (
  fonte, namespace, valor_externo, municipio_id, nome_observado, uf_observada,
  status, metodo_resolucao, evidencias, verificado_em
)
select distinct 'comprasgov', 'codigo_municipio_ibge', m.codigo_ibge, m.id, m.nome, m.uf,
       'verificado', 'codigo_ibge', jsonb_build_object('origem', 'backfill_uasgs'), now()
  from public.municipios m
 where exists (select 1 from public.uasgs u where u.codigo_municipio_ibge::text = m.codigo_ibge)
on conflict (fonte, namespace, valor_externo) do nothing;

-- O DTO oficial de UASG traz codigoMunicipio e codigoMunicipioIbge no mesmo registro.
-- Só essa coocorrência permite confirmar o ID próprio do Compras.gov como alias do município IBGE, e somente
-- quando o mesmo codigoMunicipio nunca aparece com IBGE, UF ou nome diferentes (senão não há alias confiável).
with uasg as (
  select u.codigo_municipio::text as codigo_municipio,
         u.codigo_municipio_ibge::text as codigo_ibge,
         upper(u.sigla_uf) as uf,
         u.nome_municipio_ibge as nome,
         private.normalizar_nome_municipio(u.nome_municipio_ibge) as nome_norm
    from public.uasgs u
   where u.codigo_municipio is not null
     and u.codigo_municipio_ibge is not null
), alvo as (
  select codigo_municipio,
         min(codigo_ibge) as codigo_ibge, min(uf) as uf, min(nome_norm) as nome_norm, min(nome) as nome
    from uasg
   group by codigo_municipio
  having count(distinct codigo_ibge) = 1
     and count(distinct uf) = 1
     and count(distinct nome_norm) = 1
)
insert into public.municipio_referencias_externas (
  fonte, namespace, valor_externo, municipio_id, nome_observado, uf_observada,
  status, metodo_resolucao, evidencias, verificado_em
)
select 'comprasgov', 'codigo_municipio', a.codigo_municipio, m.id, a.nome, a.uf, 'verificado', 'codigo_ibge',
       jsonb_build_object(
         'origem', 'backfill_uasgs',
         'campos_coocorrentes', jsonb_build_array('codigoMunicipio', 'codigoMunicipioIbge'),
         'codigo_municipio_ibge', a.codigo_ibge
       ), now()
  from alvo a
  join public.municipios m on m.codigo_ibge = a.codigo_ibge
 where a.uf = m.uf
   and a.nome_norm = m.nome_normalizado
on conflict (fonte, namespace, valor_externo) do nothing;

commit;
