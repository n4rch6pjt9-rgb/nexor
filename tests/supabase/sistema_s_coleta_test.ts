import { assert, assertEquals } from "jsr:@std/assert@1";
import {
  aceitaNaDescoberta,
  acionabilidade,
  carregarFonte,
  descobrirFonte,
  type FonteColeta,
  hashListagem,
  linhaLicitacao,
  linhasItens,
  type Linha,
  parseData,
  partesItem,
  prioridadeDaCompra,
  type Repositorio,
  statusNormalizado,
  valor,
} from "../../supabase/functions/_shared/coletor/paradigma-coleta.ts";

const BASE = "https://portal.exemplo.invalid/sescdn/portal";
const fonte = (o: Partial<FonteColeta> = {}): FonteColeta => ({
  slug: "t1",
  base_url: BASE,
  ativo: true,
  robots_permite: null,
  mural_autorizado: false,
  pausada_ate: null,
  delay_ms: 1000,
  entidade: "SESC",
  uf: "DN",
  ...o,
});
const sem = async () => {};
const pagDe = (c: Linha) => ((c.dtoProcesso as Linha).dtoPaginacao as Linha).nPaginaDe as number;
const AGORA = new Date("2026-11-21T12:00:00Z");
const ms = (iso: string) => `/Date(${new Date(iso).getTime()})/`;
const d = (x: unknown) => new Response(JSON.stringify({ d: x }), { status: 200 });

function servidor(rotas: Record<string, (corpo: Linha) => Response>) {
  const chamadas: string[] = [];
  const fetcher = async (url: string, init?: RequestInit) => {
    const m = url.endsWith("Mural.aspx") ? "Mural.aspx" : url.split("/").pop()!;
    chamadas.push(m);
    const corpo = init?.body ? JSON.parse(String(init.body)) : {};
    return (rotas[m] ?? (() => new Response("", { status: 404 })))(corpo);
  };
  return { fetcher, chamadas };
}

function repoFalso(reservas: { id: number; n_cd_origem: number; modulo: number; listagem: Linha }[] = []) {
  const enfileirados: Linha[][] = [];
  const marcas: [number, boolean | null, string | undefined][] = [];
  const licitacoes: Linha[] = [];
  const itens: Linha[][] = [];
  const repo: Repositorio = {
    enfileirar: async (_f: string, lote: Linha[]) => {
      enfileirados.push(lote);
      return { novos: lote.length, reabertos: 0, inalterados: 0 };
    },
    reservar: async () => reservas,
    marcar: async (id: number, ok: boolean | null, erro?: string) => {
      marcas.push([id, ok, erro]);
    },
    gravarLicitacao: async (l: Linha) => {
      licitacoes.push(l);
      return 900 + licitacoes.length;
    },
    gravarItens: async (l: Linha[]) => {
      itens.push(l);
    },
  };
  return { enfileirados, marcas, licitacoes, itens, repo };
}

const op = (fetcher: (u: string, i?: RequestInit) => Promise<Response>, extra = {}) => ({
  fetcher,
  dormir: sem,
  agoraData: () => AGORA,
  ...extra,
});

Deno.test("status, prioridade e acionabilidade seguem o adaptador Python", () => {
  assertEquals(statusNormalizado("Recebimento de propostas"), "aberta");
  assertEquals(statusNormalizado("Aguardando homologação"), "em_julgamento");
  assertEquals(statusNormalizado("Homologado parcialmente"), "homologada");
  assertEquals(statusNormalizado("Fracassado"), "sem_vencedor");
  assertEquals(statusNormalizado("Suspenso"), "suspensa");
  assertEquals(statusNormalizado(null), "desconhecida");
  const futuro = "2026-12-01T00:00:00.000Z";
  assertEquals(prioridadeDaCompra("aberta", futuro, AGORA), "leads");
  assertEquals(prioridadeDaCompra("aberta", "2026-01-01T00:00:00.000Z", AGORA), "monitorar");
  assertEquals(prioridadeDaCompra("desconhecida", null, AGORA), null);
  assertEquals(acionabilidade("aberta", futuro, AGORA), "ACTIONABLE");
  assertEquals(acionabilidade("homologada", null, AGORA), "NOT_ACTIONABLE");
  assertEquals(acionabilidade("em_julgamento", null, AGORA), "ACTIONABILITY_UNRESOLVED");
});

Deno.test("datas e valores do Paradigma", () => {
  assertEquals(parseData("/Date(1786622400000)/"), "2026-08-13T12:00:00.000Z");
  assertEquals(parseData("/Date(-62135596800000)/"), null);
  assertEquals(parseData(null), null);
  assertEquals(valor(-7.9e28), null);
  assertEquals(valor(0), null);
  assertEquals(valor(150.5), 150.5);
});

Deno.test("descoberta aceita só processo válido, de situação aceita e dos últimos 24 meses", () => {
  assert(aceitaNaDescoberta({ nCdOrigem: 10 }, AGORA));
  assert(!aceitaNaDescoberta({ nCdOrigem: 0 }, AGORA));
  assert(!aceitaNaDescoberta({ nCdOrigem: "10" }, AGORA));
  assert(aceitaNaDescoberta({ nCdOrigem: 10, sDsSituacao: "Finalizado com contrato" }, AGORA));
  assert(!aceitaNaDescoberta({ nCdOrigem: 10, sDsSituacao: "Cancelado" }, AGORA));
  assert(!aceitaNaDescoberta({ nCdOrigem: 10, tDtInicial: ms("2023-01-01T00:00:00Z") }, AGORA));
  assert(aceitaNaDescoberta({ nCdOrigem: 10, tDtInicial: ms("2026-06-01T00:00:00Z") }, AGORA));
});

Deno.test("hash da listagem ignora campo de exibição e muda com a situação", async () => {
  const a = await hashListagem({ sDsObjeto: "x", sDsSituacao: "Em andamento", nPagina: 1 });
  const b = await hashListagem({ sDsObjeto: "x", sDsSituacao: "Em andamento", nPagina: 7 });
  const c = await hashListagem({ sDsObjeto: "x", sDsSituacao: "Homologado" });
  assertEquals(a, b);
  assert(a !== c);
  assertEquals(a.length, 64);
});

Deno.test("partes do item e linhas de itens", () => {
  const p = partesItem("3 - Esteira\r\nVariação: elétrica\r\nDescrição: x");
  assertEquals([p.sequencial, p.categoria, p.variacao], [3, "Esteira", "elétrica"]);
  const linhas = linhasItens(5, [
    { nCdItem: 1, nCdItemSequencial: 1, sDsItem: "1 - Bola", dQtItem: 4, dVlReferencia: 10.5, sDsUnidadeMedida: "UN" },
    { nCdItem: 2, nCdItemSequencial: 2, sDsItem: "AB1234567 - Colchonete", dQtItem: 0, dVlReferencia: -7.9e28 },
    { nCdItem: 3, nCdItemSequencial: 1, sDsItem: "1 - repetido" },
    { nCdItem: 4, sDsItem: "sem numero" },
  ]);
  assertEquals(linhas.length, 2);
  assertEquals(linhas[0].valor_total_estimado, 42);
  assertEquals(linhas[0].licitacao_id, 5);
  assertEquals(linhas[1].quantidade, null);
  assertEquals(linhas[1].valor_unitario_estimado, null);
  assertEquals(linhas[1].catalogo_codigo_item, "AB1234567");
});

Deno.test("linha da licitação traz fonte, módulo, status e prioridade, sem campos de escopo", () => {
  const l = linhaLicitacao(fonte(), {
    nCdProcesso: 77, nCdModulo: 22, sDsObjeto: " Compra de bolas ", sDsSituacao: "Recebimento de propostas",
    tDtFinal: ms("2026-12-10T00:00:00Z"), sNmModalidadeTipo: "Seleção de fornecedores", dVlTotal: -7.9e28,
  }, { dVlEstimado: 1000 }, AGORA);
  assertEquals([l.fonte, l.modulo, l.id_externo, l.objeto], ["t1", 22, 77, "Compra de bolas"]);
  assertEquals([l.status_normalizado, l.prioridade, l.acionabilidade], ["aberta", "leads", "ACTIONABLE"]);
  assertEquals(l.regulamento, "RCA");
  assertEquals(l.valor_total, 1000);
  assert(!("categoria_escopo" in l) && !("interesse_borracha" in l) && !("escopo_estado" in l));
});

Deno.test("descobrir enfileira página a página e termina na página curta", async () => {
  const sv = servidor({
    "Mural.aspx": () => new Response("", { status: 302 }),
    PesquisarProcessos: (c) => {
      const de = pagDe(c);
      if (de === 1) return d([{ nCdOrigem: 1, nCdModulo: 22 }, { nCdOrigem: 2, sDsSituacao: "Cancelado" }]);
      return d([{ nCdOrigem: 3 }]);
    },
  });
  const r = repoFalso();
  const { resumo } = await descobrirFonte(fonte(), r.repo, { tamanho: 2 }, op(sv.fetcher));
  assertEquals(resumo.paginas, 2);
  assertEquals(resumo.listados, 3);
  assertEquals(resumo.descartados, 1);
  assertEquals(resumo.fila.novos, 2);
  assertEquals(resumo.completa, true);
  assertEquals(r.enfileirados[0][0].modulo, 22);
  assertEquals(r.enfileirados[1][0].nCdOrigem, 3);
});

Deno.test("descobrir respeita o teto de páginas e avisa que não terminou", async () => {
  const sv = servidor({
    "Mural.aspx": () => new Response("", { status: 302 }),
    PesquisarProcessos: (c) => {
      const de = pagDe(c);
      return d([{ nCdOrigem: de }, { nCdOrigem: de + 1 }]);
    },
  });
  const r = repoFalso();
  const { resumo } = await descobrirFonte(fonte(), r.repo, { tamanho: 2 }, op(sv.fetcher, { maxPaginas: 2 }));
  assertEquals(resumo.paginas, 2);
  assertEquals(resumo.completa, false);
  assert(resumo.avisos.some((a) => a.includes("teto de 2 páginas")));
});

Deno.test("descobrir para ao ver página repetida e não grava o repetido", async () => {
  const sv = servidor({
    "Mural.aspx": () => new Response("", { status: 302 }),
    PesquisarProcessos: () => d([{ nCdOrigem: 1 }, { nCdOrigem: 2 }]),
  });
  const r = repoFalso();
  const { resumo } = await descobrirFonte(fonte(), r.repo, { tamanho: 2 }, op(sv.fetcher, { maxPaginas: 5 }));
  assertEquals(resumo.paginas, 2);
  assertEquals(r.enfileirados.length, 1);
  assert(resumo.avisos.some((a) => a.includes("repetido")));
});

Deno.test("descobrir com 403 no mural não lista nem enfileira", async () => {
  const sv = servidor({ "Mural.aspx": () => new Response("", { status: 403 }) });
  const r = repoFalso();
  const out = await descobrirFonte(fonte(), r.repo, {}, op(sv.fetcher));
  assertEquals(out.bloqueada, true);
  assertEquals(r.enfileirados.length, 0);
  assertEquals(sv.chamadas, ["Mural.aspx"]);
});

Deno.test("descobrir resposta sem lista interrompe sem enfileirar", async () => {
  const sv = servidor({
    "Mural.aspx": () => new Response("", { status: 302 }),
    PesquisarProcessos: () => d(null),
  });
  const r = repoFalso();
  const { resumo } = await descobrirFonte(fonte(), r.repo, {}, op(sv.fetcher));
  assertEquals(resumo.paginas, 0);
  assertEquals(r.enfileirados.length, 0);
  assert(resumo.avisos.some((a) => a.includes("sem lista")));
});

const reserva = (id: number, o = 100 + id) => ({ id, n_cd_origem: o, modulo: 22, listagem: { dVlEstimado: 500 } });
const detalhe = (id: number) => ({
  nCdProcesso: id, nCdModulo: 22, sDsObjeto: "Compra", sDsSituacao: "Em andamento", sNrProcesso: "1/2026",
});

Deno.test("carregar grava licitação e itens e marca feito", async () => {
  const sv = servidor({
    "Mural.aspx": () => new Response("", { status: 302 }),
    PesquisarProcessoDetalhes: (c) => d(detalhe((c.dtoProcesso as Linha).nCdProcesso as number)),
    PesquisarProcessoDetalheItemProduto: () => d([{ nCdItem: 1, nCdItemSequencial: 1, sDsItem: "1 - Bola", dQtItem: 2 }]),
  });
  const r = repoFalso([reserva(1), reserva(2)]);
  const { resumo } = await carregarFonte(fonte(), r.repo, 2, op(sv.fetcher));
  assertEquals([resumo.reservados, resumo.gravados, resumo.itens, resumo.erros.length], [2, 2, 2, 0]);
  assertEquals(r.licitacoes.length, 2);
  assertEquals(r.itens[0][0].licitacao_id, 901);
  assertEquals(r.marcas, [[1, true, undefined], [2, true, undefined]]);
});

Deno.test("carregar: detalhe vazio conta tentativa; erro de gravação não derruba os demais", async () => {
  const sv = servidor({
    "Mural.aspx": () => new Response("", { status: 302 }),
    PesquisarProcessoDetalhes: (c) => {
      const id = (c.dtoProcesso as Linha).nCdProcesso as number;
      return id === 101 ? d(null) : d(detalhe(id));
    },
    PesquisarProcessoDetalheItemProduto: () => d([]),
  });
  const r = repoFalso([reserva(1), reserva(2), reserva(3)]);
  let n = 0;
  const grava = r.repo.gravarLicitacao;
  r.repo.gravarLicitacao = async (l: Linha) => {
    if (++n === 1) throw new Error("violação de restrição");
    return await grava(l);
  };
  const { resumo } = await carregarFonte(fonte(), r.repo, 3, op(sv.fetcher));
  assertEquals(resumo.sem_detalhe, 1);
  assertEquals(resumo.erros.length, 1);
  assertEquals(resumo.gravados, 1);
  assertEquals(r.marcas.map((m) => [m[0], m[1]]), [[1, false], [2, false], [3, true]]);
});

Deno.test("carregar: 403 no detalhe para a fonte e devolve o restante sem contar tentativa", async () => {
  const sv = servidor({
    "Mural.aspx": () => new Response("", { status: 302 }),
    PesquisarProcessoDetalhes: () => new Response("", { status: 403 }),
  });
  const r = repoFalso([reserva(1), reserva(2)]);
  const out = await carregarFonte(fonte(), r.repo, 2, op(sv.fetcher));
  assertEquals(out.bloqueada, true);
  assertEquals(r.marcas.map((m) => [m[0], m[1]]), [[1, null], [2, null]]);
  assertEquals(sv.chamadas.filter((c) => c === "PesquisarProcessoDetalhes").length, 1);
  assertEquals(r.licitacoes.length, 0);
});

Deno.test("carregar: orçamento esgotado devolve o que sobrou", async () => {
  let t = 0;
  const sv = servidor({
    "Mural.aspx": () => new Response("", { status: 302 }),
    PesquisarProcessoDetalhes: (c) => d(detalhe((c.dtoProcesso as Linha).nCdProcesso as number)),
    PesquisarProcessoDetalheItemProduto: () => d([]),
  });
  const r = repoFalso([reserva(1), reserva(2), reserva(3)]);
  const { resumo } = await carregarFonte(fonte(), r.repo, 3, op(sv.fetcher, { orcamentoMs: 5000, agora: () => (t += 1500) }));
  assert(resumo.gravados < 3);
  assertEquals(r.marcas.filter((m) => m[1] === null).length, 3 - resumo.gravados);
  assert(resumo.avisos.some((a) => a.includes("orçamento")));
});

Deno.test("carregar sem fila não chama o portal", async () => {
  const sv = servidor({});
  const r = repoFalso([]);
  const { resumo } = await carregarFonte(fonte(), r.repo, 3, op(sv.fetcher));
  assertEquals(resumo.reservados, 0);
  assertEquals(sv.chamadas.length, 0);
});
