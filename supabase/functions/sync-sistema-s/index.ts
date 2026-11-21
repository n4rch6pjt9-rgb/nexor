import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { corsHeaders, jsonResponse, requireCronAuth } from "../_shared/http.ts";
import { createServiceClient } from "../_shared/pncp/supabase-admin.ts";
import { compararFontes, type FonteSonda, parametrosListagemValidos, sondarFonte } from "../_shared/coletor/paradigma-sonda.ts";

// Spec 0071 (fase 2), contrato K-7. Por enquanto só a ação `sonda`: somente leitura, não grava licitação.
// `descobrir` e `carregar` entram na fase 3 (junto do tick), depois de a sonda comparar os portais.

const FONTES_PILOTO = ["sescdn", "firjan", "sescsp"];
const MAX_FONTES = 4;

const COLUNAS = "slug, base_url, ativo, robots_permite, mural_autorizado, pausada_ate, delay_ms";

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
  if (body.acao !== "sonda") {
    return jsonResponse({ error: "acao inválida; nesta fase só existe 'sonda'" }, 400);
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
  const porSlug = new Map((data as FonteSonda[]).map((f) => [f.slug, f]));

  const registrar = async (slug: string, status: number) => {
    const { error: e } = await client.rpc("fonte_externa_registrar_resultado", {
      p_slug: slug,
      p_http_status: status,
    });
    if (e) throw new Error(e.message);
  };

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
    relatorios.push(await sondarFonte(f, { amostra, registrar, listagem }));
  }
  return jsonResponse({ acao: "sonda", somente_leitura: true, relatorios, comparacao: compararFontes(relatorios) });
});
