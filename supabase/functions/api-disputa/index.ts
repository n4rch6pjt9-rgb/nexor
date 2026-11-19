import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2";
import {
  type AuthenticatedUser,
  authenticateCron,
  authenticateUser,
  corsHeaders,
  isLicitagymAdmin,
  jsonResponse,
} from "../_shared/http.ts";
import { ErroTenantAcesso, lerTenantDoUsuario } from "../_shared/tenant.ts";
import type { ResultadoConsultaIntegra } from "../_shared/serpro.ts";
import {
  extrairChaveCompra17Digitos,
  INTERVALO_MINIMO_CONSULTA_MS,
  sincronizarCompra,
} from "../_shared/sessao_chat.ts";
import { pisoTenantCentavos, unidadeNorm } from "../_shared/agentes/preco.ts";
import { recomendar, type RecomendacaoLance } from "../_shared/recomendacao.ts";
import { listarSessoes } from "./sessoes.ts";
import { listarAlertas, marcarAlertaLido } from "./alertas.ts";

/**
 * O intervalo mínimo entre lances e o modo de disputa são do edital (K-8). Enquanto a leitura do edital não existir
 * (etapa 2 da spec 0039), nenhum item é habilitado para o robô: não se presume valor.
 */
const INTERVALO_MINIMO_EDITAL_LIDO = false;

/** Tipos de evento aceitos na trilha de lances (K-9/K-10) e o resultado que cada um grava. */
const TIPOS_AUDITORIA: Record<string, "sucesso" | "bloqueado_piso" | "recusado_intervalo"> = {
  LANCE_AUTOMATICO: "sucesso",
  LANCE_CONFIRMADO: "sucesso",
  BLOQUEIO_PISO: "bloqueado_piso",
  RECUSADO_INTERVALO: "recusado_intervalo",
};
const RECOMENDACAO_LOTE = 8;
const CHAT_LIMITE_PADRAO = 500;
const CHAT_LIMITE_MAX = 2000;
const MODOS_DISPUTA = new Set(["aberto", "aberto_fechado"]);
const REGRA_VERSION_MAX = 40;

/** Reais → centavos. undefined = inválido; null = ausente e opcional. */
function reaisParaCentavos(v: unknown, obrigatorio: boolean): number | null | undefined {
  if (v === undefined || v === null) return obrigatorio ? undefined : null;
  if (typeof v !== "number" || !Number.isFinite(v) || v <= 0 || v > 1e10) return undefined;
  return Math.round(v * 100);
}

export interface ApiDisputaContext {
  getSupabase?: () => SupabaseClient;
  getUser?: (req: Request) => Promise<AuthenticatedUser | null>;
  isCron?: (req: Request) => boolean;
  consultarChat?: (chave: string) => Promise<ResultadoConsultaIntegra>;
  consultarDiligencias?: (chave: string) => Promise<ResultadoConsultaIntegra>;
  agora?: () => number;
}

function getDefaultServiceClient(): SupabaseClient {
  const url = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !serviceKey) {
    throw new Error("Variáveis de ambiente SUPABASE_URL ou SUPABASE_SERVICE_ROLE_KEY não configuradas.");
  }
  return createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });
}

export { extrairChaveCompra17Digitos };

export async function handleRequest(req: Request, ctx?: ApiDisputaContext): Promise<Response> {
  // CORS Preflight
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  const url = new URL(req.url);
  const caminho = url.pathname.replace(/^\/api-disputa\/?/, "");

  try {
    let isCron = false;
    if (ctx?.isCron) {
      isCron = ctx.isCron(req);
    } else {
      try {
        isCron = authenticateCron(req) === "CRON_AUTHENTICATED";
      } catch {
        isCron = false;
      }
    }

    let user: AuthenticatedUser | null = null;
    let tenantId = 0;
    let papel: string | null = null;

    if (isCron) {
      if (caminho !== "sync-chat") {
        return jsonResponse({ erro: "Acesso por cron permitido apenas para /sync-chat." }, 403);
      }
    } else {
      user = ctx?.getUser ? await ctx.getUser(req) : await authenticateUser(req);
      if (!user) {
        return jsonResponse({ erro: "Não autenticado." }, 401);
      }
    }

    const supabase = ctx?.getSupabase ? ctx.getSupabase() : getDefaultServiceClient();

    if (!isCron && user) {
      const tenantRes = await lerTenantDoUsuario(
        supabase,
        user.id,
        isLicitagymAdmin(user)
      );
      tenantId = tenantRes.tenant;
      papel = tenantRes.papel;
    }

    // 0. GET /api-disputa/sessoes: compras do pipeline com o estado do chat da sessão (tela "Sessão").
    if (req.method === "GET" && caminho === "sessoes") {
      const sessoes = await listarSessoes(supabase, tenantId, ctx?.agora ? ctx.agora() : Date.now());
      return jsonResponse({ ok: true, fonte: "integra_compras", sessoes });
    }

    // 0b. Alertas de convocação do chat (spec 0039, etapa 1b, K-5c e K-5d). Só do tenant de quem chama.
    if (req.method === "GET" && caminho === "alertas") {
      const alertas = await listarAlertas(supabase, tenantId, {
        naoLidos: url.searchParams.get("nao_lidos") === "true",
        agoraMs: ctx?.agora ? ctx.agora() : Date.now(),
      });
      return jsonResponse({ ok: true, alertas });
    }
    if (req.method === "POST" && caminho === "alertas/lido") {
      let corpo: unknown = null;
      try {
        corpo = await req.json();
      } catch {
        return jsonResponse({ erro: "Corpo JSON inválido." }, 400);
      }
      const id = (corpo as { id?: unknown } | null)?.id;
      if (typeof id !== "number" || !Number.isSafeInteger(id) || id <= 0) {
        return jsonResponse({ erro: "Informe o id do alerta (inteiro positivo)." }, 400);
      }
      if (!user) return jsonResponse({ erro: "Não autenticado." }, 401);
      const marcado = await marcarAlertaLido(supabase, tenantId, id, user.id, ctx?.agora ? ctx.agora() : Date.now());
      if (!marcado) return jsonResponse({ erro: "Alerta não encontrado." }, 404);
      return jsonResponse({ ok: true });
    }

    // 1. GET /api-disputa/estrategia?licitacao_id=...
    if (req.method === "GET" && (caminho === "estrategia" || caminho === "")) {
      const licitacaoIdStr = url.searchParams.get("licitacao_id");
      if (!licitacaoIdStr) {
        return jsonResponse({ erro: "Parâmetro licitacao_id obrigatório." }, 400);
      }
      const licitacaoId = parseInt(licitacaoIdStr, 10);
      if (isNaN(licitacaoId)) {
        return jsonResponse({ erro: "licitacao_id inválido." }, 400);
      }

      // Verifica se a licitação está no pipeline do tenant
      const { data: pipelineRow, error: erroPipeline } = await supabase
        .from("pipeline_oportunidades")
        .select("licitacao_id")
        .eq("tenant_id", tenantId)
        .eq("licitacao_id", licitacaoId)
        .maybeSingle();

      if (erroPipeline) throw erroPipeline;
      if (!pipelineRow) {
        return jsonResponse({ erro: "Oportunidade não encontrada no pipeline do tenant." }, 404);
      }

      // Busca dados dos itens da licitação
      const { data: itens, error: erroItens } = await supabase
        .from("licitacao_itens")
        .select("id, numero_item, descricao, valor_unitario_estimado, valor_total_estimado, catalogo_codigo_item, unidade_medida")
        .eq("licitacao_id", licitacaoId)
        .order("numero_item", { ascending: true });

      if (erroItens) throw erroItens;

      // Busca mapeamento de-para confirmado no catálogo do tenant (determinístico: order by id asc, idêntico a api-agentes)
      const itemIds = (itens || []).map((it) => it.id);
      const deParaMap = new Map<number, number>(); // licitacao_item_id -> produto_id
      if (itemIds.length > 0) {
        const { data: deParaRows, error: erroDePara } = await supabase
          .from("catalogo_de_para")
          .select("id, licitacao_item_id, produto_id")
          .eq("tenant_id", tenantId)
          .in("licitacao_item_id", itemIds)
          .eq("status", "confirmado")
          .order("id", { ascending: true });

        if (erroDePara) throw erroDePara;

        for (const dp of deParaRows || []) {
          if (dp.licitacao_item_id && dp.produto_id) {
            // Mantém o primeiro produto confirmado ordenado por id (compatível com api-agentes repo.ts:398)
            if (!deParaMap.has(dp.licitacao_item_id)) {
              deParaMap.set(dp.licitacao_item_id, dp.produto_id);
            }
          }
        }
      }

      // Busca preços vigentes para os produtos mapeados
      const produtoIds = Array.from(new Set(Array.from(deParaMap.values())));
      const precosPorProduto = new Map<number, { preco_tabela: number; desconto_max_pct: number }>();
      if (produtoIds.length > 0) {
        const hoje = new Date().toISOString().slice(0, 10);
        const { data: precosRows, error: erroPrecos } = await supabase
          .from("catalogo_precos")
          .select("produto_id, preco_tabela, desconto_max_pct, vigencia_inicio, vigencia_fim")
          .eq("tenant_id", tenantId)
          .in("produto_id", produtoIds)
          .lte("vigencia_inicio", hoje)
          .order("vigencia_inicio", { ascending: false });

        if (erroPrecos) throw erroPrecos;

        for (const p of precosRows || []) {
          if (!precosPorProduto.has(p.produto_id)) {
            if (p.vigencia_fim === null || String(p.vigencia_fim) >= hoje) {
              if (typeof p.preco_tabela === "number") {
                precosPorProduto.set(p.produto_id, {
                  preco_tabela: p.preco_tabela,
                  desconto_max_pct: typeof p.desconto_max_pct === "number" ? p.desconto_max_pct : 0,
                });
              }
            }
          }
        }
      }

      // CONTRATO RECOMENDACAO v1: enriquece cada item com RecomendacaoLance
      const recomendacoesPorItem = new Map<number, RecomendacaoLance>();
      // Em lotes: `recomendar` vai ao banco por item; em paralelo, mas sem abrir uma conexão por item de licitação grande.
      const calcularRecomendacao = async (item: NonNullable<typeof itens>[number]) => {
        const produtoId = deParaMap.get(item.id);
        if (produtoId === undefined) return;

        const preco = precosPorProduto.get(produtoId);
        if (!preco) return;

        const tabelaCentavos = Math.round(preco.preco_tabela * 100);
        const pisoCentavos = pisoTenantCentavos(tabelaCentavos, preco.desconto_max_pct);

        const rec = await recomendar(
          {
            codigo_item: Number(item.catalogo_codigo_item ?? 0),
            unidade: unidadeNorm(item.unidade_medida),
            custo_proprio: pisoCentavos / 100,
            margem_min: 0,
            estimado_edital: Number(item.valor_unitario_estimado ?? 0),
          },
          supabase,
        );

        recomendacoesPorItem.set(item.id, rec);
      };
      const todosItens = itens || [];
      for (let i = 0; i < todosItens.length; i += RECOMENDACAO_LOTE) {
        await Promise.all(todosItens.slice(i, i + RECOMENDACAO_LOTE).map(calcularRecomendacao));
      }

      // Constrói estratégia determinística estrita (sem alucinar pisos inexistentes)
      const itensEstrategia = (itens || []).map((it) => {
        const itemNum = it.numero_item || 1;
        const produtoId = deParaMap.get(it.id);
        let pisoCentavos: number | null = null;
        let habilitado = false;

        if (produtoId !== undefined) {
          const preco = precosPorProduto.get(produtoId);
          if (preco) {
            const tabelaCentavos = Math.round(preco.preco_tabela * 100);
            pisoCentavos = pisoTenantCentavos(tabelaCentavos, preco.desconto_max_pct);
            habilitado = true;
          }
        }

        const recomendacao = recomendacoesPorItem.get(it.id) || null;

        return {
          item_numero: itemNum,
          descricao: it.descricao,
          valor_unitario_estimado: it.valor_unitario_estimado,
          valor_total_estimado: it.valor_total_estimado,
          piso_centavos: pisoCentavos,
          // Sem piso o robô não atua. O intervalo mínimo vem do edital e ainda não é lido (K-8, etapa 2):
          // fica ausente, nunca presumido, e com ele ausente o item não é habilitado.
          habilitado: habilitado && INTERVALO_MINIMO_EDITAL_LIDO,
          intervalo_minimo_reais: null as number | null,
          recomendacao,
        };
      });

      const primeiroPiso = itensEstrategia[0]?.piso_centavos ?? null;

      return jsonResponse({
        licitacao_id: licitacaoId,
        tenant_id: tenantId,
        // Modo de disputa e intervalo mínimo vêm do edital e ainda não são lidos (K-8, etapa 2): ausentes, não presumidos.
        modo_disputa: null as string | null,
        intervalo_minimo_reais: null as number | null,
        piso_centavos: primeiroPiso,
        habilitado: itensEstrategia[0]?.habilitado ?? false,
        itens: itensEstrategia,
      });
    }

    // 2. POST /api-disputa/auditoria (enviado pela extensão web)
    if (req.method === "POST" && caminho === "auditoria") {
      // Só admin do tenant (K-10). Nada é presumido: valor, piso, modo e tipo são obrigatórios e validados,
      // e só os campos abaixo são gravados (o corpo do cliente não entra em `detalhes`).
      if (!user) return jsonResponse({ erro: "Não autenticado." }, 401);
      // Allowlist: admin do tenant, ou admin da plataforma sem vínculo (papel nulo). Papel novo não libera sozinho.
      if (!(papel === "admin" || (papel === null && isLicitagymAdmin(user)))) {
        return jsonResponse({ erro: "Apenas admin da empresa registra a trilha de lances." }, 403);
      }
      let body: Record<string, unknown>;
      try {
        const b = await req.json();
        if (!b || typeof b !== "object" || Array.isArray(b)) throw new Error("corpo");
        body = b as Record<string, unknown>;
      } catch {
        return jsonResponse({ erro: "Corpo JSON inválido." }, 400);
      }

      const licitacaoId = Number(body.licitacaoId);
      const itemNumero = Number(body.item_numero);
      const valor = reaisParaCentavos(body.valor, true);
      const piso = reaisParaCentavos(body.piso, true);
      const melhor = reaisParaCentavos(body.melhorOferta, false);
      const tipo = typeof body.tipo === "string" ? body.tipo : "";
      const modo = typeof body.modo_disputa === "string" ? body.modo_disputa : "";
      if (
        !Number.isSafeInteger(licitacaoId) || licitacaoId <= 0 ||
        !Number.isSafeInteger(itemNumero) || itemNumero <= 0 ||
        valor === undefined || valor === null || piso === undefined || piso === null || melhor === undefined ||
        !Object.hasOwn(TIPOS_AUDITORIA, tipo) || !MODOS_DISPUTA.has(modo)
      ) {
        return jsonResponse({
          erro: "Informe licitacaoId, item_numero, valor e piso (positivos), melhorOferta (opcional), " +
            "modo_disputa (aberto | aberto_fechado) e tipo (" + Object.keys(TIPOS_AUDITORIA).join(" | ") + ").",
        }, 400);
      }

      const { data: pipelineAud, error: erroPipelineAud } = await supabase
        .from("pipeline_oportunidades")
        .select("licitacao_id")
        .eq("tenant_id", tenantId)
        .eq("licitacao_id", licitacaoId)
        .maybeSingle();
      if (erroPipelineAud) throw erroPipelineAud;
      if (!pipelineAud) {
        return jsonResponse({ erro: "Oportunidade não encontrada no pipeline do tenant." }, 404);
      }

      // O item precisa existir na licitação: a trilha de auditoria não aceita item inventado.
      const { data: itemExiste, error: erroItem } = await supabase
        .from("licitacao_itens")
        .select("id")
        .eq("licitacao_id", licitacaoId)
        .eq("numero_item", itemNumero)
        .limit(1)
        .maybeSingle();
      if (erroItem) throw erroItem;
      if (!itemExiste) {
        return jsonResponse({ erro: "Item não encontrado nesta licitação." }, 404);
      }

      const recomendacaoId = typeof body.recomendacao_id === "number" && Number.isSafeInteger(body.recomendacao_id)
        ? body.recomendacao_id
        : null;
      const regraVersion = typeof body.regra_version === "string" && body.regra_version.length <= REGRA_VERSION_MAX
        ? body.regra_version
        : "bot-guards.v1";

      const { data, error } = await supabase.from("disputa_lances_auditoria").insert({
        tenant_id: tenantId,
        licitacao_id: licitacaoId,
        item_numero: itemNumero,
        valor_lance_centavos: valor,
        piso_referencia_centavos: piso,
        melhor_lance_adversario_centavos: melhor,
        modo_disputa: modo,
        regra_aplicada: tipo, // vocabulário já usado nesta coluna (ex.: BLOQUEIO_PISO); o desfecho vai em `resultado`
        origem: "extensao_operador",
        resultado: TIPOS_AUDITORIA[tipo],
        detalhes: { recomendacao_id: recomendacaoId, regra_version: regraVersion },
      }).select("id").single();

      if (error) throw error;
      return jsonResponse({ ok: true, id: data.id });
    }

    // 3. GET /api-disputa/chat?licitacao_id=... (consumido pelo Dashboard)
    //    O chat é global (uma cópia por compra); o acesso é amarrado ao pipeline do tenant.
    if (req.method === "GET" && caminho === "chat") {
      const licitacaoIdStr = url.searchParams.get("licitacao_id");
      if (!licitacaoIdStr) {
        return jsonResponse({ erro: "Parâmetro licitacao_id obrigatório." }, 400);
      }
      const licitacaoId = parseInt(licitacaoIdStr, 10);
      if (isNaN(licitacaoId)) {
        return jsonResponse({ erro: "licitacao_id inválido." }, 400);
      }

      const { data: pipelineRow, error: erroPipeline } = await supabase
        .from("pipeline_oportunidades")
        .select("licitacao_id")
        .eq("tenant_id", tenantId)
        .eq("licitacao_id", licitacaoId)
        .maybeSingle();

      if (erroPipeline) throw erroPipeline;
      if (!pipelineRow) {
        return jsonResponse({ erro: "Oportunidade não encontrada no pipeline do tenant." }, 404);
      }

      const { data: licitacao, error: erroLic } = await supabase
        .from("licitacoes_externas")
        .select("id, codigo_externo, link_sistema_origem, raw")
        .eq("id", licitacaoId)
        .maybeSingle();
      if (erroLic) throw erroLic;

      const chaveCompra = licitacao ? extrairChaveCompra17Digitos(licitacao) : null;
      if (!chaveCompra) {
        // Estado explícito: sem chave oficial não há como consultar o chat (nunca lista vazia disfarçada).
        return jsonResponse({
          ok: true,
          fonte: "integra_compras",
          chave_compra: null,
          motivo: "sem_chave_compra",
          ultima_consulta: null,
          truncado: false,
          mensagens: [],
        });
      }

      // Limite: as mais recentes (o início da sessão é o que menos importa); `truncado` avisa que há mais antigas.
      const limiteBruto = url.searchParams.get("limite");
      const limiteParam = limiteBruto === null ? CHAT_LIMITE_PADRAO : Number(limiteBruto);
      if (!Number.isInteger(limiteParam) || limiteParam < 1) {
        return jsonResponse({ erro: "limite deve ser um inteiro positivo." }, 400);
      }
      const limite = Math.min(limiteParam, CHAT_LIMITE_MAX);
      const { data: maisRecentes, error } = await supabase
        .from("sessao_mensagens")
        .select(
          "chave_mensagem, tipo, identificador_item, categoria, tipo_remetente, texto, data_hora, data_hora_fonte, fonte, coletado_em",
        )
        .eq("chave_compra", chaveCompra)
        .order("data_hora", { ascending: false })
        .order("id", { ascending: false })
        .limit(limite + 1);
      if (error) throw error;
      const truncado = (maisRecentes ?? []).length > limite;
      const mensagens = (maisRecentes ?? []).slice(0, limite).reverse();

      const { data: ultimaRun, error: erroRun } = await supabase
        .schema("private")
        .from("integra_compras_run")
        .select("iniciado_em, terminado_em, erro")
        .eq("chave_compra", chaveCompra)
        .order("iniciado_em", { ascending: false })
        .limit(1)
        .maybeSingle();
      if (erroRun) throw erroRun;

      return jsonResponse({
        ok: true,
        fonte: "integra_compras",
        chave_compra: chaveCompra,
        motivo: null,
        ultima_consulta: ultimaRun
          ? { iniciado_em: ultimaRun.iniciado_em, terminado_em: ultimaRun.terminado_em, com_erro: Boolean(ultimaRun.erro) }
          : null,
        truncado,
        mensagens,
      });
    }

    // 4. POST /api-disputa/sync-chat (consulta o Integra Compras sob demanda ou por cron)
    if (req.method === "POST" && caminho === "sync-chat") {
      let body: Record<string, unknown>;
      try {
        body = await req.json();
      } catch {
        return jsonResponse({ erro: "Corpo JSON inválido." }, 400);
      }
      const { licitacao_id, chave_compra } = body;

      if (!licitacao_id) {
        return jsonResponse({ erro: "licitacao_id é obrigatório." }, 400);
      }

      const licitacaoId = parseInt(String(licitacao_id), 10);
      if (isNaN(licitacaoId)) {
        return jsonResponse({ erro: "licitacao_id inválido." }, 400);
      }

      // Só compras que estão no pipeline de algum tenant são consultadas (cada chamada é cobrada).
      if (isCron) {
        const tenantParam = body.tenant_id ? parseInt(String(body.tenant_id), 10) : null;
        if (tenantParam && !isNaN(tenantParam)) {
          const { data: pipe, error: ePipe } = await supabase
            .from("pipeline_oportunidades")
            .select("tenant_id")
            .eq("tenant_id", tenantParam)
            .eq("licitacao_id", licitacaoId)
            .maybeSingle();
          if (ePipe) throw ePipe;
          if (!pipe) {
            return jsonResponse({ erro: "Licitação não vinculada ao tenant informado no pipeline." }, 404);
          }
        } else {
          const { data: pipes, error: ePipe } = await supabase
            .from("pipeline_oportunidades")
            .select("tenant_id")
            .eq("licitacao_id", licitacaoId);
          if (ePipe) throw ePipe;
          if (!pipes || pipes.length === 0) {
            return jsonResponse({ erro: "Licitação não vinculada a nenhum tenant ativo no pipeline." }, 404);
          }
        }
      } else {
        const { data: pipelineRow, error: erroPipeline } = await supabase
          .from("pipeline_oportunidades")
          .select("licitacao_id")
          .eq("tenant_id", tenantId)
          .eq("licitacao_id", licitacaoId)
          .maybeSingle();

        if (erroPipeline) throw erroPipeline;
        if (!pipelineRow) {
          return jsonResponse({ erro: "Oportunidade não encontrada no pipeline do tenant." }, 404);
        }
      }

      // A chave consultada vem sempre do registro oficial da licitação, nunca do corpo da requisição.
      const { data: licitacao, error: erroLic } = await supabase
        .from("licitacoes_externas")
        .select("id, codigo_externo, link_sistema_origem, raw")
        .eq("id", licitacaoId)
        .maybeSingle();

      if (erroLic) throw erroLic;
      if (!licitacao) {
        return jsonResponse({ erro: "Licitação não encontrada." }, 404);
      }

      const chaveOficial = extrairChaveCompra17Digitos(licitacao);
      if (!chaveOficial) {
        return jsonResponse({
          erro: "Esta licitação não possui chave oficial de compra do Compras.gov (17 dígitos) para consulta no Integra Compras."
        }, 400);
      }

      if (typeof chave_compra === "string" && chave_compra.trim() && chave_compra.trim() !== chaveOficial) {
        return jsonResponse({ erro: "Chave de compra não corresponde ao registro oficial da licitação." }, 400);
      }

      // Cada consulta é cobrada: pedido manual repetido na mesma compra espera o intervalo mínimo.
      if (!isCron) {
        const { data: recente, error: erroRecente } = await supabase
          .schema("private")
          .from("integra_compras_run")
          .select("iniciado_em")
          .eq("chave_compra", chaveOficial)
          .order("iniciado_em", { ascending: false })
          .limit(1)
          .maybeSingle();
        if (erroRecente) throw erroRecente;
        const ultima = recente?.iniciado_em ? new Date(String(recente.iniciado_em)).getTime() : NaN;
        if (Number.isFinite(ultima) && Date.now() - ultima < INTERVALO_MINIMO_CONSULTA_MS) {
          return jsonResponse({
            erro: "Esta compra foi consultada há pouco. Aguarde alguns minutos para consultar de novo.",
            ultima_consulta: recente!.iniciado_em,
          }, 429);
        }
      }

      const r = await sincronizarCompra(
        supabase,
        { chaveCompra: chaveOficial, licitacaoId, origem: isCron ? "cron" : "usuario" },
        { consultarChat: ctx?.consultarChat, consultarDiligencias: ctx?.consultarDiligencias },
      );

      if (r.pulada) {
        // Corrida com outra consulta da mesma compra: a outra segue, esta não chamou a fonte.
        return jsonResponse({
          erro: "Esta compra foi consultada há pouco. Aguarde alguns minutos para consultar de novo.",
        }, 429);
      }

      if (!r.ok) {
        return jsonResponse({
          ok: false,
          erro: `Integra Compras indisponível (HTTP ${r.status_erro ?? "sem resposta"}). Nada foi apagado.`,
          total_lidas: r.total_lidas,
          novas_inseridas: r.novas_inseridas,
          alertas_gerados: r.alertas_gerados,
          chamadas: r.chamadas,
        }, 502);
      }

      return jsonResponse({
        ok: true,
        total_lidas: r.total_lidas,
        novas_inseridas: r.novas_inseridas,
        alertas_gerados: r.alertas_gerados,
        chamadas: r.chamadas,
      });
    }

    return jsonResponse({ erro: "Rota não encontrada." }, 404);
  } catch (err) {
    if (err instanceof ErroTenantAcesso) {
      return jsonResponse({ erro: err.message }, err.status);
    }
    console.error("[api-disputa] Erro interno:", err instanceof Error ? err.message : err);
    return jsonResponse({ erro: "Erro interno no servidor." }, 500);
  }
}

if (import.meta.main) {
  Deno.serve((req: Request) => handleRequest(req));
}
