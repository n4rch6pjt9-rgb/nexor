import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import {
  type AuthenticatedUser,
  authenticateCron,
  authenticateUser,
  corsHeaders,
  isLicitagymAdmin,
  jsonResponse,
} from "../_shared/http.ts";
import { SYNCS, syncPorSlug } from "./catalogo.ts";
import { responderEstadoPca } from "./estado-pca.ts";
import { createServiceClient } from "../_shared/pncp/supabase-admin.ts";

/**
 * api-syncs: catálogo dos syncs e disparo manual.
 *   POST {action:"listar"} -> { syncs: [...] }
 *   POST {action:"rodar", sync:"sync-portal-compras"} -> encaminha o corpo do catálogo para a Edge Function.
 *   POST {action:"rodar", sync:"coletor-pncp"} -> chama a função SQL do catálogo (campo `rpc`), tudo dentro do Supabase.
 * O "último cron" dos itens com `cron_jobs` vem do pg_cron (public.sync_status_cron), sem GitHub Actions.
 * Acesso: cron (SYNC_CRON_SECRET) ou app_metadata.licitagym_role = 'admin'.
 */

export interface StatusJobCron {
  jobname: string;
  schedule: string | null;
  ativo: boolean | null;
  run_id: number | null;
  status: string | null;
  inicio: string | null;
  fim: string | null;
  mensagem: string | null;
}

export interface ApiSyncsContext {
  getUser?: (req: Request) => Promise<AuthenticatedUser | null>;
  isCron?: (req: Request) => boolean;
  fetchFn?: typeof fetch;
  segredo?: () => string | null;
  baseUrl?: () => string | null;
  /** Relógio (testes). */
  agora?: () => Date;
  lerEstadoPca?: (ano: number) => Promise<unknown>;
  /** Status dos jobs do pg_cron (testes); padrão: RPC public.sync_status_cron com a service role. */
  lerStatusCron?: (jobs: string[]) => Promise<StatusJobCron[]>;
  /** Chamada de função SQL (testes); padrão: RPC com a service role. */
  chamarRpc?: (nome: string, args: Record<string, unknown>) => Promise<unknown>;
}

function segredoCron(): string | null {
  const bruto = Deno.env.get("SYNC_CRON_SECRET")?.trim() ?? "";
  const um = bruto.split(",").map((s) => s.trim()).find((s) => s.length > 0);
  return um ?? null;
}

function baseDasFuncoes(): string | null {
  const url = Deno.env.get("SUPABASE_URL")?.trim().replace(/\/+$/, "");
  return url ? `${url}/functions/v1` : null;
}

async function corpoResposta(res: Response): Promise<unknown> {
  const texto = await res.text();
  if (!texto) return null;
  try {
    return JSON.parse(texto);
  } catch {
    return { texto: texto.slice(0, 500) };
  }
}

// ---- último cron: lido do pg_cron (mesmo formato que a tela já exibe) ----

interface EtapaCron {
  nome: string;
  status: string | null;
  conclusion: string | null;
  started_at: string | null;
  completed_at: string | null;
}

interface EstadoCron {
  ultimo_cron: {
    run_id: number;
    status: string | null;
    conclusion: string | null;
    run_attempt: number | null;
    created_at: string | null;
    html_url: string | null;
    etapas: EtapaCron[];
  } | null;
  pode_refazer: boolean;
  motivo_refazer: string | null;
  erro_ultimo_cron: string | null;
}

async function statusPadrao(jobs: string[]): Promise<StatusJobCron[]> {
  const { data, error } = await createServiceClient().rpc("sync_status_cron", { p_jobs: jobs });
  if (error) throw new Error(error.message);
  return (data ?? []) as StatusJobCron[];
}

async function rpcPadrao(nome: string, args: Record<string, unknown>): Promise<unknown> {
  const { data, error } = await createServiceClient().rpc(nome, args);
  if (error) throw new Error(error.message);
  return data;
}

function conclusaoDe(status: string | null): string | null {
  if (status === "succeeded") return "success";
  if (status === "failed") return "failure";
  return null;
}

async function estadoCron(jobs: string[], ler: (j: string[]) => Promise<StatusJobCron[]>): Promise<EstadoCron> {
  const semRefazer = { pode_refazer: false, motivo_refazer: null };
  let linhas: StatusJobCron[];
  try {
    linhas = await ler(jobs);
  } catch (e) {
    console.error("[api-syncs] estadoCron", e instanceof Error ? e.message : String(e));
    return { ultimo_cron: null, ...semRefazer, erro_ultimo_cron: "Falha ao ler o status dos jobs no pg_cron." };
  }
  const porNome = new Map(linhas.map((l) => [l.jobname, l]));
  const etapas: EtapaCron[] = jobs.map((nome) => {
    const l = porNome.get(nome);
    if (!l) return { nome: `${nome} (não agendado)`, status: "completed", conclusion: "skipped", started_at: null, completed_at: null };
    if (l.ativo === false) return { nome: `${nome} (desativado)`, status: "completed", conclusion: "skipped", started_at: l.inicio, completed_at: l.fim };
    if (!l.status) return { nome: `${nome} (ainda não rodou)`, status: "completed", conclusion: "skipped", started_at: null, completed_at: null };
    const rodando = l.status === "running" || l.status === "starting" || l.status === "sending" || l.status === "connecting";
    return {
      nome: l.status === "failed" && l.mensagem ? `${nome}: ${l.mensagem}` : nome,
      status: rodando ? "in_progress" : "completed",
      conclusion: conclusaoDe(l.status),
      started_at: l.inicio,
      completed_at: l.fim,
    };
  });
  const comRun = linhas.filter((l) => l.run_id !== null && l.inicio);
  if (comRun.length === 0) {
    return { ultimo_cron: null, ...semRefazer, motivo_refazer: "Nenhum job agendado rodou ainda.", erro_ultimo_cron: null };
  }
  const maisRecente = comRun.reduce((a, b) => (Date.parse(b.inicio as string) > Date.parse(a.inicio as string) ? b : a));
  const falhou = etapas.some((e) => e.conclusion === "failure");
  const rodando = etapas.some((e) => e.status === "in_progress");
  return {
    ultimo_cron: {
      run_id: maisRecente.run_id as number,
      status: rodando ? "in_progress" : "completed",
      conclusion: rodando ? null : falhou ? "failure" : "success",
      run_attempt: 1,
      created_at: maisRecente.inicio,
      html_url: null,
      etapas,
    },
    ...semRefazer,
    erro_ultimo_cron: null,
  };
}

export async function handleRequest(req: Request, ctx: ApiSyncsContext = {}): Promise<Response> {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return jsonResponse({ error: "Método não permitido. Utilize POST." }, 405);

  const cron = (ctx.isCron ?? ((r: Request) => authenticateCron(r) === "CRON_AUTHENTICATED"))(req);
  if (!cron) {
    const user = await (ctx.getUser ?? authenticateUser)(req);
    if (!user) return jsonResponse({ error: "Unauthorized" }, 401);
    if (!isLicitagymAdmin(user)) return jsonResponse({ error: "Sem permissão: só administradores disparam sync." }, 403);
  }

  let body: Record<string, unknown> = {};
  try {
    const parsed = await req.json();
    if (typeof parsed === "object" && parsed !== null && !Array.isArray(parsed)) body = parsed as Record<string, unknown>;
  } catch {
    return jsonResponse({ error: "Corpo JSON inválido." }, 400);
  }

  const action = body.action ?? "listar";
  const agora = (ctx.agora ?? (() => new Date()))();
  if (action === "estado_pca") {
    if (cron) {
      return jsonResponse({ error: "Sem permissão: consulta restrita a administradores." }, 403);
    }
    return await responderEstadoPca(body, agora, ctx.lerEstadoPca);
  }
  if (action === "listar") {
    const ler = ctx.lerStatusCron ?? statusPadrao;
    const syncs = await Promise.all(SYNCS.map(async (s) => {
      if (!s.cron_jobs || s.cron_jobs.length === 0) return s;
      const estado = await estadoCron(s.cron_jobs, ler);
      return { ...s, ...estado };
    }));
    return jsonResponse({ action: "listar", syncs });
  }
  if (action === "refazer") {
    // O "refazer" existia só para runs do GitHub Actions. No Supabase os ticks do pg_cron retomam sozinhos.
    return jsonResponse({ error: "Sem refazer: os jobs rodam no pg_cron e se retomam sozinhos. Use 'Rodar agora'." }, 400);
  }
  if (action !== "rodar") return jsonResponse({ error: "Ação não suportada. Use 'listar' ou 'rodar'." }, 400);

  const slug = body.sync;
  if (typeof slug !== "string" || !slug) return jsonResponse({ error: "Informe sync." }, 400);
  const item = syncPorSlug(slug);
  if (!item) return jsonResponse({ error: "Sync desconhecido." }, 400);
  if (!item.disparavel || (!item.funcao && !item.rpc)) {
    return jsonResponse({ error: item.aviso ?? "Este sync não dispara daqui." }, 400);
  }

  if (item.rpc) {
    // Função SQL do próprio banco: nada sai do Supabase.
    try {
      const resposta = await (ctx.chamarRpc ?? rpcPadrao)(item.rpc.nome, item.rpc.args);
      return jsonResponse({ action: "rodar", sync: item.slug, http: 200, resposta });
    } catch (e) {
      console.error("[api-syncs]", item.slug, e instanceof Error ? e.message : String(e));
      return jsonResponse({ error: "Falha ao executar a função SQL do sync." }, 502);
    }
  }

  const segredo = (ctx.segredo ?? segredoCron)();
  const base = (ctx.baseUrl ?? baseDasFuncoes)();
  if (!segredo || !base) return jsonResponse({ error: "Sync manual não configurado." }, 500);

  try {
    const fetchFn = ctx.fetchFn ?? fetch;
    const res = await fetchFn(`${base}/${item.funcao as string}`, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${segredo}`,
        "Content-Type": "application/json",
      },
      // origem manual: quem disparou foi a tela (spec 0023); o pg_cron manda origem cron no corpo do job.
      body: JSON.stringify({ ...item.corpo, origem: "manual" }),
      signal: AbortSignal.timeout(140_000),
    });
    const resposta = await corpoResposta(res);
    // 200 daqui significa que a função foi chamada. O status dela vai em `http`,
    // para a tela mostrar o corpo mesmo quando o sync recusa.
    return jsonResponse({
      action: "rodar",
      sync: item.slug,
      http: res.status,
      resposta,
    });
  } catch (e) {
    console.error("[api-syncs]", item.slug, e instanceof Error ? e.message : String(e));
    return jsonResponse({ error: "Falha ao chamar o sync." }, 502);
  }
}

if (import.meta.main) Deno.serve((req) => handleRequest(req));
