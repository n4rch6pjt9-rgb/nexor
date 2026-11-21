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
// A camada HTTP (ClientePortal) é compartilhada com a descoberta e a carga (paradigma-coleta.ts, fase 3).

export const UA = "LicitaGym-Coletor/1.1 (pesquisa de licitações públicas)";
export const DELAY_MINIMO_MS = 1000;
export const MODULO_PADRAO = 59;
export const TAMANHO_AMOSTRA_LISTAGEM = 20;

/** Marcadores de vazio do Paradigma (mesma regra de portal.limpar). */
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

export type Chamada = { metodo: string; status: number | null; erro?: string; ms: number };

export type RelatorioFonte = {
  fonte: string;
  executada: boolean;
  motivo_nao_executada?: string;
  bloqueada: boolean;
  chamadas: Chamada[];
  listagem?: { linhas: number; chaves: string[]; assinatura: string; amostra_objeto: string[] };
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

export function limpar(v: unknown): unknown {
  if (v === NULO_TEXTO || v === NULO_INT) return null;
  if (Array.isArray(v)) return v.map(limpar);
  if (v && typeof v === "object") {
    return Object.fromEntries(Object.entries(v as Record<string, unknown>).map(([k, x]) => [k, limpar(x)]));
  }
  return v;
}

export function chavesDe(obj: unknown): string[] {
  if (!obj || typeof obj !== "object" || Array.isArray(obj)) return [];
  return Object.keys(obj as Record<string, unknown>).sort();
}

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

export function compararChaves(ref: string[], outra: string[]) {
  const r = new Set(ref);
  const o = new Set(outra);
  return {
    so_na_referencia: ref.filter((k) => !o.has(k)),
    so_na_outra: outra.filter((k) => !r.has(k)),
    iguais: ref.length === outra.length && ref.every((k) => o.has(k)),
  };
}

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

export const METODOS_LISTAGEM = ["PesquisarProcessos", "PesquisarProcessosPorSituacoesAgrupadas"] as const;
export type MetodoListagem = (typeof METODOS_LISTAGEM)[number];
export type ParametrosListagem = { metodo?: MetodoListagem; tipoMural?: number; ordenarPor?: string; tamanho?: number };

/** Valida os parâmetros de listagem (perfil ou corpo da chamada). null = inválido. */
export function parametrosListagemValidos(v: unknown): ParametrosListagem | null {
  if (v === undefined) return {};
  if (!v || typeof v !== "object" || Array.isArray(v)) return null;
  const o = v as Record<string, unknown>;
  const r: ParametrosListagem = {};
  if (o.metodo !== undefined) {
    if (!(METODOS_LISTAGEM as readonly unknown[]).includes(o.metodo)) return null;
    r.metodo = o.metodo as MetodoListagem;
  }
  if (o.tipoMural !== undefined) {
    if (!Number.isInteger(o.tipoMural) || (o.tipoMural as number) < 0 || (o.tipoMural as number) > 9) return null;
    r.tipoMural = o.tipoMural as number;
  }
  if (o.ordenarPor !== undefined) {
    if (typeof o.ordenarPor !== "string" || !/^[A-Z]{3,20}$/.test(o.ordenarPor)) return null;
    r.ordenarPor = o.ordenarPor;
  }
  if (o.tamanho !== undefined) {
    if (!Number.isInteger(o.tamanho) || (o.tamanho as number) < 1 || (o.tamanho as number) > 50) return null;
    r.tamanho = o.tamanho as number;
  }
  return r;
}

export function corpoListagem(texto = "", de = 1, ate = TAMANHO_AMOSTRA_LISTAGEM, p: ParametrosListagem = {}) {
  return {
    dtoProcesso: {
      nAnoFinalizacao: 0,
      tmpTipoMuralProcesso: p.tipoMural ?? 2,
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
      sOrdenarPor: p.ordenarPor ?? "NCDPROCESSO",
      sOrdenarPorDirecao: "DESC",
      dtoPaginacao: { nPaginaDe: de, nPaginaAte: ate },
      dtoIdioma: { nCdIdioma: 1 },
    },
  };
}

export function corpoDetalhe(id: number, modulo: number) {
  return {
    dtoProcesso: { nCdProcesso: id, nCdModulo: modulo, tmpTipoMuralProcesso: 0, dtoIdioma: { nCdIdioma: 1 } },
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

function esperar(ms: number): Promise<void> {
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
  /** Chamado a cada resposta HTTP (para `fonte_externa_registrar_resultado`). Falha dele não derruba a chamada. */
  registrar?: (slug: string, status: number) => Promise<void>;
  listagem?: ParametrosListagem;
  agora?: () => number;
};

export class Bloqueio extends Error {}

/**
 * Camada HTTP de um portal Paradigma, com as regras de coleta (ver o topo do arquivo). Compartilhada pela sonda e
 * pela descoberta: o bloqueio (401/403) para a fonte na hora, 429/5xx tem uma nova tentativa, o intervalo mínimo vale.
 */
export class ClientePortal {
  readonly chamadas: Chamada[] = [];
  readonly avisos: string[] = [];
  bloqueada = false;
  private primeira = true;
  private readonly inicio: number;
  private readonly fetcher: Fetcher;
  private readonly dormir: (ms: number) => Promise<void>;
  private readonly agora: () => number;
  private readonly orcamentoMs: number;
  private readonly timeoutMs: number;
  private readonly atraso: number;

  constructor(private readonly f: FonteSonda, private readonly op: OpcoesSonda = {}) {
    this.fetcher = op.fetcher ?? ((u, i) => fetch(u, i));
    this.dormir = op.dormir ?? esperar;
    this.agora = op.agora ?? Date.now;
    this.orcamentoMs = op.orcamentoMs ?? 40_000;
    this.timeoutMs = op.timeoutMs ?? 15_000;
    this.atraso = Math.max(f.delay_ms ?? DELAY_MINIMO_MS, DELAY_MINIMO_MS);
    this.inicio = this.agora();
  }

  noOrcamento(): boolean {
    return this.agora() - this.inicio < this.orcamentoMs;
  }

  async chamar(metodo: string, url: string, init: RequestInit): Promise<Response | null> {
    const { f, op } = this;
    for (let tentativa = 0; tentativa < 2; tentativa++) {
      if (!this.primeira) await this.dormir(this.atraso);
      this.primeira = false;
      const t0 = this.agora();
      let resp: Response;
      try {
        resp = await this.fetcher(url, {
          ...init,
          headers: { "User-Agent": UA, Accept: "application/json, text/plain, */*", ...(init.headers ?? {}) },
          signal: AbortSignal.timeout(this.timeoutMs),
          redirect: "manual",
        });
      } catch (e) {
        this.chamadas.push({ metodo, status: null, erro: e instanceof Error ? e.name : "erro", ms: this.agora() - t0 });
        if (tentativa === 0 && this.noOrcamento()) continue;
        return null;
      }
      this.chamadas.push({ metodo, status: resp.status, ms: this.agora() - t0 });
      try {
        await op.registrar?.(f.slug, resp.status);
      } catch {
        this.avisos.push("falha ao registrar o resultado em fonte_externa_registrar_resultado");
      }
      if (resp.status === 401 || resp.status === 403) {
        this.bloqueada = true;
        throw new Bloqueio(`${f.slug}: o host recusou o acesso (HTTP ${resp.status}); bloqueio não se contorna.`);
      }
      if ((resp.status === 429 || resp.status >= 500) && tentativa === 0 && this.noOrcamento()) {
        if (resp.status === 429) {
          const ra = Number(resp.headers.get("retry-after"));
          await this.dormir(Number.isFinite(ra) && ra > 0 ? Math.min(ra, 10) * 1000 : 2000);
        }
        continue;
      }
      return resp;
    }
    return null;
  }

  /** Abre a sessão do portal. Devolve o status, ou null se o host não respondeu. */
  async mural(): Promise<number | null> {
    const r = await this.chamar("Mural.aspx", urlMural(this.f.base_url), { method: "GET" });
    if (!r) return null;
    await r.arrayBuffer().catch(() => undefined);
    return r.status;
  }

  async ws(metodo: string, corpo: unknown): Promise<unknown | null> {
    const r = await this.chamar(metodo, urlMetodo(this.f.base_url, metodo), {
      method: "POST",
      headers: { "Content-Type": "application/json; charset=utf-8" },
      body: JSON.stringify(corpo),
    });
    if (!r || r.status !== 200) {
      this.avisos.push(`${metodo}: HTTP ${r?.status ?? "sem resposta"}`);
      return null;
    }
    try {
      const j = await r.json();
      return limpar((j as { d?: unknown }).d);
    } catch {
      this.avisos.push(`${metodo}: resposta não é JSON`);
      return null;
    }
  }
}

export async function sondarFonte(f: FonteSonda, op: OpcoesSonda = {}): Promise<RelatorioFonte> {
  const amostra = Math.min(Math.max(op.amostra ?? 2, 1), 3);
  const c = new ClientePortal(f, op);
  const rel: RelatorioFonte = { fonte: f.slug, executada: false, bloqueada: false, chamadas: c.chamadas, avisos: c.avisos };
  const regra = podeSondar(f);
  if (!regra.ok) {
    rel.motivo_nao_executada = regra.motivo;
    return rel;
  }
  rel.executada = true;
  const noOrcamento = () => c.noOrcamento();
  const ws = (m: string, corpo: unknown) => c.ws(m, corpo);

  try {
    // 1. Mural: abre a sessão do portal e mede o status do host.
    const mural = await c.mural();
    if (mural === null || mural >= 400) {
      rel.avisos.push(`Mural.aspx: HTTP ${mural ?? "sem resposta"}`);
      return rel;
    }

    // 2. Listagem.
    if (!noOrcamento()) {
      rel.avisos.push("orçamento de tempo esgotado antes da listagem");
      return rel;
    }
    const lista = await ws(op.listagem?.metodo ?? "PesquisarProcessos", corpoListagem("", 1, op.listagem?.tamanho ?? TAMANHO_AMOSTRA_LISTAGEM, op.listagem));
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
      if (!d || typeof d !== "object" || Array.isArray(d)) {
        rel.avisos.push(`PesquisarProcessoDetalhes (processo ${id}, módulo ${mod}): .d veio ${d === null ? "nulo" : Array.isArray(d) ? "lista" : typeof d}`);
        continue;
      }
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
      rel.bloqueada = true;
      rel.avisos.push(e.message);
      return rel;
    }
    throw e;
  }
}

/** Compara as chaves de cada portal com a primeira fonte que respondeu (a referência). */
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
