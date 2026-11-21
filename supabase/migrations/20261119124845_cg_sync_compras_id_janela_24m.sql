create or replace function public.cg_sync_compras_id_planejar() returns integer
language plpgsql security definer set search_path = public as $$
declare n integer; n2 integer;
begin
  insert into cg_sync_compras_id_fila (id_compra, parte, pagina)
  select p.id_compra, x.parte, 1
    from (select id_compra from precos_praticados_itens
           where id_compra ~ '^[0-9]{17}$' group by id_compra
          having max(data_resultado) >= current_date - interval '24 months') p
    cross join (values ('contratacao'), ('item')) x(parte)
   where ((x.parte = 'contratacao' and not exists (select 1 from cg_contratacoes c where c.id_compra = p.id_compra))
       or (x.parte = 'item' and not exists (select 1 from cg_contratacao_itens i where i.id_compra = p.id_compra)))
  on conflict do nothing;
  get diagnostics n = row_count;
  update cg_sync_compras_id_fila set estado = 'pendente', tentativas = 0, erro = null, req_id = null
   where parte = 'item' and estado = 'vazio' and concluido_em < now() - interval '1 day'
     and id_compra in (select id_compra from precos_praticados_itens group by 1 having max(data_resultado) >= current_date - 14);
  get diagnostics n2 = row_count;
  return n + n2;
end $$;
revoke execute on function public.cg_sync_compras_id_planejar() from public, anon, authenticated;

delete from public.cg_sync_compras_id_fila f
 where f.estado = 'pendente'
   and f.id_compra in (select id_compra from precos_praticados_itens group by 1 having max(data_resultado) < current_date - interval '24 months');