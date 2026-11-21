-- 20261121140000_sistema_s_selecao_sem_pdm.sql
-- Spec 0071, K-4 (correção). O Sistema S não tem PDM: o catálogo é nativo
-- (Grupo → Classe → Produto/item, nCdProduto). A seleção por tenant passa a
-- saber de qual catálogo a camada vem:
--   catmat    : palavra_global → palavra_objeto → grupo → classe → pdm → item
--   sistema_s : palavra_global → palavra_objeto → grupo → classe → item
-- `pdm` fica proibido no catálogo `sistema_s`. Sem ponte obrigatória com o CATMAT.
-- Idempotente. A tabela estava vazia na aplicação; linhas antigas (se houver)
-- ficam como `catmat`, o comportamento anterior.

alter table public.tenant_coleta_selecao
  add column if not exists catalogo text not null default 'catmat';

alter table public.tenant_coleta_selecao
  drop constraint if exists tenant_coleta_selecao_catalogo_ck;
alter table public.tenant_coleta_selecao
  add constraint tenant_coleta_selecao_catalogo_ck
  check (catalogo in ('catmat', 'sistema_s'));

alter table public.tenant_coleta_selecao
  drop constraint if exists tenant_coleta_selecao_catalogo_nivel_ck;
alter table public.tenant_coleta_selecao
  add constraint tenant_coleta_selecao_catalogo_nivel_ck
  check (catalogo = 'catmat' or nivel <> 'pdm');

-- unicidade passa a considerar o catálogo
drop index if exists public.tenant_coleta_selecao_uq;
create unique index tenant_coleta_selecao_uq on public.tenant_coleta_selecao
  (tenant_id, catalogo, nivel, coalesce(fonte, ''), coalesce(termo_pai, ''), coalesce(termo, ''), coalesce(codigo, ''));

drop index if exists public.tenant_coleta_selecao_tenant_idx;
create index tenant_coleta_selecao_tenant_idx on public.tenant_coleta_selecao
  (tenant_id, catalogo, nivel) where incluido;

comment on column public.tenant_coleta_selecao.catalogo is
  'catmat (inclui pdm) ou sistema_s (grupo/classe/item nativos, sem pdm). Spec 0071 K-4.';
comment on column public.tenant_coleta_selecao.codigo is
  'Código da camada. No sistema_s, nível item = nCdProduto do portal; grupo e classe são os códigos nativos do portal.';

-- prontidão: seleções por catálogo (colunas novas só no fim, a view já existe)
create or replace view public.v_tenant_coleta_prontidao
with (security_invoker = true) as
select
  t.id as tenant_id,
  t.slug,
  (select count(*) from public.tenant_coleta_selecao s
    where s.tenant_id = t.id and s.incluido) as n_selecoes_incluidas,
  exists (select 1 from public.tenant_coleta_visitante v
           where v.tenant_id = t.id and v.completo) as visitante_completo,
  (select v.campos_faltantes from public.tenant_coleta_visitante v
    where v.tenant_id = t.id
    order by (v.fonte is null) desc
    limit 1) as campos_faltantes_visitante,
  (select count(*) from public.tenant_coleta_selecao s
    where s.tenant_id = t.id and s.incluido and s.catalogo = 'sistema_s') as n_selecoes_sistema_s
from public.tenants t
where t.ativo;
