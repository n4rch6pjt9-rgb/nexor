-- 20261121150000_sistema_s_selecao_fonte_obrigatoria.sql
-- Spec 0071, K-4 (correção 2). No Sistema S, grupo, classe e item são códigos do
-- portal, não do Sistema S inteiro: a classe "MATERIAIS ESPORTIVOS" é 20 na FIEMS
-- e 141 no Sesc BA; o grupo é prefixo do código com regra por portal; nCdProduto
-- é do portal. Logo, no catálogo `sistema_s` os níveis grupo, classe e item exigem
-- `fonte`. As palavras (global e do objeto) continuam valendo sem fonte.
-- `fonte` passa a referenciar `fontes_externas(slug)`: um slug digitado errado
-- vira erro, não seleção que nunca casa. Idempotente; a tabela estava vazia.

alter table public.tenant_coleta_selecao
  drop constraint if exists tenant_coleta_selecao_sistema_s_fonte_ck;
alter table public.tenant_coleta_selecao
  add constraint tenant_coleta_selecao_sistema_s_fonte_ck
  check (catalogo <> 'sistema_s' or nivel in ('palavra_global', 'palavra_objeto') or fonte is not null);

alter table public.tenant_coleta_selecao
  drop constraint if exists tenant_coleta_selecao_fonte_fk;
alter table public.tenant_coleta_selecao
  add constraint tenant_coleta_selecao_fonte_fk
  foreign key (fonte) references public.fontes_externas (slug) on update cascade on delete restrict;
