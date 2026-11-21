import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { corsHeaders, jsonResponse, requireCronAuth } from "../_shared/http.ts";
import { createServiceClient } from "../_shared/pncp/supabase-admin.ts";
import { compararFontes, type ParametrosListagem, parametrosListagemValidos, sondarFonte } from "../_shared/coletor/paradigma-sonda.ts";
import { carregarFonte, descobrirFonte, type FonteColeta, type Linha, type Repositorio } from "../_shared/coletor/paradigma-coleta.ts";

// Spec 0071, contrato K-7. Ações:
//   sonda     (fase 2) somente leitura, não grava licitação;
//   descobrir (fase 3) lista o mural pelo perfil da fonte e enfileira (spec 0064);
//   carregar  (fase 3) reserva uma fatia da fila, lê detalhe e itens e grava licitacoes_externas e licitacao_itens.
// descobrir e carregar só rodam quando fonte_externa_pode_coletar(slug) é verdadeiro (ativa, cron_ligado, perfil
// certificado, modo automático, sem pausa, robots ou mural autorizado). Não há parâmetro que contorne o gate.

const FONTES_PILOTO = ["sescdn", "firjan", "sescsp"];
const MAX_FONTES = 4;

const COLUNAS = "slug, base_url, ativo, robots_permite, mural_autorizado, pausada_ate, delay_ms, perfil, entidade, uf, max_processos_por_tick, orcamento_tick_s";

type FonteLinha = FonteColeta & { perfil: string | null; max_processos_por_tick: number; orcamento_tick_s: number };

function repositorio(client: ReturnType<typeof createServiceClient>): Repositorio {
  const falha = (op: string, e: { message: string } | null) => {
    if (e) throw new Error(`${op}: ${e.message}`);
  };
  return {
    async enfileirar(fonte, itens) {
      const { data, error } = await client.rpc("coleta_externa_fila_enfileirar", { p_fonte: fonte, p_itens: itens });
      falha("enfileirar", error);
      const r = (data ?? {}) as Record<string, number>;
      return { novos: Number(r.novos ?? 0), reabertos: Number(r.reabertos ?? 0), inalterados: Number(r.inalterados ?? 0) };
    },
    async reservar(fonte, limite) {
      const { data, error } = await client.rpc("coleta_externa_fila_reservar", { p_fonte: fonte, p_limite: limite });
      falha("reservar", error);
      return (data ?? []) as { id: number; n_cd_origem: number; modulo: number; listagem: Linha }[];
    },
    async marcar(id, ok, erro) {
      const { error } = await client.rpc("coleta_externa_fila_marcar", { p_id: id, p_ok: ok, p_erro: erro ?? null });
      falha("marcar", error);
    },
    async gravarLicitacao(linha) {
      const { data, error } = await client.from("licitacoes_externas")
        .upsert(linha, { onConflict: "fonte,modulo,id_externo" }).select("id").single();
      falha("gravar licitação", error);
      return (data as { id: number }).id;
    },
    async gravarItens(linhas) {
      const { error } = await client.from("licitacao_itens").upsert(linhas, { onConflict: "licitacao_id,numero_item" });
      falha("gravar itens", error);
    },
  };
}

function listaDeFontes(body: Record<string, unknown>): string[] | null {
  const v = body.fontes;
  if (v === undefined) return FONTES_PILOTO;
  if (!Array.isArray(v) || v.length === 0 || v.length > MAX_FONTES) return null;
  if (!v.every((s) => typeof s === "string" && /^[a-z0-9_]{2,40}$/.test(s))) return null;
  return [...new Set(v as string[])];
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return jsonResponse({ error: "Use POST" }, 405);
  const denied = requireCronAuth(req);
  if (denied) return denied;

  let body: Record<string, unknown> = {};
  const texto = await req.text();
  if (texto.trim()) {
    try {
      const j = JSON.parse(texto);
      if (!j || typeof j !== "object" || Array.isArray(j)) throw new Error();
      body = j as Record<string, unknown>;
    } catch {
      return jsonResponse({ error: "JSON inválido" }, 400);
    }
  }
  if (!["sonda", "descobrir", "carregar"].includes(body.acao as string)) {
    return jsonResponse({ error: "acao inválida; use 'sonda', 'descobrir' ou 'carregar'" }, 400);
  }
  const slugs = listaDeFontes(body);
  if (!slugs) return jsonResponse({ error: `fontes: lista de 1 a ${MAX_FONTES} slugs` }, 400);
  const listagem = parametrosListagemValidos(body.listagem);
  if (!listagem) return jsonResponse({ error: "listagem: tipoMural 0-9, ordenarPor A-Z (3-20), tamanho 1-50" }, 400);
  const amostra = Number.isInteger(body.amostra) ? Math.min(Math.max(body.amostra as number, 1), 3) : 2;

  const client = createServiceClient();
  const { data, error } = await client.from("fontes_externas").select(COLUNAS).in("slug", slugs)
    .eq("adaptador", "paradigma");
  if (error) return jsonResponse({ error: "falha ao ler fontes_externas" }, 500);
  const fontes = data as FonteLinha[];
  const porSlug = new Map(fontes.map((f) => [f.slug, f]));

  // Cada fonte coleta pelo seu perfil (coletor_perfis.listagem). O corpo da chamada só sobrepõe, para testar.
  const perfis = [...new Set(fontes.map((f) => f.perfil).filter((p): p is string => !!p))];
  const listagemDoPerfil = new Map<string, ParametrosListagem>();
  if (perfis.length) {
    const { data: ps, error: ep } = await client.from("coletor_perfis").select("slug, listagem").in("slug", perfis);
    if (ep) return jsonResponse({ error: "falha ao ler coletor_perfis" }, 500);
    for (const p of ps as { slug: string; listagem: unknown }[]) {
      const v = parametrosListagemValidos(p.listagem);
      if (v) listagemDoPerfil.set(p.slug, v);
    }
  }

  const registrar = async (slug: string, status: number) => {
    const { error: e } = await client.rpc("fonte_externa_registrar_resultado", {
      p_slug: slug,
      p_http_status: status,
    });
    if (e) throw new Error(e.message);
  };

  const acao = body.acao as string;
  if (acao !== "sonda") {
    const repo = repositorio(client);
    const resultados = [];
    for (const slug of slugs) {
      const f = porSlug.get(slug);
      if (!f) {
        resultados.push({ fonte: slug, executada: false, motivo: "fonte inexistente ou sem adaptador paradigma" });
        continue;
      }
      const { data: pode, error: ep } = await client.rpc("fonte_externa_pode_coletar", { p_slug: slug });
      if (ep) return jsonResponse({ error: "falha ao consultar fonte_externa_pode_coletar" }, 500);
      if (pode !== true) {
        resultados.push({ fonte: slug, executada: false, motivo: "fonte_externa_pode_coletar = falso (ver cron_ligado, perfil certificado, pausa, robots)" });
        continue;
      }
      const orcamentoMs = Math.max(5, Math.min(f.orcamento_tick_s ?? 40, 120)) * 1000;
      const base = (f.perfil && listagemDoPerfil.get(f.perfil)) || {};
      const { data: runId, error: er } = await client.rpc("coleta_externa_iniciar", {
        p_fonte: slug,
        p_modo: acao === "descobrir" ? "descoberta" : "carga",
        p_termos: null,
      });
      if (er) return jsonResponse({ error: "falha ao abrir a execução em coleta_externa_run" }, 500);
      const opcoes = { registrar, orcamentoMs, maxPaginas: Number.isInteger(body.max_paginas) ? Math.min(Math.max(body.max_paginas as number, 1), 20) : 5 };
      let status = "concluida";
      let listados = 0, processos = 0, itens = 0, erros = 0;
      let detalhe: unknown = null;
      let saida: Record<string, unknown>;
      try {
        if (acao === "descobrir") {
          const r = await descobrirFonte(f, repo, { ...base, ...listagem }, opcoes);
          listados = r.resumo.listados;
          erros = r.bloqueada ? 1 : 0;
          if (r.bloqueada) status = "falhou";
          else if (!r.resumo.completa) status = "incompleta";
          saida = { fonte: slug, executada: true, ...r.resumo, bloqueada: r.bloqueada, chamadas: r.chamadas.length };
          detalhe = r.resumo.avisos.length ? { avisos: r.resumo.avisos } : null;
        } else {
          const limite = Number.isInteger(body.limite) ? Math.min(Math.max(body.limite as number, 1), 20) : f.max_processos_por_tick;
          const r = await carregarFonte(f, repo, limite, opcoes);
          listados = r.resumo.reservados;
          processos = r.resumo.gravados;
          itens = r.resumo.itens;
          erros = r.resumo.erros.length + r.resumo.sem_detalhe + (r.bloqueada ? 1 : 0);
          if (r.bloqueada) status = "falhou";
          else if (erros > 0) status = "concluida_com_erros";
          saida = { fonte: slug, executada: true, ...r.resumo, bloqueada: r.bloqueada, chamadas: r.chamadas.length };
          detalhe = erros > 0 || r.resumo.avisos.length ? { erros: r.resumo.erros, avisos: r.resumo.avisos } : null;
        }
      } catch (e) {
        status = "falhou";
        erros = 1;
        detalhe = { excecao: (e instanceof Error ? e.message : String(e)).slice(0, 300) };
        saida = { fonte: slug, executada: true, erro: "falha inesperada; ver coleta_externa_run" };
      }
      await client.rpc("coleta_externa_finalizar", {
        p_id: runId,
        p_status: status,
        p_listados: listados,
        p_processos: processos,
        p_no_escopo: 0,
        p_itens_escopo: itens,
        p_erros: erros,
        p_detalhe_erros: detalhe,
      });
      resultados.push({ ...saida, run_id: runId, status });
    }
    return jsonResponse({ acao, resultados });
  }

  const relatorios = [];
  for (const slug of slugs) {
    const f = porSlug.get(slug);
    if (!f) {
      relatorios.push({
        fonte: slug,
        executada: false,
        motivo_nao_executada: "fonte inexistente ou sem adaptador paradigma",
        bloqueada: false,
        chamadas: [],
        avisos: [],
      });
      continue;
    }
    const base = (f.perfil && listagemDoPerfil.get(f.perfil)) || {};
    relatorios.push(await sondarFonte(f, { amostra, registrar, listagem: { ...base, ...listagem } }));
  }
  return jsonResponse({ acao: "sonda", somente_leitura: true, relatorios, comparacao: compararFontes(relatorios) });
});
