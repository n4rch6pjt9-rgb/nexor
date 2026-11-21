import { assertEquals } from "jsr:@std/assert@1";
import {
  chavesDe,
  chavesDeCatalogo,
  compararChaves,
  compararFontes,
  corpoListagem,
  parametrosListagemValidos,
  type FonteSonda,
  limpar,
  podeSondar,
  sondarFonte,
  urlMetodo,
  urlMural,
} from "../../supabase/functions/_shared/coletor/paradigma-sonda.ts";

const BASE = "https://portal.exemplo.invalid/sescdn/portal";
const fonte = (o: Partial<FonteSonda> = {}): FonteSonda => ({
  slug: "t1",
  base_url: BASE,
  ativo: true,
  robots_permite: null,
  mural_autorizado: false,
  pausada_ate: null,
  delay_ms: 1000,
  ...o,
});
const NULO = "\u0013\u0012\u0012\u0013";
const sem = async () => {};

const d = (x: unknown) => new Response(JSON.stringify({ d: x }), { status: 200 });

/** Servidor falso: responde por método e conta as chamadas. */
function servidor(rotas: Record<string, () => Response>) {
  const chamadas: string[] = [];
  const fetcher = (url: string) => {
    const m = url.endsWith("Mural.aspx") ? "Mural.aspx" : url.split("/").pop()!;
    chamadas.push(m);
    return Promise.resolve((rotas[m] ?? (() => new Response("", { status: 404 })))());
  };
  return { fetcher, chamadas };
}

Deno.test("limpar troca os marcadores de vazio do Paradigma por null, em profundidade", () => {
  assertEquals(limpar({ a: NULO, b: -2147483648, c: [NULO, 1], d: { e: "x" } }), {
    a: null,
    b: null,
    c: [null, 1],
    d: { e: "x" },
  });
});

Deno.test("urls do portal não duplicam barra", () => {
  assertEquals(urlMural(BASE + "/"), BASE + "/Mural.aspx");
  assertEquals(urlMetodo(BASE, "PesquisarProcessos"), BASE + "/WebService/Servicos.asmx/PesquisarProcessos");
});

Deno.test("corpo da listagem pede só uma faixa curta, com o objeto vazio", () => {
  const c = corpoListagem();
  assertEquals(c.dtoProcesso.sDsObjeto, "");
  assertEquals(c.dtoProcesso.dtoPaginacao, { nPaginaDe: 1, nPaginaAte: 20 });
});

Deno.test("podeSondar respeita ativo, pausa, robots e mural_autorizado", () => {
  const agora = new Date("2026-11-21T12:00:00Z");
  assertEquals(podeSondar(fonte({ ativo: false }), agora).ok, false);
  assertEquals(podeSondar(fonte({ pausada_ate: "2026-11-22T00:00:00Z" }), agora).ok, false);
  assertEquals(podeSondar(fonte({ pausada_ate: "2026-11-20T00:00:00Z" }), agora).ok, true);
  assertEquals(podeSondar(fonte({ robots_permite: false }), agora).ok, false);
  assertEquals(podeSondar(fonte({ robots_permite: false, mural_autorizado: true }), agora).ok, true);
  assertEquals(podeSondar(fonte({ robots_permite: null }), agora).ok, true);
});

Deno.test("compararChaves e chavesDeCatalogo", () => {
  assertEquals(compararChaves(["a", "b"], ["b", "c"]), { so_na_referencia: ["a"], so_na_outra: ["c"], iguais: false });
  assertEquals(compararChaves(["a", "b"], ["b", "a"]).iguais, true);
  assertEquals(chavesDeCatalogo(["nCdProduto", "sDsItem", "nCdClasse", "tDtInicial"]), ["nCdProduto", "nCdClasse"]);
  assertEquals(chavesDe([1]), []);
});

Deno.test("sonda feliz: mede listagem, detalhe e itens, e devolve só chaves", async () => {
  const s = servidor({
    "Mural.aspx": () => new Response("<html></html>", { status: 200 }),
    PesquisarProcessos: () =>
      d([
        { nCdOrigem: 11, nCdModulo: 59, sDsObjeto: " Aquisição de esteira ", lstClasses: [] },
        { nCdOrigem: 12, nCdModulo: 18, sDsObjeto: "Outro objeto", lstClasses: [] },
        { nCdOrigem: 13, nCdModulo: 59, sDsObjeto: "Terceiro", lstClasses: [] },
      ]),
    PesquisarProcessoDetalhes: () => d({ nCdProcesso: 11, sNrProcesso: "1/2026", nCdSituacao: 1, sDsObjeto: "x" }),
    PesquisarProcessoDetalheItemProduto: () => d([{ nCdProduto: 9, sDsItem: "ESTEIRA", nCdClasse: 5 }]),
  });
  const reg: Array<[string, number]> = [];
  const rel = await sondarFonte(fonte(), {
    fetcher: s.fetcher,
    dormir: sem,
    registrar: (slug, st) => {
      reg.push([slug, st]);
      return Promise.resolve();
    },
  });
  assertEquals(rel.executada, true);
  assertEquals(rel.bloqueada, false);
  assertEquals(rel.listagem?.linhas, 3);
  assertEquals(rel.listagem?.amostra_objeto[0], "Aquisição de esteira");
  assertEquals(rel.detalhe?.processos, 2); // amostra padrão = 2
  assertEquals(rel.detalhe?.modulos, [18, 59]);
  assertEquals(rel.itens?.chaves_de_catalogo, ["nCdClasse", "nCdProduto"]);
  assertEquals(reg.every(([slug, st]) => slug === "t1" && st === 200), true);
  assertEquals(s.chamadas.length, 1 + 1 + 2 * 2);
  assertEquals(JSON.stringify(rel).includes("1/2026"), false); // nenhum valor de processo vaza
});

Deno.test("403 no mural para na hora: sem nova tentativa e sem chamar o webservice", async () => {
  const s = servidor({ "Mural.aspx": () => new Response("", { status: 403 }) });
  const reg: number[] = [];
  const rel = await sondarFonte(fonte(), {
    fetcher: s.fetcher,
    dormir: sem,
    registrar: (_s, st) => {
      reg.push(st);
      return Promise.resolve();
    },
  });
  assertEquals(rel.bloqueada, true);
  assertEquals(s.chamadas, ["Mural.aspx"]);
  assertEquals(reg, [403]);
  assertEquals(rel.listagem, undefined);
});

Deno.test("403 no webservice também para, sem repetir", async () => {
  const s = servidor({
    "Mural.aspx": () => new Response("ok", { status: 200 }),
    PesquisarProcessos: () => new Response("", { status: 403 }),
  });
  const rel = await sondarFonte(fonte(), { fetcher: s.fetcher, dormir: sem });
  assertEquals(rel.bloqueada, true);
  assertEquals(s.chamadas, ["Mural.aspx", "PesquisarProcessos"]);
});

Deno.test("429 tem exatamente uma nova tentativa, respeitando Retry-After", async () => {
  let n = 0;
  const esperas: number[] = [];
  const s = servidor({
    "Mural.aspx": () => new Response("ok", { status: 200 }),
    PesquisarProcessos: () => {
      n++;
      return n === 1 ? new Response("", { status: 429, headers: { "retry-after": "3" } }) : d([]);
    },
  });
  const rel = await sondarFonte(fonte(), {
    fetcher: s.fetcher,
    dormir: (ms) => Promise.resolve(void esperas.push(ms)),
  });
  assertEquals(n, 2);
  assertEquals(rel.listagem?.linhas, 0);
  assertEquals(esperas.includes(3000), true);
});

Deno.test("429 persistente não gera terceira chamada", async () => {
  let n = 0;
  const s = servidor({
    "Mural.aspx": () => new Response("ok", { status: 200 }),
    PesquisarProcessos: () => {
      n++;
      return new Response("", { status: 429 });
    },
  });
  const rel = await sondarFonte(fonte(), { fetcher: s.fetcher, dormir: sem });
  assertEquals(n, 2);
  assertEquals(rel.listagem, undefined);
});

Deno.test("o intervalo entre chamadas nunca fica abaixo de 1000 ms, mesmo com delay_ms menor", async () => {
  const esperas: number[] = [];
  const s = servidor({
    "Mural.aspx": () => new Response("ok", { status: 200 }),
    PesquisarProcessos: () => d([]),
  });
  await sondarFonte(fonte({ delay_ms: 10 }), {
    fetcher: s.fetcher,
    dormir: (ms) => Promise.resolve(void esperas.push(ms)),
  });
  assertEquals(esperas.length > 0 && esperas.every((e) => e >= 1000), true);
});

Deno.test("fonte que não pode ser sondada não faz nenhuma chamada", async () => {
  const s = servidor({});
  const rel = await sondarFonte(fonte({ robots_permite: false }), { fetcher: s.fetcher, dormir: sem });
  assertEquals(rel.executada, false);
  assertEquals(s.chamadas.length, 0);
});

Deno.test("falha ao registrar o resultado não derruba a sonda", async () => {
  const s = servidor({
    "Mural.aspx": () => new Response("ok", { status: 200 }),
    PesquisarProcessos: () => d([]),
  });
  const rel = await sondarFonte(fonte(), {
    fetcher: s.fetcher,
    dormir: sem,
    registrar: () => Promise.reject(new Error("rpc fora")),
  });
  assertEquals(rel.listagem?.linhas, 0);
  assertEquals(rel.avisos.some((a) => a.includes("registrar")), true);
});

Deno.test("compararFontes mostra o que muda de um portal para outro", async () => {
  const mk = (extra: string[]) =>
    servidor({
      "Mural.aspx": () => new Response("ok", { status: 200 }),
      PesquisarProcessos: () => d([Object.fromEntries(["nCdOrigem", "sDsObjeto", ...extra].map((k) => [k, 1]))]),
    });
  const a = await sondarFonte(fonte({ slug: "a" }), { fetcher: mk([]).fetcher, dormir: sem });
  const b = await sondarFonte(fonte({ slug: "b" }), { fetcher: mk(["chatUrl"]).fetcher, dormir: sem });
  const c = compararFontes([a, b]);
  assertEquals(c.referencia, "a");
  assertEquals((c.diferencas[0] as { listagem: { so_na_outra: string[] } }).listagem.so_na_outra, ["chatUrl"]);
});

Deno.test("corpo da listagem aceita tipo de mural, ordenação e tamanho por fonte", () => {
  const c = corpoListagem("", 1, 50, { tipoMural: 4, ordenarPor: "TDTINICIAL" });
  assertEquals(c.dtoProcesso.tmpTipoMuralProcesso, 4);
  assertEquals(c.dtoProcesso.sOrdenarPor, "TDTINICIAL");
  assertEquals(c.dtoProcesso.dtoPaginacao, { nPaginaDe: 1, nPaginaAte: 50 });
});

Deno.test("parâmetros de listagem rejeitam valores fora da faixa", () => {
  assertEquals(parametrosListagemValidos(undefined), {});
  assertEquals(parametrosListagemValidos({ tipoMural: 4, ordenarPor: "TDTINICIAL", tamanho: 50 }), { tipoMural: 4, ordenarPor: "TDTINICIAL", tamanho: 50 });
  assertEquals(parametrosListagemValidos({ tamanho: 51 }), null);
  assertEquals(parametrosListagemValidos({ ordenarPor: "x; drop" }), null);
  assertEquals(parametrosListagemValidos({ tipoMural: 1.5 }), null);
  assertEquals(parametrosListagemValidos([]), null);
});

Deno.test("a listagem usa o método do perfil da fonte", async () => {
  const s = servidor({
    "Mural.aspx": () => new Response("ok", { status: 200 }),
    PesquisarProcessosPorSituacoesAgrupadas: () => d([{ nCdOrigem: 1 }]),
  });
  const rel = await sondarFonte(fonte(), {
    fetcher: s.fetcher,
    dormir: sem,
    amostra: 1,
    listagem: { metodo: "PesquisarProcessosPorSituacoesAgrupadas", tipoMural: 4 },
  });
  assertEquals(rel.listagem?.linhas, 1);
  assertEquals(s.chamadas[1], "PesquisarProcessosPorSituacoesAgrupadas");
});

Deno.test("método de listagem fora da lista é recusado", () => {
  assertEquals(parametrosListagemValidos({ metodo: "ExcluirProcesso" }), null);
  assertEquals(parametrosListagemValidos({ metodo: "PesquisarProcessos" }), { metodo: "PesquisarProcessos" });
});
