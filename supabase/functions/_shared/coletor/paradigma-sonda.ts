// Sonda dos portais Paradigma (Sistema S), spec 0071 fase 2, contrato K-7 (ação `sonda`).
//
// Somente leitura e sem gravar dado de licitação. Responde, por fonte, o que o portal devolve a partir do IP do
// Supabase: status HTTP de cada chamada e as CHAVES e tipos do payload (listagem, detalhe e itens do processo),
// para comparar portal a portal antes de dar perfil à fonte. Só valores públicos de texto curto (objeto) saem na
// resposta, para mostrar o formato do objeto da contratação.
//
// Regras de coleta respeitadas (as mesmas do adaptador Python, services/coletor-externo/coletor/paradigma.py):
//  - fonte inativa, pausada, ou com robots.txt `Disallow` sem `mural_autorizado`: não chama;
//  - 401/403 em qualquer chamada: para a fonte na hora, sem nova tentativa e sem contornar;
//  - 429 e 5xx: no máximo UMA nova tentativa (429 respeita Retry-After, com teto);
//  - intervalo mínimo de 1000 ms entre chamadas (`delay_ms` da fonte, nunca abaixo disso);
//  - orçamento de tempo por fonte; ao acabar, devolve o que já mediu.

export const UA = "LicitaGym-Coletor/1.1 (pesquisa de licitações públicas)";
export const DELAY_MINIMO_MS = 1000;
export const MODULO_PADRAO = 59;
export const TAMANHO_AMOSTRA_LISTAGEM = 20;

// Marcadores de "vazio" do Paradigma (portal.py: _NULO e _INT_NULO).
const NULO_TEXTO = "\u0013\u0012\u0012\u0013";
const NULO_INT = -2147483648;

export type FonteSonda = {
  slug: string;
  base_url: string;
  ativo: boolean;
  robots_permite: boolean | null;
  mural_autorizado: boolean;
  pausada_ate: string | null;
  delay_ms: number | null;
};

export type Fetcher = (url: string, init?: RequestInit) => Promise<Response>;

export type Chamada = {
  metodo: string;
  status: number | null;
  erro?: string;
  ms: number;
};

export type RelatorioFonte = {
  fonte: string;
  executada: boolean;
  motivo_nao_executada?: string;
  bloqueada: boolean;
  chamadas: Chamada[];
  listagem?: {
    linhas: number;
    chaves: string[];
    assinatura: string;
    amostra_objeto: string[];
  };
  detalhe?: { processos: number; chaves: string[]; assinatura: string; modulos: number[] };
  itens?: {
    processos_com_itens: number;
    total_itens: number;
    chaves: string[];
    assinatura: string;
    chaves_de_catalogo: string[];
  };
  avisos: string[];
};

/** Remove os marcadores de vazio do Paradigma (mesma regra de portal.limpar). */
export function limpar(v: unknown): unknown {
  if (v === NULO_TEXTO || v === NULO_INT) return null;
  if (Array.isArray(v)) return v.map(limpar);
  if (v && typeof v === "object") {
    return Object.fromEntries(Object.entries(v as Record<string, unknown>).map(([k, x]) => [k, limpar(x)]));
  }
  return v;
}

/** Chaves de primeiro nível, ordenadas. Não devolve valor. */
export function chavesDe(obj: unknown): string[] {
  if (!obj || typeof obj !== "object" || Array.isArray(obj)) return [];
  return Object.keys(obj as Record<string, unknown>).sort();
}

/** União das chaves de uma lista de objetos. */
export function uniaoDeChaves(lista: unknown[]): string[] {
  const s = new Set<string>();
  for (const x of lista) for (const k of chavesDe(x)) s.add(k);
  return [...s].sort();
}

export async function assinaturaDe(chaves: string[]): Promise<string> {
  const bytes = new TextEncoder().encode(chaves.join("|"));
  const h = await crypto.subtle.digest("SHA-256", bytes);
  return [...new Uint8Array(h)].slice(0, 6).map((b) => b.toString(16).padStart(2, "0")).join("");
}

/** Diferença entre dois conjuntos de chaves (referência x outra). */
export function compararChaves(ref: string[], outra: string[]) {
  const r = new Set(ref);
  const o = new Set(outra);
  return {
    so_na_referencia: ref.filter((k) => !o.has(k)),
    so_na_outra: outra.filter((k) => !r.has(k)),
    iguais: ref.length === outra.length && ref.every((k) => o.has(k)),
  };
}

/** Chaves que parecem de catálogo (classe, grupo, produto): onde procurar a estrutura Grupo → Classe → Produto. */
export function chavesDeCatalogo(chaves: string[]): string[] {
  return chaves.filter((k) => /classe|grupo|produto|catalog|familia|categoria/i.test(k));
}

export function podeSondar(f: FonteSonda, agora = new Date()): { ok: boolean; motivo?: string } {
  if (!f.ativo) return { ok: false, motivo: "fonte inativa" };
  if (f.pausada_ate && new Date(f.pausada_ate) > agora) {
    return { ok: false, motivo: `fonte pausada até ${f.pausada_ate}` };
  }
  if (f.robots_permite === false && !f.mural_autorizado) {
    return { ok: false, motivo: "robots.txt proíbe e a fonte não tem mural_autorizado" };
  }
  return { ok: true };
}

export function urlMural(base: string): string {
  return `${base.replace(/\/+$/, "")}/Mural.aspx`;
}
export function urlMetodo(base: string, metodo: string): string {
  return `${base.replace(/\/+$/, "")}/WebService/Servicos.asmx/${metodo}`;
}

export function corpoListagem(texto = "", de = 1, ate = TAMANHO_AMOSTRA_LISTAGEM) {
  return {
    dtoProcesso: {
      nAnoFinalizacao: 0,
      tmpTipoMuralProcesso: 2,
      nCdModulo: 0,
      nCdModalidade: 0,
      nCdModalidadeFase: 0,
      nCdTipoModalidade: 0,
      tmpTipoMuralVisao: 0,
      nCdSituacao: 0,
      nCdTipoProcesso: 0,
      nCdEmpresa: 0,
      sNrProcesso: "",
      nCdProcesso: 0,
      sDsObjeto: texto,
      sDtPeriodoDe: "",
      sDtPeriodoAte: "",
      sOrdenarPor: "NCDPROCESSO",
      sOrdenarPorDirecao: "DESC",
      dtoPaginacao: { nPaginaDe: de, nPaginaAte: ate },
      dtoIdioma: { nCdIdioma: 1 },
    },
  };
}

export function corpoDetalhe(id: number, modulo: number) {
  return {
    dtoProcesso: {
      nCdProcesso: id,
      nCdModulo: modulo,
      tmpTipoMuralProcesso: 0,
      dtoIdioma: { nCdIdioma: 1 },
    },
  };
}

export function moduloDe(x: unknown): number {
  const m = (x as { nCdModulo?: unknown } | null)?.nCdModulo;
  return typeof m === "number" && Number.isInteger(m) && m > 0 ? m : MODULO_PADRAO;
}

export function corpoItens(d: Record<string, unknown>) {
  return {
    dtoProcesso: {
      nCdProcesso: d.nCdProcesso,
      nCdModulo: moduloDe(d),
      sNrProcesso: d.sNrProcesso ?? null,
      nCdSituacao: d.nCdSituacao ?? null,
      tmpTipoMuralProcesso: 0,
      nCdLote: 0,
      dtoIdioma: { nCdIdioma: 1 },
    },
  };
}

function esperar(ms: number) {
  return new Promise((r) => setTimeout(r, ms));
}

export type OpcoesSonda = {
  fetcher?: Fetcher;
  dormir?: (ms: number) => Promise<void>;
  /** Quantos processos da listagem têm detalhe e itens lidos (1 a 3). */
  amostra?: number;
  /** Orçamento de tempo da fonte, em ms. */
  orcamentoMs?: number;
  timeoutMs?: number;
  /** Chamado a cada resposta HTTP (para `fonte_externa_registrar_resultado`). Falha dele não derruba a sonda. */
  registrar?: (slug: string, status: number) => Promise<void>;
  agora?: () => number;
};

class Bloqueio extends Error {}

export async function sondarFonte(f: FonteSonda, op: OpcoesSonda = {}): Promise<RelatorioFonte> {
  const fetcher = op.fetcher ?? ((u, i) => fetch(u, i));
  const dormir = op.dormir ?? esperar;
  const agora = op.agora ?? Date.now;
  const amostra = Math.min(Math.max(op.amostra ?? 2, 1), 3);
  const orcamentoMs = op.orcamentoMs ?? 40_000;
  const timeoutMs = op.timeoutMs ?? 15_000;
  const atraso = Math.max(f.delay_ms ?? DELAY_MINIMO_MS, DELAY_MINIMO_MS);

  const rel: RelatorioFonte = { fonte: f.slug, executada: false, bloqueada: false, chamadas: [], avisos: [] };
  const regra = podeSondar(f);
  if (!regra.ok) {
    rel.motivo_nao_executada = regra.motivo;
    return rel;
  }
  rel.executada = true;
  const inicio = agora();
  const noOrcamento = () => agora() - inicio < orcamentoMs;
  let primeira = true;

  async function chamar(metodo: string, url: string, init: RequestInit): Promise<Response | null> {
    for (let tentativa = 0; tentativa < 2; tentativa++) {
      if (!primeira) await dormir(atraso);
      primeira = false;
      const t0 = agora();
      let resp: Response;
      try {
        resp = await fetcher(url, {
          ...init,
          headers: { "User-Agent": UA, Accept: "application/json, text/plain, */*", ...(init.headers ?? {}) },
          signal: AbortSignal.timeout(timeoutMs),
          redirect: "manual",
        });
      } catch (e) {
        rel.chamadas.push({ metodo, status: null, erro: e instanceof Error ? e.name : "erro", ms: agora() - t0 });
        if (tentativa === 0 && noOrcamento()) continue;
        return null;
      }
      rel.chamadas.push({ metodo, status: resp.status, ms: agora() - t0 });
      try {
        await op.registrar?.(f.slug, resp.status);
      } catch {
        rel.avisos.push("falha ao registrar o resultado em fonte_externa_registrar_resultado");
      }
      if (resp.status === 401 || resp.status === 403) {
        rel.bloqueada = true;
        throw new Bloqueio(`${f.slug}: o host recusou o acesso (HTTP ${resp.status}); bloqueio não se contorna.`);
      }
      if ((resp.status === 429 || resp.status >= 500) && tentativa === 0 && noOrcamento()) {
        if (resp.status === 429) {
          const ra = Number(resp.headers.get("retry-after"));
          await dormir(Number.isFinite(ra) && ra > 0 ? Math.min(ra, 10) * 1000 : 2000);
        }
        continue;
      }
      return resp;
    }
    return null;
  }

  async function ws(metodo: string, corpo: unknown): Promise<unknown | null> {
    const r = await chamar(metodo, urlMetodo(f.base_url, metodo), {
      method: "POST",
      headers: { "Content-Type": "application/json; charset=utf-8" },
      body: JSON.stringify(corpo),
    });
    if (!r || r.status !== 200) {
      rel.avisos.push(`${metodo}: HTTP ${r?.status ?? "sem resposta"}`);
      return null;
    }
    try {
      const j = await r.json();
      return limpar((j as { d?: unknown }).d);
    } catch {
      rel.avisos.push(`${metodo}: resposta não é JSON`);
      return null;
    }
  }

  try {
    // 1. Mural: abre a sessão do portal e mede o status do host.
    const mural = await chamar("Mural.aspx", urlMural(f.base_url), { method: "GET" });
    if (!mural || mural.status >= 400) {
      rel.avisos.push(`Mural.aspx: HTTP ${mural?.status ?? "sem resposta"}`);
      return rel;
    }
    await mural.arrayBuffer().catch(() => undefined);

    // 2. Listagem.
    if (!noOrcamento()) {
      rel.avisos.push("orçamento de tempo esgotado antes da listagem");
      return rel;
    }
    const lista = await ws("PesquisarProcessos", corpoListagem());
    if (!Array.isArray(lista)) return rel;
    const chavesLista = uniaoDeChaves(lista);
    rel.listagem = {
      linhas: lista.length,
      chaves: chavesLista,
      assinatura: await assinaturaDe(chavesLista),
      amostra_objeto: lista
        .map((x) => (x as { sDsObjeto?: unknown }).sDsObjeto)
        .filter((s): s is string => typeof s === "string" && s.trim() !== "")
        .slice(0, 3)
        .map((s) => s.trim().slice(0, 100)),
    };

    // 3. Detalhe e itens de uma amostra pequena.
    const detalhes: Record<string, unknown>[] = [];
    const itensTodos: unknown[] = [];
    let comItens = 0;
    const modulos = new Set<number>();
    const candidatos = lista.filter((x) => {
      const id = (x as { nCdOrigem?: unknown }).nCdOrigem;
      return typeof id === "number" && Number.isInteger(id) && id > 0;
    }).slice(0, amostra);
    for (const x of candidatos) {
      if (!noOrcamento()) {
        rel.avisos.push("orçamento de tempo esgotado; amostra reduzida");
        break;
      }
      const id = (x as { nCdOrigem: number }).nCdOrigem;
      const mod = moduloDe(x);
      modulos.add(mod);
      const d = await ws("PesquisarProcessoDetalhes", corpoDetalhe(id, mod));
      if (!d || typeof d !== "object" || Array.isArray(d)) continue;
      const det = d as Record<string, unknown>;
      detalhes.push(det);
      if (!noOrcamento()) break;
      const its = await ws("PesquisarProcessoDetalheItemProduto", corpoItens(det));
      if (Array.isArray(its) && its.length > 0) {
        comItens++;
        itensTodos.push(...its);
      }
    }
    const chavesDet = uniaoDeChaves(detalhes);
    if (detalhes.length) {
      rel.detalhe = {
        processos: detalhes.length,
        chaves: chavesDet,
        assinatura: await assinaturaDe(chavesDet),
        modulos: [...modulos].sort((a, b) => a - b),
      };
    }
    const chavesIt = uniaoDeChaves(itensTodos);
    rel.itens = {
      processos_com_itens: comItens,
      total_itens: itensTodos.length,
      chaves: chavesIt,
      assinatura: await assinaturaDe(chavesIt),
      chaves_de_catalogo: chavesDeCatalogo(chavesIt),
    };
    return rel;
  } catch (e) {
    if (e instanceof Bloqueio) {
      rel.avisos.push(e.message);
      return rel;
    }
    throw e;
  }
}

/** Compara cada fonte com a primeira que respondeu (referência): o que muda de portal para portal. */
export function compararFontes(relatorios: RelatorioFonte[]) {
  const ref = relatorios.find((r) => r.listagem);
  if (!ref) return { referencia: null, diferencas: [] as unknown[] };
  const diferencas = relatorios.filter((r) => r !== ref && r.listagem).map((r) => ({
    fonte: r.fonte,
    listagem: compararChaves(ref.listagem!.chaves, r.listagem!.chaves),
    detalhe: ref.detalhe && r.detalhe ? compararChaves(ref.detalhe.chaves, r.detalhe.chaves) : null,
    itens: ref.itens?.chaves.length && r.itens?.chaves.length ? compararChaves(ref.itens.chaves, r.itens.chaves) : null,
  }));
  return { referencia: ref.fonte, diferencas };
}
