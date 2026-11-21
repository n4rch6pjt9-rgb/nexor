create or replace function public.cg_sync_enfileirar(p_lote date, p_status text, p_uf text, p_modalidade text, p_pagina integer) returns boolean
language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  insert into cg_sync_fila (lote, status, uf, modalidade, pagina) values (p_lote, p_status, p_uf, p_modalidade, p_pagina) on conflict do nothing;
  get diagnostics n = row_count;
  return n > 0;
end $$;
revoke execute on function public.cg_sync_enfileirar(date, text, text, text, integer) from public, anon, authenticated;
grant execute on function public.cg_sync_enfileirar(date, text, text, text, integer) to service_role;