
create or replace function public.pgc_sync_tick()
returns text
language plpgsql
security definer
set search_path = public, net
as $fn$
declare r record; j jsonb; arr jsonb; n integer; rest integer; gravadas integer; livres integer; d record; msg text := '';
begin
  update pgc_sync_fila set estado = case when tentativas >= 5 then 'erro' else 'pendente' end,
         erro = coalesce(erro,'') || ' [sem resposta]', req_id = null
   where estado = 'em_execucao' and iniciado_em < now() - interval '8 minutes';

  for r in select f.id, f.ano, f.classe, f.pagina, f.tentativas, h.status_code, h.content, h.error_msg
             from pgc_sync_fila f join net._http_response h on h.id = f.req_id
            where f.estado = 'em_execucao' order by f.id limit 3 for update of f skip locked loop
    begin
      if r.status_code is distinct from 200 or r.content is null then
        raise exception 'http %: %', coalesce(r.status_code::text,'sem status'), left(coalesce(r.error_msg, r.content, ''), 120);
      end if;
      j := r.content::jsonb;
      arr := coalesce(j->'resultado', '[]'::jsonb);
      n := jsonb_array_length(arr);
      rest := coalesce((j->>'paginasRestantes')::integer, 0);
      if n > 0 then
        drop table if exists pg_temp._pgc_m;
        gravadas := public.pgc_ingest_itens(arr);
      else
        gravadas := 0;
      end if;
      update pgc_sync_fila set estado = case when n = 0 and pagina = 1 then 'vazio' else 'ok' end, linhas = n,
             total_paginas = (j->>'totalPaginas')::integer, erro = null, req_id = null, concluido_em = now() where id = r.id;
      if rest > 0 then
        insert into pgc_sync_fila (ano, classe, pagina) values (r.ano, r.classe, r.pagina + 1) on conflict do nothing;
      end if;
      msg := msg || format('%s/%s p%s: %s lidas, %s gravadas; ', r.ano, r.classe, r.pagina, n, gravadas);
    exception when others then
      update pgc_sync_fila set estado = case when r.tentativas >= 5 then 'erro' else 'pendente' end,
             erro = left(sqlerrm, 300), req_id = null where id = r.id;
      msg := msg || 'falha ' || r.id || ': ' || left(sqlerrm, 80) || '; ';
    end;
  end loop;

  select count(*) into livres from pgc_sync_fila where estado = 'em_execucao';
  if livres < 2 then
    for d in select id, ano, classe, pagina from pgc_sync_fila where estado = 'pendente' order by id
              limit (2 - livres) for update skip locked loop
      update pgc_sync_fila set estado = 'em_execucao', tentativas = tentativas + 1, iniciado_em = now(),
             req_id = net.http_get(url := public.pgc_sync_url(d.ano, d.classe, d.pagina), timeout_milliseconds := 110000)
       where id = d.id;
    end loop;
  end if;
  return msg;
end $fn$;
revoke all on function public.pgc_sync_tick() from public, anon, authenticated;
grant execute on function public.pgc_sync_tick() to service_role;
