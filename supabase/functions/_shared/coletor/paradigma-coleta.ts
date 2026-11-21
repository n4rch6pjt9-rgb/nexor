// Spec 0071 (fase 3): descoberta e carga do Paradigma na Edge Function, sem GitHub Actions.
//
// Espelha o adaptador Python (services/coletor-externo/coletor/paradigma.py) nas duas etapas da spec 0064:
//   descobrir: lista o mural pelo perfil da fonte e enfileira (coleta_externa_fila_enfileirar), sem hidratar;
//   carregar:  reserva uma fatia da fila, lê detalhe e itens de cada processo e grava em licitacoes_externas e
//              licitacao_itens.
// Fora desta fase (ficam para a reclassificação de escopo e para a fase 4): categoria_escopo, interesse_borracha,
// perfil do item, fórum, lances, resultados e documentos. As linhas gravadas aqui não trazem esses campos, e o
// upsert não os apaga (PostgREST só atualiza as colunas enviadas).
//
// Acesso ao banco entra por `Repositorio`, para os testes rodarem sem Supabase. Regras de coleta (robots, bloqueio,
// retry, intervalo) ficam no ClientePortal da sonda.
import {
  ClientePortal,
  corpoDetalhe,
  corpoItens,
  corpoListagem,
  type FonteSonda,
  MODULO_PADRAO,
  moduloDe,
  type OpcoesSonda,
  type ParametrosListagem,
} from "./paradigma-sonda.ts";

export const SITUACOES_DESCOBERTA = ["em proposta", "em andamento", "finalizado"];
export const JANELA_DESCOBERTA_DIAS = 730;
export const CAMPOS_HASH_LISTAGEM = [
  "sDsObjeto", "sDsSituacao", "nCdSituacao", "tDtInicial", "tDtFinal", "tDtEncerrado", "dVlEstimado", "dVlNegociado",
];
const MAX_PAGINAS_DESCOBERTA = 200;
const DECIMAL_NULO_LIMITE = -1e20;

export type Linha = Record<string, unknown>;

export type FonteColeta = FonteSonda & { entidade: string | null; uf: string | null };

export interface Repositorio {
  enfileirar(fonte: string, itens: Linha[]): Promise<{ novos: number; reabertos: number; inalterados: number }>;
  reservar(fonte: string, limite: number): Promise<{ id: number; n_cd_origem: number; modulo: number; listagem: Linha }[]>;
  marcar(id: number, ok: boolean | null, erro?: string): Promise<void>;
  gravarLicitacao(linha: Linha): Promise<number>;
  gravarItens(linhas: Linha[]): Promise<void>;
}

// ---------- utilitários de dado ----------

export function normalizar(t: string | null | undefined): string {
  return (t ?? "").normalize("NFKD").replace(/[̀-ͯ]/g, "").toLowerCase();
}

/** '/Date(1786622400000)/' -> ISO-8601; data zerada ou negativa -> null (mesma regra de portal.parse_data). */
export function parseData(v: unknown): string | null {
  if (typeof v !== "string") return null;
  const m = /\/Date\((-?\d+)/.exec(v);
  if (!m) return null;
  const ms = Number(m[1]);
  return ms > 0 ? new Date(ms).toISOString() : null;
}

/** System.Decimal.MinValue, zero e negativos viram null. */
export function valor(v: unknown): number | null {
  return typeof v === "number" && v > 0 && v > DECIMAL_NULO_LIMITE ? v : null;
}

export function statusNormalizado(situacao: string | null | undefined): string {
  const s = normalizar(situacao);
  if (!s) return "desconhecida";
  if (s.startsWith("recebimento")) return "aberta";
  if ((s.includes("aguard") && s.includes("homolog")) || s.includes("em aprovac")) return "em_julgamento";
  if (s.includes("homolog") && s.includes("parcial")) return "homologada";
  if (["fracass", "desert"].some((k) => s.includes(k))) return "sem_vencedor";
  if (s.includes("homolog")) return "homologada";
  if (["cancel", "revog", "anul", "suspens"].some((k) => s.includes(k))) {
    return s.includes("suspens") ? "suspensa" : "cancelada";
  }
  if (["julg", "analis", "habilit", "negocia", "disputa", "lance"].some((k) => s.includes(k))) return "em_julgamento";
  if (["andamento", "public", "recebend", "aberto", "abert"].some((k) => s.includes(k))) return "aberta";
  if (["encerr", "finaliz", "adjudic", "conclu"].some((k) => s.includes(k))) return "encerrada";
  return "desconhecida";
}

function fimDoPrazo(iso: string | null): number | null {
  return iso ? new Date(iso).getTime() : null;
}

export function prioridadeDaCompra(status: string, dataFimIso: string | null, agora = new Date()): string | null {
  if (["encerrada", "homologada", "cancelada", "sem_vencedor"].includes(status)) return "historico";
  if (["em_julgamento", "suspensa"].includes(status)) return "monitorar";
  if (status === "aberta") {
    const fim = fimDoPrazo(dataFimIso);
    if (fim === null) return "monitorar";
    return fim > agora.getTime() ? "leads" : "monitorar";
  }
  return null;
}

export function acionabilidade(status: string, dataFimIso: string | null, agora = new Date()): string {
  if (["homologada", "cancelada", "sem_vencedor", "encerrada"].includes(status)) return "NOT_ACTIONABLE";
  const fim = fimDoPrazo(dataFimIso);
  if (status === "aberta" && fim !== null) return fim > agora.getTime() ? "ACTIONABLE" : "NOT_ACTIONABLE";
  return "ACTIONABILITY_UNRESOLVED";
}

// ---------- descoberta ----------

function inteiroPositivo(v: unknown): v is number {
  return typeof v === "number" && Number.isInteger(v) && v > 0;
}

/** Linha do mural que vai para a fila: id válido, situação aceita (se a linha a traz) e início nos últimos 24 meses
 *  (se a linha o traz). Dado ausente não vira exclusão. */
export function aceitaNaDescoberta(x: Linha, agora = new Date()): boolean {
  if (!inteiroPositivo(x?.nCdOrigem)) return false;
  const sit = x.sDsSituacao;
  if (typeof sit === "string" && sit.trim()) {
    const s = normalizar(sit).trim();
    if (!SITUACOES_DESCOBERTA.some((a) => s.startsWith(a))) return false;
  }
  const inicio = parseData(x.tDtInicial);
  if (inicio && new Date(inicio).getTime() < agora.getTime() - JANELA_DESCOBERTA_DIAS * 86400_000) return false;
  return true;
}

function jsonPython(v: unknown): string {
  // Mesmo formato do json.dumps(sort_keys=True, ensure_ascii=False) do adaptador Python, para o hash coincidir
  // enquanto os dois coletores convivem. Número inteiro vindo como float no Python ("1500.0") pode divergir: o
  // custo é uma reabertura única na fila, nunca perda de dado.
  if (v === null || v === undefined) return "null";
  if (typeof v === "string") return JSON.stringify(v);
  if (typeof v === "number" || typeof v === "boolean") return String(v);
  if (Array.isArray(v)) return `[${v.map(jsonPython).join(", ")}]`;
  const o = v as Record<string, unknown>;
  return `{${Object.keys(o).sort().map((k) => `${JSON.stringify(k)}: ${jsonPython(o[k])}`).join(", ")}}`;
}

export async function hashListagem(x: Linha): Promise<string> {
  const base: Linha = {};
  for (const k of CAMPOS_HASH_LISTAGEM) base[k] = x?.[k] ?? null;
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(jsonPython(base)));
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

export type ResumoDescoberta = {
  paginas: number;
  listados: number;
  descartados: number;
  fila: { novos: number; reabertos: number; inalterados: number };
  completa: boolean;
  avisos: string[];
};

export type OpcoesColeta = OpcoesSonda & {
  /** Teto de páginas por execução da descoberta (o mural é lido do mais novo para o mais velho). */
  maxPaginas?: number;
  agoraData?: () => Date;
};

/** Lista o mural pelo perfil e enfileira página a página. Erro de página para a descoberta (nunca vira lista vazia);
 *  o que já entrou na fila fica, porque enfileirar é idempotente. */
export async function descobrirFonte(
  f: FonteColeta,
  repo: Repositorio,
  listagem: ParametrosListagem,
  op: OpcoesColeta = {},
): Promise<{ resumo: ResumoDescoberta; chamadas: ClientePortal["chamadas"]; bloqueada: boolean }> {
  const c = new ClientePortal(f, op);
  const resumo: ResumoDescoberta = {
    paginas: 0, listados: 0, descartados: 0, fila: { novos: 0, reabertos: 0, inalterados: 0 }, completa: false, avisos: c.avisos,
  };
  const tamanho = listagem.tamanho ?? 20;
  const maxPaginas = Math.min(op.maxPaginas ?? 5, MAX_PAGINAS_DESCOBERTA);
  const agora = op.agoraData?.() ?? new Date();
  const metodo = listagem.metodo ?? "PesquisarProcessos";
  try {
    const mural = await c.mural();
    if (mural === null || mural >= 400) {
      c.avisos.push(`Mural.aspx: HTTP ${mural ?? "sem resposta"}`);
      return { resumo, chamadas: c.chamadas, bloqueada: c.bloqueada };
    }
    const vistas = new Set<number>();
    let de = 1;
    while (resumo.paginas < maxPaginas) {
      if (!c.noOrcamento()) {
        c.avisos.push("orçamento de tempo esgotado na descoberta");
        break;
      }
      const ate = de + tamanho - 1;
      const pagina = await c.ws(metodo, corpoListagem("", de, ate, listagem));
      if (!Array.isArray(pagina)) {
        c.avisos.push(`${metodo} ${de}-${ate}: resposta sem lista; descoberta interrompida`);
        break;
      }
      resumo.paginas++;
      if (pagina.length === 0) {
        resumo.completa = true;
        break;
      }
      const linhas = pagina.filter((x): x is Linha => !!x && typeof x === "object");
      const novas = linhas.filter((x) => !(inteiroPositivo(x.nCdOrigem) && vistas.has(x.nCdOrigem)));
      if (novas.length === 0) {
        c.avisos.push(`página ${resumo.paginas}: conteúdo repetido; descoberta interrompida (não é fim confirmado)`);
        break;
      }
      for (const x of linhas) if (inteiroPositivo(x.nCdOrigem)) vistas.add(x.nCdOrigem);
      resumo.listados += linhas.length;
      const aceitos = linhas.filter((x) => aceitaNaDescoberta(x, agora));
      resumo.descartados += linhas.length - aceitos.length;
      if (aceitos.length) {
        const itens: Linha[] = [];
        for (const x of aceitos) {
          itens.push({ nCdOrigem: x.nCdOrigem, modulo: moduloDe(x), listagem: x, hash: await hashListagem(x) });
        }
        const r = await repo.enfileirar(f.slug, itens);
        resumo.fila.novos += r.novos;
        resumo.fila.reabertos += r.reabertos;
        resumo.fila.inalterados += r.inalterados;
      }
      if (linhas.length < tamanho) {
        resumo.completa = true;
        break;
      }
      de += linhas.length;
    }
    if (!resumo.completa && resumo.paginas >= maxPaginas) {
      c.avisos.push(`teto de ${maxPaginas} páginas por execução atingido; a próxima execução recomeça do mais novo`);
    }
  } catch (e) {
    if (!c.bloqueada) throw e;
    c.avisos.push(e instanceof Error ? e.message : String(e));
  }
  return { resumo, chamadas: c.chamadas, bloqueada: c.bloqueada };
}

// ---------- carga ----------

export function linhaLicitacao(f: FonteColeta, d: Linha, listagem: Linha = {}, agora = new Date()): Linha {
  const st = statusNormalizado(d.sDsSituacao as string | undefined);
  const fim = parseData(d.tDtFinal);
  const prio = prioridadeDaCompra(st, fim, agora);
  const modalidade = String(d.sNmModalidadeTipo ?? d.sNmModalidade ?? "").trim() || null;
  const objeto = String(d.sDsObjeto ?? "").trim() || null;
  const linha: Linha = {
    fonte: f.slug,
    modulo: inteiroPositivo(d.nCdModulo) ? d.nCdModulo : MODULO_PADRAO,
    id_externo: d.nCdProcesso,
    codigo_externo: String(d.nCdProcesso),
    numero_processo: d.sNrProcesso ?? null,
    numero_edital: d.sNrEdital ?? null,
    objeto,
    unidade_compradora: d.sNmEmpresa ?? null,
    orgao_nome: d.sNmEmpresa ?? null,
    entidade: f.entidade,
    uf: f.uf,
    modalidade,
    regulamento: modalidade && /sele[cç][aã]o/i.test(modalidade) ? "RCA" : null,
    fase: d.sDsFase ?? null,
    situacao: d.sDsSituacao ?? null,
    status_normalizado: st,
    acionabilidade: acionabilidade(st, fim, agora),
    data_inicio: parseData(d.tDtInicial),
    data_fim: fim,
    data_homologacao: parseData(d.tDtHomologacao),
    valor_total: valor(d.dVlTotal) ?? valor(listagem.dVlEstimado),
    anexo_raiz_id: d.nCdAnexo ?? null,
    raw: d,
    last_synced_at: agora.toISOString(),
    ingestao_origem: "sistema_s_cron",
  };
  if (prio !== null) linha.prioridade = prio;
  return linha;
}

const ITEM_SEQ = /^\s*(\d+)\s*-\s*/;

export function partesItem(sDsItem: unknown): { sequencial: number | null; categoria: string | null; variacao: string | null; descricao: string | null } {
  const texto = String(sDsItem ?? "").replace(/\r\n/g, "\n").trim();
  const linhas = texto.split("\n").map((l) => l.trim());
  const primeira = linhas[0] ?? "";
  const m = ITEM_SEQ.exec(primeira);
  let variacao: string | null = null;
  for (const l of linhas.slice(1)) {
    if (normalizar(l).startsWith("variacao:")) {
      variacao = l.split(":").slice(1).join(":").trim() || null;
      break;
    }
  }
  return {
    sequencial: m ? Number(m[1]) : null,
    categoria: primeira.replace(ITEM_SEQ, "").trim() || null,
    variacao,
    descricao: texto || null,
  };
}

const COD_CATALOGO = /^\s*([A-Z]{2}\d{7})\s*-/;

export function linhasItens(licitacaoId: number, itens: Linha[]): Linha[] {
  const out: Linha[] = [];
  const vistos = new Set<number>();
  for (const it of itens) {
    const p = partesItem(it.sDsItem);
    const numero = inteiroPositivo(it.nCdItemSequencial) ? it.nCdItemSequencial : p.sequencial;
    if (numero === null || vistos.has(numero)) continue; // sem número não há chave de upsert; repetido no lote conflitaria
    vistos.add(numero);
    const qtd = typeof it.dQtItem === "number" && it.dQtItem > 0 ? it.dQtItem : null;
    const vref = valor(it.dVlReferencia);
    const cod = COD_CATALOGO.exec(p.descricao ?? "");
    out.push({
      licitacao_id: licitacaoId,
      numero_item: numero,
      id_item_externo: it.nCdItem ?? null,
      descricao: p.descricao,
      categoria_fornecedor: p.categoria,
      variacao: p.variacao,
      quantidade: qtd,
      unidade_medida: it.sDsUnidadeMedida ?? null,
      valor_unitario_estimado: vref,
      valor_total_estimado: vref && qtd ? Math.round(vref * qtd * 100) / 100 : null,
      catalogo_codigo_item: cod ? cod[1] : null,
      situacao: it.sStItem ?? null,
      raw: it,
    });
  }
  return out;
}

export type ResumoCarga = {
  reservados: number;
  gravados: number;
  sem_detalhe: number;
  itens: number;
  erros: { id: number; n_cd_origem: number; erro: string }[];
  avisos: string[];
};

/** Reserva até `limite` processos da fila e os hidrata. Falha de um processo o devolve à fila (com tentativa) e segue;
 *  bloqueio do host (401/403) ou fim do orçamento devolve o resto sem contar tentativa. */
export async function carregarFonte(
  f: FonteColeta,
  repo: Repositorio,
  limite: number,
  op: OpcoesColeta = {},
): Promise<{ resumo: ResumoCarga; chamadas: ClientePortal["chamadas"]; bloqueada: boolean }> {
  const c = new ClientePortal(f, op);
  const resumo: ResumoCarga = { reservados: 0, gravados: 0, sem_detalhe: 0, itens: 0, erros: [], avisos: c.avisos };
  const agora = op.agoraData?.() ?? new Date();
  const reservados = await repo.reservar(f.slug, limite);
  resumo.reservados = reservados.length;
  if (!reservados.length) return { resumo, chamadas: c.chamadas, bloqueada: false };

  const devolvidos = new Set<number>();
  const devolver = async (id: number) => {
    if (devolvidos.has(id)) return;
    devolvidos.add(id);
    await repo.marcar(id, null);
  };
  try {
    const mural = await c.mural();
    if (mural === null || mural >= 400) {
      c.avisos.push(`Mural.aspx: HTTP ${mural ?? "sem resposta"}`);
      for (const r of reservados) await devolver(r.id);
      return { resumo, chamadas: c.chamadas, bloqueada: c.bloqueada };
    }
    for (const r of reservados) {
      if (!c.noOrcamento()) {
        c.avisos.push("orçamento de tempo esgotado; o restante volta à fila");
        break;
      }
      try {
        const d = await c.ws("PesquisarProcessoDetalhes", corpoDetalhe(r.n_cd_origem, r.modulo));
        if (!d || typeof d !== "object" || Array.isArray(d)) {
          resumo.sem_detalhe++;
          await repo.marcar(r.id, false, `detalhe sem objeto (.d ${d === null ? "nulo" : Array.isArray(d) ? "lista" : typeof d})`);
          devolvidos.add(r.id);
          continue;
        }
        const det = d as Linha;
        if (!inteiroPositivo(det.nCdProcesso)) {
          await repo.marcar(r.id, false, "detalhe sem nCdProcesso");
          devolvidos.add(r.id);
          continue;
        }
        if (!c.noOrcamento()) {
          c.avisos.push("orçamento de tempo esgotado entre o detalhe e os itens; o restante volta à fila");
          break;
        }
        const its = await c.ws("PesquisarProcessoDetalheItemProduto", corpoItens(det));
        const listaItens = Array.isArray(its) ? its.filter((x): x is Linha => !!x && typeof x === "object") : [];
        if (its !== null && !Array.isArray(its)) c.avisos.push(`processo ${r.n_cd_origem}: itens vieram em formato inesperado`);
        const licId = await repo.gravarLicitacao(linhaLicitacao(f, det, r.listagem, agora));
        const linhas = linhasItens(licId, listaItens);
        if (linhas.length) await repo.gravarItens(linhas);
        resumo.gravados++;
        resumo.itens += linhas.length;
        await repo.marcar(r.id, true);
        devolvidos.add(r.id);
      } catch (e) {
        if (c.bloqueada) throw e;
        const msg = e instanceof Error ? e.message : String(e);
        resumo.erros.push({ id: r.id, n_cd_origem: r.n_cd_origem, erro: msg.slice(0, 300) });
        await repo.marcar(r.id, false, msg);
        devolvidos.add(r.id);
      }
    }
  } catch (e) {
    if (!c.bloqueada) throw e;
    c.avisos.push(e instanceof Error ? e.message : String(e));
  } finally {
    // o que não foi marcado (orçamento, bloqueio) volta à fila sem consumir tentativa
    for (const r of reservados) await devolver(r.id);
  }
  return { resumo, chamadas: c.chamadas, bloqueada: c.bloqueada };
}
