import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { corsHeaders, jsonResponse, validateCronAuth } from "../_shared/http.ts";
import { PncpIntegracaoClient } from "../_shared/pncp/integracao-client.ts";
import { acquireSyncLock } from "../_shared/pncp/lock.ts";
import {
  createServiceClient,
  finishSyncRun,
  logSyncRequest,
  storeSourceRecord,
  updateSyncHeartbeat,
} from "../_shared/pncp/supabase-admin.ts";
import { orgSyncClasses } from "../_shared/pncp/catmat-scope-resolver.ts";
import { hashPayload, sha256Hex } from "../_shared/pncp/hash.ts";
import {
  chunkValues,
  fetchAllByRange,
  POSTGREST_IN_CHUNK,
} from "../_shared/pncp/postgrest-paginate.ts";
import { upsertByHash } from "../_shared/pncp/upsert.ts";
import { linhaEntidade } from "./entidade.ts";
import { identificadorMunicipioFonte, linhaUnidade, municipioDaUnidade, normalizarNomeMunicipio } from "./unidade.ts";

type ServiceClient = ReturnType<typeof createServiceClient>;
type MunicipioCache = Map<string, string | null>;

async function resolverMunicipioUnidade(
  client: ServiceClient,
  municipio: NonNullable<ReturnType<typeof municipioDaUnidade>>,
  cnpj: string,
  codigoUnidade: string,
  cache: MunicipioCache,
): Promise<{ municipioId: string | null; erros: string[] }> {
  const chave = JSON.stringify([municipio.id, municipio.codigoIbge, municipio.nome, municipio.uf]);
  if (cache.has(chave)) return { municipioId: cache.get(chave) ?? null, erros: [] };

  const identificador = identificadorMunicipioFonte(municipio);
  const { data, error } = await client.rpc("resolver_municipio", {
    p_fonte: "pncp",
    p_nome: municipio.nome,
    p_uf: municipio.uf,
    p_codigo_ibge: municipio.codigoIbge,
    p_namespace: identificador.namespace,
    p_identificador_externo: identificador.valor,
    p_identificador_verificado: identificador.verificado,
    p_evidencias: {
      endpoint: `/orgaos/${cnpj}/unidades`,
      codigo_unidade: codigoUnidade,
      municipio_id_pncp: municipio.id,
      codigo_ibge: municipio.codigoIbge,
      contrato: "Municipio.id e Municipio.codigoIbge são campos distintos no PNCP Integração v3",
    },
  });
  if (error) {
    // Falha transitória não é cacheada: o próximo registro do mesmo município tenta de novo na mesma execução.
    return { municipioId: null, erros: [`resolver_municipio: ${error.message}`] };
  }

  const resultado = (Array.isArray(data) ? data[0] : data) as Record<string, unknown> | null;
  const municipioId = resultado?.status === "resolvido" && typeof resultado.municipio_id === "string"
    ? resultado.municipio_id
    : null;
  cache.set(chave, municipioId);
  // Sem codigoIbge na unidade oficial não há cruzamento: o município pode ter sido resolvido, mas nenhum alias do
  // suggest é promovido (nome+UF e coincidência numérica isolada não confirmam semântica de ID).
  if (!municipioId || !municipio.nome || !municipio.uf || !municipio.codigoIbge) {
    return { municipioId, erros: [] };
  }

  // O suggest do PNCP não documenta o tipo de items[].id. Só promovemos um alias pendente
  // quando seu valor coincide com Municipio.id ou codigoIbge da unidade oficial (que traz os dois no mesmo DTO).
  const idsConfirmaveis = [...new Set([municipio.id, municipio.codigoIbge].filter((v): v is string => Boolean(v)))];
  if (idsConfirmaveis.length === 0) return { municipioId, erros: [] };

  const { data: referencias, error: referenciasError } = await client
    .from("municipio_referencias_externas")
    .select("valor_externo")
    .eq("fonte", "pncp")
    .eq("namespace", "suggest_municipio")
    .in("status", ["pendente", "verificado"])
    .eq("uf_observada", municipio.uf)
    .eq("nome_normalizado", normalizarNomeMunicipio(municipio.nome))
    .in("valor_externo", idsConfirmaveis);

  const erros: string[] = [];
  if (referenciasError) {
    erros.push(`consulta suggest_municipio: ${referenciasError.message}`);
    return { municipioId, erros };
  }

  for (const referencia of referencias ?? []) {
    const { error: confirmarError } = await client.rpc("resolver_municipio", {
      p_fonte: "pncp",
      p_nome: municipio.nome,
      p_uf: municipio.uf,
      p_codigo_ibge: municipio.codigoIbge,
      p_namespace: "suggest_municipio",
      p_identificador_externo: String(referencia.valor_externo),
      p_identificador_verificado: true,
      p_evidencias: {
        endpoint: `/orgaos/${cnpj}/unidades`,
        codigo_unidade: codigoUnidade,
        validado_contra: "Municipio.id ou Municipio.codigoIbge",
        municipio_id_pncp: municipio.id,
        codigo_ibge: municipio.codigoIbge,
      },
    });
    if (confirmarError) erros.push(`confirmar suggest_municipio ${referencia.valor_externo}: ${confirmarError.message}`);
  }
  return { municipioId, erros };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return jsonResponse({ error: "Use POST" }, 405);
  if (!validateCronAuth(req)) return jsonResponse({ error: "Unauthorized" }, 401);

  const client = createServiceClient();
  const integracao = new PncpIntegracaoClient();
  const lockKey = "orgaos-sync";
  const { runId, alreadyRunning } = await acquireSyncLock(client, lockKey, "orgaos", {});

  if (alreadyRunning) {
    return jsonResponse({ status: "already_running", sync_id: runId });
  }

  const stats = {
    entidades_inseridas: 0,
    orgaos_inseridas: 0,
    unidades_inseridas: 0,
    erros: 0,
    pca_itens_lidos: 0,
    pca_planos_lidos: 0,
  };

  try {
    const classCodes = orgSyncClasses().map((classe) => Number(classe));
    const { rows: itemRows, pages: itemPages } = await fetchAllByRange<{
      pca_plano_id: string;
    }>(
      (from, to) =>
        client
          .from("pca_itens")
          .select("pca_plano_id")
          .in("codigo_classe_catmat", classCodes)
          .order("id")
          .range(from, to),
      { orderBy: "id" },
    );
    stats.pca_itens_lidos = itemRows.length;

    const planIds = [
      ...new Set(
        itemRows
          .map((row) => row.pca_plano_id as string)
          .filter((id) => typeof id === "string" && id.length > 0),
      ),
    ];

    const cnpjsSet = new Set<string>();
    for (const idChunk of chunkValues(planIds, POSTGREST_IN_CHUNK)) {
      const { rows: planRows } = await fetchAllByRange<{ orgao_cnpj: string }>(
        (from, to) =>
          client
            .from("pca_planos")
            .select("orgao_cnpj")
            .in("id", idChunk)
            .order("id")
            .range(from, to),
        { orderBy: "id" },
      );
      stats.pca_planos_lidos += planRows.length;
      for (const row of planRows) {
        const cnpj = String(row.orgao_cnpj ?? "").trim();
        if (cnpj.length > 0) cnpjsSet.add(cnpj);
      }
    }

    const { rows: orgaosExistentes } = await fetchAllByRange<{ cnpj: string }>(
      (from, to) =>
        client
          .from("orgaos")
          .select("cnpj")
          .order("id")
          .range(from, to),
      { orderBy: "id" },
    );
    const cnpjsJaGravados = new Set(
      orgaosExistentes
        .map((row) => String(row.cnpj ?? "").trim())
        .filter((c) => c.length > 0),
    );

    // Prioriza CNPJs que ainda não estão em public.orgaos e respeita orçamento de tempo (90s)
    // para nunca estourar o limite de 150s da Edge Function nem deixar sync_execucoes presa em 'executando'.
    const cnpjs = Array.from(cnpjsSet).sort((a, b) => {
      const aExiste = cnpjsJaGravados.has(a) ? 1 : 0;
      const bExiste = cnpjsJaGravados.has(b) ? 1 : 0;
      if (aExiste !== bExiste) return aExiste - bExiste;
      return a.localeCompare(b);
    });

    const ORCAMENTO_PADRAO_MS = 90_000;
    const inicioMs = Date.now();
    const municipiosResolvidos: MunicipioCache = new Map();
    let processados = 0;
    let interrompidoPorOrcamento = false;

    for (const cnpj of cnpjs) {
      if (Date.now() - inicioMs >= ORCAMENTO_PADRAO_MS) {
        interrompidoPorOrcamento = true;
        break;
      }
      if (processados > 0 && processados % 10 === 0) {
        await updateSyncHeartbeat(client, runId);
      }
      processados++;
      try {
        const orgaoData = await integracao.getOrgao(cnpj);
        const payload = orgaoData as Record<string, unknown>;

        const endpoint = `/orgaos/${cnpj}`;
        const requestHash = await hashPayload({ cnpj });
        const contentHash = await sha256Hex(JSON.stringify(payload));
        await storeSourceRecord(client, {
          syncRunId: runId,
          resourceType: "orgaos",
          endpoint,
          requestHash,
          contentHash,
          payload,
        });

        const entidadeResult = await upsertByHash(
          client,
          "entidades",
          { codigo_pncp: cnpj },
          linhaEntidade(cnpj),
          { syncRunId: runId },
        );

        if (entidadeResult === "erro") {
          stats.erros++;
          await logSyncRequest(client, {
            syncRunId: runId,
            endpoint: `/orgaos/${cnpj}`,
            parametros: { cnpj, tabela: "entidades" },
            erro: "upsert entidades failed",
          });
        } else {
          stats.entidades_inseridas++;
        }

        const entidadeIdResult = await client
          .from("entidades")
          .select("id")
          .eq("codigo_pncp", cnpj)
          .single();

        if (entidadeIdResult.error) {
          stats.erros++;
          await logSyncRequest(client, {
            syncRunId: runId,
            endpoint: `/orgaos/${cnpj}`,
            parametros: { cnpj, tabela: "entidades_select" },
            erro: entidadeIdResult.error.message,
          });
        } else if (entidadeIdResult.data && entidadeIdResult.data.id) {
          const entidadeId = entidadeIdResult.data.id;

          const orgaoResult = await upsertByHash(
            client,
            "orgaos",
            { entidade_id: entidadeId },
            {
              entidade_id: entidadeId,
              cnpj: cnpj,
            },
            { syncRunId: runId },
          );

          if (orgaoResult === "erro") {
            stats.erros++;
            await logSyncRequest(client, {
              syncRunId: runId,
              endpoint: `/orgaos/${cnpj}`,
              parametros: { cnpj, tabela: "orgaos" },
              erro: "upsert orgaos failed",
            });
          } else {
            stats.orgaos_inseridas++;
            const orgaoIdResult = await client
              .from("orgaos")
              .select("id, unidades_sync_at")
              .eq("entidade_id", entidadeId)
              .single();

            if (orgaoIdResult.error || !orgaoIdResult.data?.id) {
              stats.erros++;
              await logSyncRequest(client, {
                syncRunId: runId,
                endpoint: `/orgaos/${cnpj}`,
                parametros: { cnpj, tabela: "orgaos_select" },
                erro: orgaoIdResult.error?.message ?? "orgao id ausente após upsert",
              });
            } else {
              const orgaoId = String(orgaoIdResult.data.id);
              const ultimaSyncUnidades = orgaoIdResult.data.unidades_sync_at
                ? Date.parse(String(orgaoIdResult.data.unidades_sync_at))
                : Number.NaN;
              const TTL_UNIDADES_MS = 7 * 24 * 60 * 60 * 1000;
              const precisaSincronizarUnidades = !Number.isFinite(ultimaSyncUnidades)
                || Date.now() - ultimaSyncUnidades >= TTL_UNIDADES_MS;
              const unidadesEndpoint = `/orgaos/${cnpj}/unidades`;
              if (precisaSincronizarUnidades) {
                try {
                  let unidadesSemErro = true;
                  let unidadesCompletas = true;
                  const unidades = await integracao.getUnidades(cnpj, { syncRunId: runId });
                  const unidadesRequestHash = await hashPayload({ cnpj });
                  const unidadesContentHash = await sha256Hex(JSON.stringify(unidades));
                  await storeSourceRecord(client, {
                    syncRunId: runId,
                    resourceType: "unidades",
                    endpoint: unidadesEndpoint,
                    requestHash: unidadesRequestHash,
                    contentHash: unidadesContentHash,
                    payload: unidades,
                  });

                  for (const unidadeRaw of unidades) {
                    if (Date.now() - inicioMs >= ORCAMENTO_PADRAO_MS) {
                      interrompidoPorOrcamento = true;
                      unidadesCompletas = false;
                      break;
                    }
                    const linha = linhaUnidade(orgaoId, unidadeRaw);
                    if (!linha) {
                      // Defeito permanente do dado de origem: registra, mas não impede o carimbo do TTL (senão o
                      // órgão seria rebuscado a cada execução e consumiria o orçamento de tempo dos demais).
                      stats.erros++;
                      await logSyncRequest(client, {
                        syncRunId: runId,
                        endpoint: unidadesEndpoint,
                        parametros: { cnpj, tabela: "unidades" },
                        erro: "unidade sem codigoUnidade válido",
                      });
                      continue;
                    }

                    const codigoUnidade = String(linha.codigo_unidade);
                    const municipio = municipioDaUnidade(unidadeRaw);
                    if (municipio) {
                      const resolucao = await resolverMunicipioUnidade(
                        client,
                        municipio,
                        cnpj,
                        codigoUnidade,
                        municipiosResolvidos,
                      );
                      if (resolucao.municipioId) linha.municipio_id = resolucao.municipioId;
                      for (const erro of resolucao.erros) {
                        unidadesSemErro = false;
                        stats.erros++;
                        await logSyncRequest(client, {
                          syncRunId: runId,
                          endpoint: unidadesEndpoint,
                          parametros: { cnpj, codigoUnidade, recurso: "municipio" },
                          erro,
                        });
                      }
                    }

                    const unidadeResult = await upsertByHash(
                      client,
                      "unidades",
                      { orgao_id: orgaoId, codigo_unidade: codigoUnidade },
                      linha,
                      { syncRunId: runId },
                    );
                    if (unidadeResult === "erro") {
                      unidadesSemErro = false;
                      stats.erros++;
                      await logSyncRequest(client, {
                        syncRunId: runId,
                        endpoint: unidadesEndpoint,
                        parametros: { cnpj, codigoUnidade, tabela: "unidades" },
                        erro: "upsert unidades failed",
                      });
                    } else if (unidadeResult !== "inalterado") {
                      stats.unidades_inseridas++;
                    }
                  }
                  if (unidadesSemErro && unidadesCompletas) {
                    const { error: syncStampError } = await client
                      .from("orgaos")
                      .update({ unidades_sync_at: new Date().toISOString() })
                      .eq("id", orgaoId);
                    if (syncStampError) {
                      stats.erros++;
                      await logSyncRequest(client, {
                        syncRunId: runId,
                        endpoint: unidadesEndpoint,
                        parametros: { cnpj, tabela: "orgaos", campo: "unidades_sync_at" },
                        erro: syncStampError.message,
                      });
                    }
                  }
                } catch (error) {
                  stats.erros++;
                  await logSyncRequest(client, {
                    syncRunId: runId,
                    endpoint: unidadesEndpoint,
                    parametros: { cnpj, tabela: "unidades" },
                    erro: error instanceof Error ? error.message : String(error),
                  });
                }
              }
            }
          }
        }
      } catch (error) {
        stats.erros++;
        await logSyncRequest(client, {
          syncRunId: runId,
          endpoint: `/orgaos/${cnpj}`,
          parametros: { cnpj },
          erro: error instanceof Error ? error.message : String(error),
        });
      }
    }

    await finishSyncRun(client, runId, {
      status: stats.erros > 0 ? "concluida_com_erros" : "concluida",
      totalRecebidos: processados,
      totalErros: stats.erros,
      parametros: {
        ...stats,
        pca_itens_pages: itemPages,
        plan_id_count: planIds.length,
        cnpjs_total: cnpjs.length,
        cnpjs_processados: processados,
        interrompido_por_orcamento: interrompidoPorOrcamento,
      },
    });
    return jsonResponse({
      status: stats.erros > 0 ? "concluida_com_erros" : "ok",
      stats,
      cnpjs_processados: processados,
      cnpjs_total: cnpjs.length,
      interrompido_por_orcamento: interrompidoPorOrcamento,
    }, stats.erros > 0 ? 500 : 200);
  } catch (error) {
    await finishSyncRun(client, runId, {
      status: "falhou",
      totalErros: stats.erros + 1,
      erroPrincipal: error instanceof Error ? error.message : String(error),
      parametros: stats,
    });
    return jsonResponse(
      { status: "error", erro: error instanceof Error ? error.message : String(error) },
      500,
    );
  }
});
