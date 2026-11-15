-- Nexor — validação das FKs/CHECK da reconciliação municipal (parte 3 de 3; DDL em 20261114100000).
-- VALIDATE CONSTRAINT só pega SHARE UPDATE EXCLUSIVE: leituras e escritas das tabelas continuam. Idempotente.

begin;
set local lock_timeout = '10s';

do $$
declare
  v record;
begin
  for v in
    select * from (values
      ('public.entidades', 'entidades_municipio_id_fkey'),
      ('public.unidades', 'unidades_municipio_id_fkey'),
      ('public.orgaos', 'orgaos_municipio_id_fkey'),
      ('public.uasgs', 'uasgs_municipio_id_fkey'),
      ('public.fornecedores', 'fornecedores_municipio_id_fkey'),
      ('public.licitacoes_externas', 'licitacoes_externas_municipio_id_fkey'),
      ('public.precos_praticados_itens', 'precos_praticados_itens_municipio_id_fkey'),
      ('public.precos_praticados_itens', 'precos_praticados_codigo_municipio_ibge_chk')
    ) x(tabela, constraint_name)
  loop
    if exists (
      select 1 from pg_constraint
       where conrelid = v.tabela::regclass
         and conname = v.constraint_name
         and not convalidated
    ) then
      execute format('alter table %s validate constraint %I', v.tabela, v.constraint_name);
    end if;
  end loop;
end $$;

commit;
