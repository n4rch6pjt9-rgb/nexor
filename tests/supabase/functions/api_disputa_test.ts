import { assertEquals } from "jsr:@std/assert@1";
import { handleRequest } from "../../../supabase/functions/api-disputa/index.ts";
import { sincronizarCompra } from "../../../supabase/functions/_shared/sessao_chat.ts";
import type { AuthenticatedUser } from "../../../supabase/functions/_shared/http.ts";
import {
  ErroIntegraCompras,
  type ResultadoConsultaIntegra,
} from "../../../supabase/functions/_shared/serpro.ts";

const USUARIO_TESTE: AuthenticatedUser = {
  id: "user-uuid-1",
  email: "operador@konnen.com.br",
  app_metadata: {},
};

let papelMock = "operacao";

interface MockDatabase {
  pipeline: Array<{ tenant_id: number; licitacao_id: number }>;
  itens: Array<{
    id: number;
    licitacao_id: number;
    numero_item: number;
    descricao: string;
    valor_unitario_estimado: number | null;
    valor_total_estimado: number | null;
    catalogo_codigo_item?: number | null;
    unidade_medida?: string | null;
  }>;
  dePara: Array<{
    id?: number;
    tenant_id: number;
    licitacao_item_id: number;
    produto_id: number;
    status: string;
  }>;
  precos: Array<{
    tenant_id: number;
    produto_id: number;
    preco_tabela: number;
    desconto_max_pct: number;
    vigencia_inicio: string;
    vigencia_fim: string | null;
  }>;
  precosPraticadosItens?: Array<{
    codigo_item_catalogo: number;
    preco_unitario: number;
    sigla_unidade_fornecimento: string | null;
    data_resultado: string;
  }>;
  mensagens: Array<Record<string, unknown>>;
  auditoria: Array<Record<string, unknown>>;
  runs?: Array<Record<string, unknown>>;
  licitacoesExternas?: Array<{ id: number; codigo_externo?: string; raw?: Record<string, unknown> }>;
  failUpsert?: boolean;
}

function createMockSupabase(db: MockDatabase) {
  db.runs ??= [];
  // deno-lint-ignore no-explicit-any
  const mock: any = {
    schema: (nome: string) => ({ from: (t: string) => mock.from(`${nome}.${t}`) }),
    from: (table: string) => {
      const filters: Array<(row: any) => boolean> = [];
      let sortField: string | null = null;
      let sortAsc = true;
      let isSingle = false;
      let isMaybeSingle = false;

      // deno-lint-ignore no-explicit-any
      const builder: any = {
        select: (_fields?: string) => builder,
        eq: (col: string, val: any) => {
          filters.push((row) => row[col] === val);
          return builder;
        },
        in: (col: string, vals: any[]) => {
          filters.push((row) => vals.includes(row[col]));
          return builder;
        },
        lte: (col: string, val: any) => {
          filters.push((row) => row[col] <= val);
          return builder;
        },
        gte: (col: string, val: any) => {
          filters.push((row) => row[col] >= val);
          return builder;
        },
        gt: (col: string, val: any) => {
          filters.push((row) => row[col] > val);
          return builder;
        },
        or: () => builder,
        ilike: () => builder,
        order: (col: string, opts?: { ascending?: boolean }) => {
          sortField = col;
          sortAsc = opts?.ascending ?? true;
          return builder;
        },
        limit: (_n: number) => builder,
        single: () => {
          isSingle = true;
          return builder;
        },
        maybeSingle: () => {
          isMaybeSingle = true;
          return builder;
        },
        insert: (row: any) => {
          if (table === "private.integra_compras_run") {
            const id = db.runs!.length + 1;
            db.runs!.push({ id, ...row });
            return {
              select: () => ({
                single: () => Promise.resolve({ data: { id }, error: null }),
              }),
            };
          }
          if (table === "disputa_lances_auditoria") {
            const id = db.auditoria.length + 1;
            const saved = { id, ...row };
            db.auditoria.push(saved);
            return {
              select: () => ({
                single: () => Promise.resolve({ data: { id }, error: null }),
              }),
            };
          }
          return Promise.resolve({ data: row, error: null });
        },
        update: (patch: any) => ({
          eq: (col: string, val: any) => {
            if (table === "private.integra_compras_run") {
              for (const r of db.runs!) if (r[col] === val) Object.assign(r, patch);
            }
            return Promise.resolve({ data: null, error: null });
          },
        }),
        upsert: (rows: any, _opts?: any) => {
          const lista = Array.isArray(rows) ? rows : [rows];
          if (db.failUpsert) {
            return { select: () => Promise.resolve({ data: null, error: new Error("Erro de banco ao inserir mensagem") }) };
          }
          const inseridas: any[] = [];
          if (table === "sessao_mensagens") {
            for (const r of lista) {
              if (!db.mensagens.some((m) => m.chave_mensagem === r.chave_mensagem)) {
                db.mensagens.push(r);
                inseridas.push({ chave_mensagem: r.chave_mensagem });
              }
            }
          }
          return { select: () => Promise.resolve({ data: inseridas, error: null }) };
        },
        then: (resolve: (val: any) => void) => {
          let rows: any[] = [];
          if (table === "tenant_membros") {
            rows = [{ tenant_id: 1, user_id: "user-uuid-1", papel: papelMock, ativo: true }];
          } else if (table === "tenants") {
            rows = [{ id: 1, ativo: true }];
          } else if (table === "pipeline_oportunidades") {
            rows = [...db.pipeline];
          } else if (table === "licitacao_itens") {
            rows = [...db.itens];
          } else if (table === "catalogo_de_para") {
            rows = [...db.dePara];
          } else if (table === "catalogo_precos") {
            rows = [...db.precos];
          } else if (table === "sessao_mensagens") {
            rows = [...db.mensagens];
          } else if (table === "private.integra_compras_run") {
            rows = [...db.runs!];
          } else if (table === "disputa_lances_auditoria") {
            rows = [...db.auditoria];
          } else if (table === "licitacoes_externas") {
            rows = db.licitacoesExternas ?? [
              { id: 100, codigo_externo: "15300005000012026", raw: {} },
              { id: 101, codigo_externo: "15300005000012026", raw: {} },
            ];
          } else if (table === "precos_praticados_itens") {
            rows = db.precosPraticadosItens ?? [];
          }

          const res = rows.filter((r) => filters.every((f) => f(r)));
          if (sortField) {
            res.sort((a, b) => {
              if (a[sortField!] < b[sortField!]) return sortAsc ? -1 : 1;
              if (a[sortField!] > b[sortField!]) return sortAsc ? 1 : -1;
              return 0;
            });
          }

          if (isSingle) {
            resolve({ data: res[0] ?? null, error: res[0] ? null : new Error("Row not found") });
          } else if (isMaybeSingle) {
            resolve({ data: res[0] ?? null, error: null });
          } else {
            resolve({ data: res, error: null });
          }
        },
      };
      return builder;
    },
  };
  return mock;
}

Deno.test("api-disputa: 401 para requisição sem autenticação", async () => {
  const req = new Request("http://localhost/api-disputa/estrategia?licitacao_id=101", {
    method: "GET",
  });
  const res = await handleRequest(req, {
    getUser: () => Promise.resolve(null),
  });
  assertEquals(res.status, 401);
});

Deno.test("api-disputa: GET /estrategia - 404 se licitação não está no pipeline do tenant", async () => {
  const db: MockDatabase = {
    pipeline: [], // Vazio! Licitação não está no pipeline
    itens: [],
    dePara: [],
    precos: [],
    mensagens: [],
    auditoria: [],
  };

  const req = new Request("http://localhost/api-disputa/estrategia?licitacao_id=999", {
    method: "GET",
  });
  const res = await handleRequest(req, {
    getUser: () => Promise.resolve(USUARIO_TESTE),
    // deno-lint-ignore no-explicit-any
    getSupabase: () => createMockSupabase(db) as any,
  });

  assertEquals(res.status, 404);
  const json = await res.json();
  assertEquals(json.erro, "Oportunidade não encontrada no pipeline do tenant.");
});

Deno.test("api-disputa: GET /estrategia - cálculo determinístico com catálogo e zero alucinação", async () => {
  const db: MockDatabase = {
    pipeline: [{ tenant_id: 1, licitacao_id: 101 }],
    itens: [
      {
        id: 1,
        licitacao_id: 101,
        numero_item: 1,
        descricao: "Esteira Ergométrica Profissional",
        valor_unitario_estimado: 25000.0,
        valor_total_estimado: 25000.0,
      },
      {
        id: 2,
        licitacao_id: 101,
        numero_item: 2,
        descricao: "Bicicleta Ergométrica Eletromagnética",
        valor_unitario_estimado: 15000.0,
        valor_total_estimado: 15000.0,
      },
    ],
    dePara: [
      {
        id: 1,
        tenant_id: 1,
        licitacao_item_id: 1,
        produto_id: 50,
        status: "confirmado",
      },
      // Item 2 NÃO tem mapeamento no de-para
    ],
    precos: [
      {
        tenant_id: 1,
        produto_id: 50,
        preco_tabela: 20000.0, // R$ 20.000,00
        desconto_max_pct: 15.0, // 15% desc -> Piso = R$ 17.000,00 (1.700.000 centavos)
        vigencia_inicio: "2026-01-01",
        vigencia_fim: null,
      },
    ],
    mensagens: [],
    auditoria: [],
  };

  const req = new Request("http://localhost/api-disputa/estrategia?licitacao_id=101", {
    method: "GET",
  });
  const res = await handleRequest(req, {
    getUser: () => Promise.resolve(USUARIO_TESTE),
    // deno-lint-ignore no-explicit-any
    getSupabase: () => createMockSupabase(db) as any,
  });

  assertEquals(res.status, 200);
  const json = await res.json();

  assertEquals(json.licitacao_id, 101);
  assertEquals(json.tenant_id, 1);

  // Item 1: Configurado e mapeado -> R$ 17.000,00 (1700000 centavos)
  assertEquals(json.itens[0].item_numero, 1);
  assertEquals(json.itens[0].piso_centavos, 1700000);
  // Intervalo mínimo do edital ainda não é lido (K-8): nenhum item é habilitado e nada é presumido.
  assertEquals(json.itens[0].habilitado, false);
  assertEquals(json.itens[0].intervalo_minimo_reais, null);

  // Item 2: Sem mapeamento -> NUNCA presumir 70% nem fabricar dado!
  assertEquals(json.itens[1].item_numero, 2);
  assertEquals(json.itens[1].piso_centavos, null);
  assertEquals(json.itens[1].habilitado, false);

  // Top level: reflete item 1
  assertEquals(json.piso_centavos, 1700000);
  assertEquals(json.habilitado, false);
  assertEquals(json.intervalo_minimo_reais, null);
  assertEquals(json.modo_disputa, null);
  assertEquals(Object.keys(json.itens[0]).some((k) => k.startsWith("_")), false);
});

Deno.test("api-disputa: POST /auditoria - grava log de lance supervisionado", async () => {
  papelMock = "admin";
  try {
  const db: MockDatabase = {
    pipeline: [{ tenant_id: 1, licitacao_id: 101 }],
    itens: [{ id: 1, licitacao_id: 101, numero_item: 1, descricao: "Esteira", valor_unitario_estimado: null, valor_total_estimado: null }],
    dePara: [],
    precos: [],
    mensagens: [],
    auditoria: [],
  };

  const req = new Request("http://localhost/api-disputa/auditoria", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      licitacaoId: 101,
      item_numero: 1,
      valor: 18500.0,
      piso: 17000.0,
      melhorOferta: 18550.0,
      modo_disputa: "aberto",
      tipo: "LANCE_AUTOMATICO",
    }),
  });

  const res = await handleRequest(req, {
    getUser: () => Promise.resolve(USUARIO_TESTE),
    // deno-lint-ignore no-explicit-any
    getSupabase: () => createMockSupabase(db) as any,
  });

  assertEquals(res.status, 200);
  const json = await res.json();
  assertEquals(json.ok, true);
  assertEquals(json.id, 1);
  assertEquals(db.auditoria.length, 1);
  assertEquals(db.auditoria[0].valor_lance_centavos, 1850000);
  assertEquals((db.auditoria[0].detalhes as Record<string, unknown>).regra_version, "bot-guards.v1");
  assertEquals((db.auditoria[0].detalhes as Record<string, unknown>).recomendacao_id, null);
  } finally {
    papelMock = "operacao";
  }
});

Deno.test("api-disputa: POST /sync-chat - 404 se licitação não está no pipeline", async () => {
  const db: MockDatabase = {
    pipeline: [],
    itens: [],
    dePara: [],
    precos: [],
    mensagens: [],
    auditoria: [],
  };

  const req = new Request("http://localhost/api-disputa/sync-chat", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      licitacao_id: 999,
      chave_compra: "15300005000012026",
    }),
  });

  const res = await handleRequest(req, {
    getUser: () => Promise.resolve(USUARIO_TESTE),
    // deno-lint-ignore no-explicit-any
    getSupabase: () => createMockSupabase(db) as any,
  });

  assertEquals(res.status, 404);
  const json = await res.json();
  assertEquals(json.erro, "Oportunidade não encontrada no pipeline do tenant.");
});

const EXEMPLO_OFICIAL: unknown[] = JSON.parse(
  await Deno.readTextFile(new URL("../fixtures/integra_compras_chat_exemplo.json", import.meta.url)),
);
const CHAVE_DEMO = "99998803000012026";

/** Resultado da consulta como o cliente devolve, a partir do exemplo oficial (sem rede). */
function resultadoExemplo(tipo: "mensagem" | "diligencia"): ResultadoConsultaIntegra {
  return {
    status: 200,
    // deno-lint-ignore no-explicit-any
    mensagens: EXEMPLO_OFICIAL.map((m: any) => ({
      tipo,
      chaveMensagem: tipo === "mensagem" ? m.chaveMensagem : m.chaveMensagem.replace(/^.{8}/, "dddddddd"),
      identificadorItem: m.identificadorItem ?? null,
      texto: m.texto,
      categoria: m.categoria,
      tipoRemetente: m.tipoRemetente,
      dataHora: new Date(m.dataHora.replace(" ", "T") + "-03:00").toISOString(),
      dataHoraFonte: m.dataHora,
      chaveCompra: m.chaveCompra,
    })),
  };
}
const vazio404 = (): Promise<ResultadoConsultaIntegra> => Promise.resolve({ status: 404, mensagens: [] });

function dbDemo(extra: Partial<MockDatabase> = {}): MockDatabase {
  return {
    pipeline: [{ tenant_id: 1, licitacao_id: 101 }],
    itens: [],
    dePara: [],
    precos: [],
    mensagens: [],
    auditoria: [],
    licitacoesExternas: [{ id: 101, codigo_externo: CHAVE_DEMO, raw: {} }],
    ...extra,
  };
}

function reqSync(body: Record<string, unknown> = { licitacao_id: 101 }) {
  return new Request("http://localhost/api-disputa/sync-chat", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
}

Deno.test("CA-2: exemplo oficial processado duas vezes dá 3 linhas, item nulo na primeira e \"1\" nas outras", async () => {
  const db = dbDemo();
  const ctx = {
    getUser: () => Promise.resolve(USUARIO_TESTE),
    // deno-lint-ignore no-explicit-any
    getSupabase: () => createMockSupabase(db) as any,
    consultarChat: () => Promise.resolve(resultadoExemplo("mensagem")),
    consultarDiligencias: vazio404,
  };

  const r1 = await handleRequest(reqSync(), ctx);
  assertEquals(r1.status, 200);
  assertEquals((await r1.json()).novas_inseridas, 3);

  const r2 = await handleRequest(reqSync(), ctx);
  const j2 = await r2.json();
  assertEquals(j2.total_lidas, 3);
  assertEquals(j2.novas_inseridas, 0);

  assertEquals(db.mensagens.length, 3);
  assertEquals(db.mensagens.map((m) => m.identificador_item), [null, "1", "1"]);
  assertEquals(db.mensagens.every((m) => m.chave_compra === CHAVE_DEMO && !("tenant_id" in m)), true);
  assertEquals(db.mensagens[0].categoria, "11");
  assertEquals(db.mensagens[0].data_hora_fonte, "2026-02-05 16:15:00.144");
  // K-2: uma execução por consulta, com as chamadas por código HTTP
  assertEquals(db.runs!.length, 2);
  assertEquals(db.runs![0].chamadas, { "200": 1, "404": 1 });
  assertEquals(db.runs![0].mensagens_novas, 3);
  assertEquals(db.runs![1].mensagens_novas, 0);
});

Deno.test("CA-3: 404 grava zero mensagens e o registro conta os 404 (cobrados), sem erro", async () => {
  const db = dbDemo();
  const res = await handleRequest(reqSync(), {
    getUser: () => Promise.resolve(USUARIO_TESTE),
    // deno-lint-ignore no-explicit-any
    getSupabase: () => createMockSupabase(db) as any,
    consultarChat: vazio404,
    consultarDiligencias: vazio404,
  });
  assertEquals(res.status, 200);
  const json = await res.json();
  assertEquals(json.ok, true);
  assertEquals(json.total_lidas, 0);
  assertEquals(db.mensagens.length, 0);
  assertEquals(db.runs![0].chamadas, { "404": 2 });
  assertEquals(db.runs![0].erro, null);
  // K-7: a execução guarda a licitação de onde veio a chave (base da retenção).
  assertEquals(db.runs![0].licitacao_id, 101);
  assertEquals(db.runs![0].origem, "usuario");
});

Deno.test("CA-5: 502 registra erro, não apaga nem inventa mensagem e responde 502", async () => {
  const existente = { chave_compra: CHAVE_DEMO, chave_mensagem: "ja-gravada", texto: "anterior" };
  const db = dbDemo({ mensagens: [existente] });
  const res = await handleRequest(reqSync(), {
    getUser: () => Promise.resolve(USUARIO_TESTE),
    // deno-lint-ignore no-explicit-any
    getSupabase: () => createMockSupabase(db) as any,
    consultarChat: () => Promise.reject(new ErroIntegraCompras("Integra Compras respondeu HTTP 502", 502)),
    consultarDiligencias: () => Promise.resolve(resultadoExemplo("diligencia")),
  });
  assertEquals(res.status, 502);
  const json = await res.json();
  assertEquals(json.ok, false);
  assertEquals(db.mensagens, [existente]);
  assertEquals(db.runs![0].chamadas, { "502": 1 });
  assertEquals(typeof db.runs![0].erro, "string");
  assertEquals(typeof db.runs![0].terminado_em, "string");
});

Deno.test("api-disputa: POST /sync-chat - falha sem status (timeout) fecha o registro com erro", async () => {
  const db = dbDemo();
  const res = await handleRequest(reqSync(), {
    getUser: () => Promise.resolve(USUARIO_TESTE),
    // deno-lint-ignore no-explicit-any
    getSupabase: () => createMockSupabase(db) as any,
    consultarChat: () => Promise.reject(new ErroIntegraCompras("Falha ao consultar o Integra Compras (TimeoutError).", null)),
    consultarDiligencias: vazio404,
  });
  assertEquals(res.status, 502);
  assertEquals(db.runs![0].chamadas, { "sem_resposta": 1 });
  assertEquals(typeof db.runs![0].erro, "string");
  assertEquals(typeof db.runs![0].terminado_em, "string");
});

Deno.test("api-disputa: POST /sync-chat - consulta manual repetida em menos de 5 min recebe 429 e não chama a API", async () => {
  const db = dbDemo({ runs: [{ id: 1, chave_compra: CHAVE_DEMO, origem: "usuario", iniciado_em: new Date().toISOString() }] });
  let chamou = false;
  const res = await handleRequest(reqSync(), {
    getUser: () => Promise.resolve(USUARIO_TESTE),
    // deno-lint-ignore no-explicit-any
    getSupabase: () => createMockSupabase(db) as any,
    consultarChat: () => {
      chamou = true;
      return vazio404();
    },
    consultarDiligencias: vazio404,
  });
  assertEquals(res.status, 429);
  assertEquals(chamou, false);
  assertEquals(db.runs!.length, 1);
});

Deno.test("api-disputa: POST /sync-chat - corpo que não é JSON recebe 400", async () => {
  const res = await handleRequest(
    new Request("http://localhost/api-disputa/sync-chat", { method: "POST", body: "{" }),
    {
      getUser: () => Promise.resolve(USUARIO_TESTE),
      // deno-lint-ignore no-explicit-any
      getSupabase: () => createMockSupabase(dbDemo()) as any,
    },
  );
  assertEquals(res.status, 400);
});

Deno.test("api-disputa: POST /sync-chat - não mascara erro se upsert falhar e retorna 500 higienizado", async () => {
  const db = dbDemo({ failUpsert: true });
  const res = await handleRequest(reqSync(), {
    getUser: () => Promise.resolve(USUARIO_TESTE),
    // deno-lint-ignore no-explicit-any
    getSupabase: () => createMockSupabase(db) as any,
    consultarChat: () => Promise.resolve(resultadoExemplo("mensagem")),
    consultarDiligencias: vazio404,
  });
  assertEquals(res.status, 500);
  assertEquals((await res.json()).erro, "Erro interno no servidor.");
  assertEquals(db.runs![0].erro, "falha ao gravar mensagens");
});

Deno.test("api-disputa: GET /chat - mensagens globais da compra, em ordem, com a última consulta", async () => {
  const db = dbDemo();
  const ctx = {
    getUser: () => Promise.resolve(USUARIO_TESTE),
    // deno-lint-ignore no-explicit-any
    getSupabase: () => createMockSupabase(db) as any,
    consultarChat: () => Promise.resolve(resultadoExemplo("mensagem")),
    consultarDiligencias: vazio404,
  };
  await handleRequest(reqSync(), ctx);
  const res = await handleRequest(new Request("http://localhost/api-disputa/chat?licitacao_id=101"), ctx);
  assertEquals(res.status, 200);
  const json = await res.json();
  assertEquals(json.chave_compra, CHAVE_DEMO);
  assertEquals(json.mensagens.length, 3);
  assertEquals(json.ultima_consulta.com_erro, false);
});

Deno.test("api-disputa: GET /chat - sem chave oficial devolve motivo explícito, não lista vazia muda", async () => {
  const db = dbDemo({ licitacoesExternas: [{ id: 101, codigo_externo: "00394460000141-1-000001/2026", raw: {} }] });
  const res = await handleRequest(new Request("http://localhost/api-disputa/chat?licitacao_id=101"), {
    getUser: () => Promise.resolve(USUARIO_TESTE),
    // deno-lint-ignore no-explicit-any
    getSupabase: () => createMockSupabase(db) as any,
  });
  assertEquals(res.status, 200);
  const json = await res.json();
  assertEquals(json.chave_compra, null);
  assertEquals(json.motivo, "sem_chave_compra");
});

Deno.test("api-disputa: POST /sync-chat - rejeita proxy se chave_compra divergir da oficial", async () => {
  const db: MockDatabase = {
    pipeline: [{ tenant_id: 1, licitacao_id: 101 }],
    itens: [],
    dePara: [],
    precos: [],
    mensagens: [],
    auditoria: [],
    licitacoesExternas: [
      { id: 101, codigo_externo: "15300005000012026", raw: {} },
    ],
  };

  const req = new Request("http://localhost/api-disputa/sync-chat", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      licitacao_id: 101,
      chave_compra: "CHAVE_INVASORA_ARBITRARIA",
    }),
  });

  const res = await handleRequest(req, {
    getUser: () => Promise.resolve(USUARIO_TESTE),
    // deno-lint-ignore no-explicit-any
    getSupabase: () => createMockSupabase(db) as any,
  });

  assertEquals(res.status, 400);
  const json = await res.json();
  assertEquals(json.erro, "Chave de compra não corresponde ao registro oficial da licitação.");
});

Deno.test("api-disputa: POST /sync-chat - rejeita sync se licitação não possui chave oficial de 17 dígitos", async () => {
  const db: MockDatabase = {
    pipeline: [{ tenant_id: 1, licitacao_id: 101 }],
    itens: [],
    dePara: [],
    precos: [],
    mensagens: [],
    auditoria: [],
    licitacoesExternas: [
      // Licitação apenas com identificador PNCP, sem chave de 17 dígitos do Compras.gov
      { id: 101, codigo_externo: "00394460000141-1-000001/2026", raw: {} },
    ],
  };

  const req = new Request("http://localhost/api-disputa/sync-chat", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      licitacao_id: 101,
      chave_compra: "15300005000012026",
    }),
  });

  const res = await handleRequest(req, {
    getUser: () => Promise.resolve(USUARIO_TESTE),
    // deno-lint-ignore no-explicit-any
    getSupabase: () => createMockSupabase(db) as any,
  });

  assertEquals(res.status, 400);
  const json = await res.json();
  assertEquals(json.erro, "Esta licitação não possui chave oficial de compra do Compras.gov (17 dígitos) para consulta no Integra Compras.");
});

Deno.test("api-disputa: POST /sync-chat - cron grava uma cópia global, mesmo com a compra em dois tenants", async () => {
  const db = dbDemo({ pipeline: [{ tenant_id: 1, licitacao_id: 101 }, { tenant_id: 2, licitacao_id: 101 }] });
  const res = await handleRequest(reqSync(), {
    isCron: () => true,
    // deno-lint-ignore no-explicit-any
    getSupabase: () => createMockSupabase(db) as any,
    consultarChat: () => Promise.resolve(resultadoExemplo("mensagem")),
    consultarDiligencias: vazio404,
  });
  assertEquals(res.status, 200);
  assertEquals((await res.json()).novas_inseridas, 3);
  assertEquals(db.mensagens.length, 3);
  assertEquals(db.runs![0].origem, "cron");
});

Deno.test("api-disputa: POST /sync-chat - cron com tenant_id valida presença no pipeline", async () => {
  const db = dbDemo();
  const ctx = {
    isCron: () => true,
    // deno-lint-ignore no-explicit-any
    getSupabase: () => createMockSupabase(db) as any,
    consultarChat: () => Promise.resolve(resultadoExemplo("mensagem")),
    consultarDiligencias: vazio404,
  };
  const ok = await handleRequest(reqSync({ licitacao_id: 101, tenant_id: 1 }), ctx);
  assertEquals(ok.status, 200);

  const invalido = await handleRequest(reqSync({ licitacao_id: 101, tenant_id: 99 }), ctx);
  assertEquals(invalido.status, 404);
  assertEquals((await invalido.json()).erro, "Licitação não vinculada ao tenant informado no pipeline.");
});

Deno.test("api-disputa: GET /estrategia - seleção determinística do menor id de catalogo_de_para compatível com api-agentes", async () => {
  const db: MockDatabase = {
    pipeline: [{ tenant_id: 1, licitacao_id: 101 }],
    itens: [
      {
        id: 1,
        licitacao_id: 101,
        numero_item: 1,
        descricao: "Esteira Ergométrica",
        valor_unitario_estimado: 25000.0,
        valor_total_estimado: 25000.0,
      },
    ],
    // Dois registros confirmados para o mesmo item: id 10 (produto 50) e id 20 (produto 60)
    dePara: [
      {
        id: 20,
        tenant_id: 1,
        licitacao_item_id: 1,
        produto_id: 60,
        status: "confirmado",
      },
      {
        id: 10,
        tenant_id: 1,
        licitacao_item_id: 1,
        produto_id: 50,
        status: "confirmado",
      },
    ],
    precos: [
      {
        tenant_id: 1,
        produto_id: 50,
        preco_tabela: 20000.0,
        desconto_max_pct: 10.0, // Piso = 18.000,00 (1.800.000 centavos)
        vigencia_inicio: "2026-01-01",
        vigencia_fim: null,
      },
      {
        tenant_id: 1,
        produto_id: 60,
        preco_tabela: 15000.0,
        desconto_max_pct: 20.0, // Piso = 12.000,00 (1.200.000 centavos)
        vigencia_inicio: "2026-01-01",
        vigencia_fim: null,
      },
    ],
    mensagens: [],
    auditoria: [],
  };

  const req = new Request("http://localhost/api-disputa/estrategia?licitacao_id=101", {
    method: "GET",
  });
  const res = await handleRequest(req, {
    getUser: () => Promise.resolve(USUARIO_TESTE),
    // deno-lint-ignore no-explicit-any
    getSupabase: () => createMockSupabase(db) as any,
  });

  assertEquals(res.status, 200);
  const json = await res.json();
  // Deve selecionar deterministicamente o produto 50 (menor id de de-para: 10), nunca o produto 60 (id 20)
  const item1 = json.itens.find((i: { item_numero: number }) => i.item_numero === 1);
  assertEquals(item1.piso_centavos, 1800000);
});

Deno.test("api-disputa: GET /estrategia - recomendação usa piso com desconto_max_pct, normaliza Unidade e não inventa UN quando ausente", async () => {
  const hoje = new Date().toISOString().slice(0, 10);
  const db: MockDatabase = {
    pipeline: [{ tenant_id: 1, licitacao_id: 101 }],
    itens: [
      {
        id: 1,
        licitacao_id: 101,
        numero_item: 1,
        descricao: "Esteira Ergométrica",
        valor_unitario_estimado: 20000.0,
        valor_total_estimado: 20000.0,
        catalogo_codigo_item: 485224,
        unidade_medida: "Unidade",
      },
      {
        id: 2,
        licitacao_id: 101,
        numero_item: 2,
        descricao: "Bicicleta sem unidade informada",
        valor_unitario_estimado: 15000.0,
        valor_total_estimado: 15000.0,
        catalogo_codigo_item: 485225,
        unidade_medida: null,
      },
    ],
    dePara: [
      { id: 1, tenant_id: 1, licitacao_item_id: 1, produto_id: 50, status: "confirmado" },
      { id: 2, tenant_id: 1, licitacao_item_id: 2, produto_id: 50, status: "confirmado" },
    ],
    precos: [
      {
        tenant_id: 1,
        produto_id: 50,
        preco_tabela: 20000.0,
        desconto_max_pct: 20.0, // Piso = 16.000,00 (não deve virar 24.000,00!)
        vigencia_inicio: "2026-01-01",
        vigencia_fim: null,
      },
    ],
    precosPraticadosItens: [
      { codigo_item_catalogo: 485224, preco_unitario: 17000, sigla_unidade_fornecimento: "UN", data_resultado: hoje },
      { codigo_item_catalogo: 485224, preco_unitario: 17500, sigla_unidade_fornecimento: "UN", data_resultado: hoje },
      { codigo_item_catalogo: 485224, preco_unitario: 18000, sigla_unidade_fornecimento: "Unidade", data_resultado: hoje },
      { codigo_item_catalogo: 485224, preco_unitario: 18500, sigla_unidade_fornecimento: "UN", data_resultado: hoje },
      { codigo_item_catalogo: 485224, preco_unitario: 19000, sigla_unidade_fornecimento: "UN", data_resultado: hoje },
      // Item 2 tem amostras "UN", mas o item 2 está com unidade_medida: null -> não pode casar com "UN" inventado
      { codigo_item_catalogo: 485225, preco_unitario: 17000, sigla_unidade_fornecimento: "UN", data_resultado: hoje },
      { codigo_item_catalogo: 485225, preco_unitario: 17500, sigla_unidade_fornecimento: "UN", data_resultado: hoje },
      { codigo_item_catalogo: 485225, preco_unitario: 18000, sigla_unidade_fornecimento: "UN", data_resultado: hoje },
      { codigo_item_catalogo: 485225, preco_unitario: 18500, sigla_unidade_fornecimento: "UN", data_resultado: hoje },
      { codigo_item_catalogo: 485225, preco_unitario: 19000, sigla_unidade_fornecimento: "UN", data_resultado: hoje },
    ],
    mensagens: [],
    auditoria: [],
  };

  const req = new Request("http://localhost/api-disputa/estrategia?licitacao_id=101", {
    method: "GET",
  });
  const res = await handleRequest(req, {
    getUser: () => Promise.resolve(USUARIO_TESTE),
    // deno-lint-ignore no-explicit-any
    getSupabase: () => createMockSupabase(db) as any,
  });

  assertEquals(res.status, 200);
  const json = await res.json();
  const item1 = json.itens.find((i: { item_numero: number }) => i.item_numero === 1);
  // Piso de catálogo com 20% desconto = R$ 16.000,00 <= p75 (R$ 18.500,00) -> disputar!
  assertEquals(item1.recomendacao.status, "SUCCESS_WITH_DATA");
  assertEquals(item1.recomendacao.decisao, "disputar");
  assertEquals(item1.recomendacao.parametros.piso_inexequibilidade, 16000);
  assertEquals(item1.recomendacao.parametros.alvo, 18000);
  assertEquals(item1.recomendacao.parametros.teto_absoluto, 18500);

  const item2 = json.itens.find((i: { item_numero: number }) => i.item_numero === 2);
  assertEquals(item2.recomendacao.status, "EMPTY_VALID");
  assertEquals(item2.recomendacao.motivos, ["input_invalido"]);
});

function pedidoAuditoria(corpo: unknown, bruto?: string): Request {
  return new Request("http://localhost/api-disputa/auditoria", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: bruto ?? JSON.stringify(corpo),
  });
}

const AUDITORIA_VALIDA = {
  licitacaoId: 101,
  item_numero: 1,
  valor: 18500.0,
  piso: 17000.0,
  modo_disputa: "aberto",
  tipo: "LANCE_AUTOMATICO",
};

async function chamarAuditoria(papel: string, req: Request, pipeline = [{ tenant_id: 1, licitacao_id: 101 }]) {
  const db: MockDatabase = { pipeline, itens: [{ id: 1, licitacao_id: 101, numero_item: 1, descricao: "Esteira", valor_unitario_estimado: null, valor_total_estimado: null }], dePara: [], precos: [], mensagens: [], auditoria: [] };
  papelMock = papel;
  try {
    const res = await handleRequest(req, {
      getUser: () => Promise.resolve(USUARIO_TESTE),
      // deno-lint-ignore no-explicit-any
      getSupabase: () => createMockSupabase(db) as any,
    });
    return { res, db };
  } finally {
    papelMock = "operacao";
  }
}

Deno.test("api-disputa: POST /auditoria - 403 para papel operacao (K-10: só admin do tenant)", async () => {
  const { res, db } = await chamarAuditoria("operacao", pedidoAuditoria(AUDITORIA_VALIDA));
  assertEquals(res.status, 403);
  assertEquals(db.auditoria.length, 0);
});

Deno.test("api-disputa: POST /auditoria - 400 para JSON inválido, sem valor, sem piso, sem modo e tipo desconhecido", async () => {
  const casos: Array<[string, Request]> = [
    ["json", pedidoAuditoria(null, "{nao-json")],
    ["sem valor", pedidoAuditoria({ ...AUDITORIA_VALIDA, valor: undefined })],
    ["valor zero", pedidoAuditoria({ ...AUDITORIA_VALIDA, valor: 0 })],
    ["valor texto", pedidoAuditoria({ ...AUDITORIA_VALIDA, valor: "18500" })],
    ["sem piso", pedidoAuditoria({ ...AUDITORIA_VALIDA, piso: undefined })],
    ["sem modo", pedidoAuditoria({ ...AUDITORIA_VALIDA, modo_disputa: undefined })],
    ["modo fora da lista", pedidoAuditoria({ ...AUDITORIA_VALIDA, modo_disputa: "fechado" })],
    ["tipo desconhecido", pedidoAuditoria({ ...AUDITORIA_VALIDA, tipo: "QUALQUER" })],
    ["licitacao NaN", pedidoAuditoria({ ...AUDITORIA_VALIDA, licitacaoId: "abc" })],
  ];
  for (const [nome, req] of casos) {
    const { res, db } = await chamarAuditoria("admin", req);
    assertEquals(res.status, 400, nome);
    assertEquals(db.auditoria.length, 0, nome);
  }
});

Deno.test("api-disputa: POST /auditoria - 404 se a licitação não está no pipeline do tenant", async () => {
  const { res, db } = await chamarAuditoria("admin", pedidoAuditoria(AUDITORIA_VALIDA), []);
  assertEquals(res.status, 404);
  assertEquals(db.auditoria.length, 0);
});

Deno.test("api-disputa: POST /auditoria - admin grava; detalhes só com a lista permitida e resultado vem do tipo", async () => {
  const { res, db } = await chamarAuditoria(
    "admin",
    pedidoAuditoria({ ...AUDITORIA_VALIDA, tipo: "BLOQUEIO_PISO", cpf_operador: "123", extra: "x".repeat(1000) }),
  );
  assertEquals(res.status, 200);
  assertEquals(db.auditoria.length, 1);
  assertEquals(db.auditoria[0].resultado, "bloqueado_piso");
  assertEquals(db.auditoria[0].melhor_lance_adversario_centavos, null);
  assertEquals(Object.keys(db.auditoria[0].detalhes as Record<string, unknown>).sort(), ["recomendacao_id", "regra_version"]);
});

Deno.test("Corrida: run mais antigo na janela de 5 min faz o novo desistir sem chamar a fonte (nada cobrado)", async () => {
  const agora = Date.parse("2026-11-19T15:00:00Z");
  const db: MockDatabase = {
    pipeline: [],
    itens: [],
    dePara: [],
    precos: [],
    mensagens: [],
    auditoria: [],
    // run 1 começou 2 s antes; o novo ganha o id 2
    runs: [{ id: 1, chave_compra: "99998803000012026", iniciado_em: new Date(agora - 2000).toISOString() }],
  };
  let chamouFonte = 0;
  const fonte = () => {
    chamouFonte++;
    return Promise.resolve({ status: 200, mensagens: [], statusPaginas: [200] });
  };
  const r = await sincronizarCompra(
    // deno-lint-ignore no-explicit-any
    createMockSupabase(db) as any,
    { chaveCompra: "99998803000012026", licitacaoId: 101, origem: "usuario" },
    { consultarChat: fonte, consultarDiligencias: fonte, agora: () => agora },
  );
  assertEquals(r.pulada, true);
  assertEquals(r.total_lidas, 0);
  assertEquals(r.chamadas, {});
  assertEquals(chamouFonte, 0);
  // run pulado não é falha: erro nulo (a tela mostra "última consulta" sem erro), fechado e sem chamadas
  assertEquals(db.runs![1].erro ?? null, null);
  assertEquals(db.runs![1].chamadas, {});
  assertEquals(typeof db.runs![1].terminado_em, "string");
  assertEquals(r.erro?.startsWith("pulada:"), true);
});

Deno.test("Corrida: o run de menor id segue e consulta a fonte", async () => {
  const agora = Date.parse("2026-11-19T15:00:00Z");
  const db: MockDatabase = {
    pipeline: [],
    itens: [],
    dePara: [],
    precos: [],
    mensagens: [],
    auditoria: [],
    // o outro run (id 9) é posterior: quem entrou primeiro (id 2) não desiste
    runs: [{ id: 9, chave_compra: "99998803000012026", iniciado_em: new Date(agora - 1000).toISOString() }],
  };
  let chamouFonte = 0;
  const fonte = () => {
    chamouFonte++;
    return Promise.resolve({ status: 200, mensagens: [], statusPaginas: [200] });
  };
  const r = await sincronizarCompra(
    // deno-lint-ignore no-explicit-any
    createMockSupabase(db) as any,
    { chaveCompra: "99998803000012026", licitacaoId: 101, origem: "usuario" },
    { consultarChat: fonte, consultarDiligencias: fonte, agora: () => agora },
  );
  assertEquals(r.pulada, undefined);
  assertEquals(chamouFonte, 2);
});

Deno.test("Corrida: run antigo (fora da janela de 5 min) não bloqueia", async () => {
  const agora = Date.parse("2026-11-19T15:00:00Z");
  const db: MockDatabase = {
    pipeline: [],
    itens: [],
    dePara: [],
    precos: [],
    mensagens: [],
    auditoria: [],
    runs: [{ id: 1, chave_compra: "99998803000012026", iniciado_em: new Date(agora - 6 * 60_000).toISOString() }],
  };
  let chamouFonte = 0;
  const fonte = () => {
    chamouFonte++;
    return Promise.resolve({ status: 200, mensagens: [], statusPaginas: [200] });
  };
  const r = await sincronizarCompra(
    // deno-lint-ignore no-explicit-any
    createMockSupabase(db) as any,
    { chaveCompra: "99998803000012026", licitacaoId: 101, origem: "cron" },
    { consultarChat: fonte, consultarDiligencias: fonte, agora: () => agora },
  );
  assertEquals(r.pulada, undefined);
  assertEquals(chamouFonte, 2);
});

Deno.test("Aviso: mensagem com data/hora no futuro vira aviso no run (fuso suspeito), sem corrigir a data", async () => {
  const agora = Date.parse("2026-11-19T15:00:00Z");
  const db: MockDatabase = { pipeline: [], itens: [], dePara: [], precos: [], mensagens: [], auditoria: [], runs: [] };
  const futura = {
    tipo: "mensagem" as const,
    chaveMensagem: "cccccccc-0000-4000-8000-000000000001",
    identificadorItem: null,
    texto: "Bom dia.",
    categoria: null,
    tipoRemetente: "1",
    dataHora: new Date(agora + 3 * 3600_000).toISOString(), // 3 h à frente: fuso errado
    dataHoraFonte: "x",
    chaveCompra: null,
  };
  const r = await sincronizarCompra(
    // deno-lint-ignore no-explicit-any
    createMockSupabase(db) as any,
    { chaveCompra: "99998803000012026", licitacaoId: 101, origem: "cron" },
    {
      consultarChat: () => Promise.resolve({ status: 200, mensagens: [futura], statusPaginas: [200] }),
      consultarDiligencias: () => Promise.resolve({ status: 404, mensagens: [], statusPaginas: [404] }),
      agora: () => agora,
    },
  );
  assertEquals(r.erro?.includes("futuro"), true);
  assertEquals(String(db.runs![0].erro).includes("fuso"), true);
  assertEquals(db.mensagens[0].data_hora, futura.dataHora); // gravada como veio
});

Deno.test("GET /chat: devolve as mais recentes em ordem, com truncado=true quando há mais antigas", async () => {
  const msgs = Array.from({ length: 5 }, (_, i) => ({
    chave_mensagem: `dddddddd-0000-4000-8000-00000000000${i}`,
    chave_compra: CHAVE_DEMO,
    id: i + 1,
    data_hora: `2026-11-19T10:0${i}:00Z`,
    texto: `m${i}`,
  }));
  const db = dbDemo({ mensagens: msgs });
  const res = await handleRequest(
    new Request("http://localhost/api-disputa/chat?licitacao_id=101&limite=3"),
    {
      getUser: () => Promise.resolve(USUARIO_TESTE),
      // deno-lint-ignore no-explicit-any
      getSupabase: () => createMockSupabase(db) as any,
    },
  );
  assertEquals(res.status, 200);
  const json = await res.json();
  // O mock não aplica limit(): a rota corta em `limite` e marca truncado se vier mais.
  assertEquals(json.mensagens.length, 3);
  assertEquals(json.truncado, true);
  assertEquals(json.mensagens.map((m: { texto: string }) => m.texto), ["m2", "m3", "m4"]);
});

Deno.test("api-disputa: POST /auditoria - papel desconhecido não escreve (allowlist, não lista de exclusão)", async () => {
  const { res, db } = await chamarAuditoria("gerente", pedidoAuditoria(AUDITORIA_VALIDA));
  assertEquals(res.status, 403);
  assertEquals(db.auditoria.length, 0);
});

Deno.test("api-disputa: POST /auditoria - 404 se o item não existe na licitação", async () => {
  const { res, db } = await chamarAuditoria("admin", pedidoAuditoria({ ...AUDITORIA_VALIDA, item_numero: 99 }));
  assertEquals(res.status, 404);
  assertEquals(db.auditoria.length, 0);
});
