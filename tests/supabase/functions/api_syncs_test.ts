import { assertEquals } from "jsr:@std/assert@1";
import { SYNCS } from "../../../supabase/functions/api-syncs/catalogo.ts";
import {
  type ApiSyncsContext,
  handleRequest,
  type StatusJobCron,
} from "../../../supabase/functions/api-syncs/index.ts";

const ADMIN = { id: "u1", app_metadata: { licitagym_role: "admin" } };
const COMUM = { id: "u2", app_metadata: {} };

function post(body: unknown) {
  return new Request("http://x/api-syncs", {
    method: "POST",
    body: JSON.stringify(body),
    headers: { Authorization: "Bearer t" },
  });
}

function ctx(over: Partial<ApiSyncsContext> = {}): ApiSyncsContext {
  return {
    isCron: () => false,
    getUser: () => Promise.resolve(ADMIN),
    segredo: () => "segredo-de-teste",
    baseUrl: () => "https://exemplo.supabase.co/functions/v1",
    fetchFn: () => Promise.resolve(new Response(JSON.stringify({ status: "ok", sync_id: "1" }), { status: 200 })),
    lerStatusCron: () => Promise.resolve([]),
    chamarRpc: () => Promise.resolve({ ok: true }),
    ...over,
  };
}

function linha(jobname: string, over: Partial<StatusJobCron> = {}): StatusJobCron {
  return {
    jobname,
    schedule: "* * * * *",
    ativo: true,
    run_id: 1,
    status: "succeeded",
    inicio: "2026-11-19T18:00:00Z",
    fim: "2026-11-19T18:00:01Z",
    mensagem: null,
    ...over,
  };
}

/** Leitor do pg_cron falso: devolve só as linhas dos jobs pedidos. */
function statusDe(linhas: StatusJobCron[]): ApiSyncsContext["lerStatusCron"] {
  return (jobs) => Promise.resolve(linhas.filter((l) => jobs.includes(l.jobname)));
}

async function listar(c: ApiSyncsContext) {
  const body = await (await handleRequest(post({ action: "listar" }), c)).json();
  const por = (slug: string) => body.syncs.find((s: { slug: string }) => s.slug === slug);
  return { body, por };
}

Deno.test("api-syncs: sem credencial 401 e usuário comum 403", async () => {
  assertEquals((await handleRequest(post({ action: "listar" }), ctx({ getUser: () => Promise.resolve(null) }))).status, 401);
  assertEquals((await handleRequest(post({ action: "listar" }), ctx({ getUser: () => Promise.resolve(COMUM) }))).status, 403);
});

Deno.test("api-syncs: listar separa cron de quem nunca entrou", async () => {
  const { body, por } = await listar(ctx());
  assertEquals(por("sync-portal-compras").cron, "Todo dia às 08:00.");
  assertEquals(por("sync-portal-compras").disparavel, true);
  assertEquals(por("sync-pncp-contratacoes-editais").cron, null);
  assertEquals(body.syncs.length, SYNCS.length);
  assertEquals(JSON.stringify(body).includes("segredo-de-teste"), false);
});

Deno.test("api-syncs: coletores PNCP, preços e PGC rodam no Supabase, sem GitHub Actions", async () => {
  const { por } = await listar(ctx());
  for (const slug of ["coletor-pncp", "coletor-precos", "coletor-pgc"]) {
    const item = por(slug);
    assertEquals(item.disparavel, true, slug);
    assertEquals(typeof item.rpc?.nome, "string", slug);
    assertEquals(Array.isArray(item.cron_jobs) && item.cron_jobs.length > 0, true, slug);
    assertEquals("github_workflow" in item, false, slug);
    assertEquals("refazer_cron" in item, false, slug);
    assertEquals(String(item.cron).includes("GitHub"), false, slug);
  }
  assertEquals(por("coletor-pgc").rpc.nome, "pgc_sync_planejar");
  assertEquals(por("coletor-pgc").cron_jobs, ["pgc-sync-planejar", "pgc-sync-tick"]);
  assertEquals(por("coletor-pncp").rpc, { nome: "licext_publicar_de_pncp_busca", args: { p_dias: 10 } });
  assertEquals(por("coletor-precos").rpc, { nome: "precos_sync_planejar", args: { p_dias: 60 } });
});

Deno.test("api-syncs: rodar encaminha o corpo do catálogo e não devolve o segredo", async () => {
  let url = "";
  let authorization = "";
  let enviado = "";
  const c = ctx({
    fetchFn: (input, init) => {
      url = String(input);
      authorization = new Headers(init?.headers).get("authorization") ?? "";
      enviado = String(init?.body);
      return Promise.resolve(new Response(JSON.stringify({ status: "ok" }), { status: 200 }));
    },
  });
  const res = await handleRequest(post({ action: "rodar", sync: "sync-portal-compras" }), c);
  const body = await res.json();
  assertEquals(res.status, 200);
  assertEquals(url, "https://exemplo.supabase.co/functions/v1/sync-portal-compras");
  assertEquals(authorization, "Bearer segredo-de-teste");
  assertEquals(JSON.parse(enviado), { limite: 40, origem: "manual" });
  assertEquals(JSON.stringify(body).includes("segredo-de-teste"), false);
});

Deno.test("api-syncs: sync que responde erro ainda devolve o corpo e o status", async () => {
  const c = ctx({
    fetchFn: () => Promise.resolve(new Response(JSON.stringify({ error: "limite excedido" }), { status: 429 })),
  });
  const res = await handleRequest(post({ action: "rodar", sync: "sync-portal-compras" }), c);
  const body = await res.json();
  assertEquals(res.status, 200);
  assertEquals(body.http, 429);
  assertEquals(body.resposta.error, "limite excedido");
  assertEquals(JSON.stringify(body).includes("segredo-de-teste"), false);
});

Deno.test("api-syncs: sync desconhecido não dispara, e todo item disparavel tem função ou rpc", async () => {
  let chamou = false;
  const c = ctx({ fetchFn: () => { chamou = true; return Promise.resolve(new Response("{}")); } });
  assertEquals((await handleRequest(post({ action: "rodar", sync: "nao-existe" }), c)).status, 400);
  assertEquals(chamou, false);
  assertEquals(SYNCS.every((s) => !s.disparavel || Boolean(s.funcao) || Boolean(s.rpc)), true);
});

// Syncs presos por trava de ambiente (PNCP_NATIONAL_SYNC_ENABLED, IRP_SYNC_ENABLED) ou que dependem de um sync
// travado: a tela não oferece "Rodar agora" e o disparo responde 400 com o motivo, sem chamar a função. Provisório:
// a spec 0024 (decisão de 14/10, #363) troca a trava pelo catálogo e devolve o disparo manual; aí saem desta lista.
const SYNCS_TRAVADOS = [
  "sync-pncp-contratacoes-editais",
  "sync-pncp-contratacoes-atas",
  "sync-pncp-contratacoes-contratos",
  "sync-pncp-irp",
  // depende de contratacoes_editais, alimentada só pelo sync nacional de editais (travado)
  "sync-pncp-contratacoes-itens",
];

Deno.test("api-syncs: syncs travados por escopo não são disparáveis e não chamam a função", async () => {
  let chamou = false;
  const c = ctx({ fetchFn: () => { chamou = true; return Promise.resolve(new Response("{}")); } });
  for (const slug of SYNCS_TRAVADOS) {
    const item = SYNCS.find((s) => s.slug === slug);
    assertEquals(item?.disparavel, false, slug);
    assertEquals(Boolean(item?.aviso), true, `${slug} precisa dizer por que está desligado`);
    const res = await handleRequest(post({ action: "rodar", sync: slug }), c);
    assertEquals(res.status, 400, slug);
    assertEquals((await res.json()).error, item?.aviso);
  }
  assertEquals(chamou, false);
});

Deno.test("CA-6 (spec 0023): rodar manda origem manual no corpo da função disparada", async () => {
  let enviado = "";
  const c = ctx({
    fetchFn: (_input, init) => {
      enviado = String(init?.body);
      return Promise.resolve(new Response(JSON.stringify({ status: "ok" }), { status: 200 }));
    },
  });
  const res = await handleRequest(post({ action: "rodar", sync: "sync-portal-compras" }), c);
  assertEquals(res.status, 200);
  const corpo = JSON.parse(enviado);
  assertEquals(corpo.origem, "manual");
  assertEquals(corpo.limite, 40);
});

Deno.test("api-syncs: rodar coletor com rpc chama a função SQL do catálogo, sem HTTP externo", async () => {
  for (const slug of ["coletor-pncp", "coletor-precos", "coletor-pgc"]) {
    const item = SYNCS.find((s) => s.slug === slug);
    let rpc: { nome: string; args: Record<string, unknown> } | null = null;
    let fetchChamado = false;
    const c = ctx({
      chamarRpc: (nome, args) => {
        rpc = { nome, args };
        return Promise.resolve([{ inseridos: 1 }]);
      },
      fetchFn: () => { fetchChamado = true; return Promise.resolve(new Response("{}")); },
    });
    const res = await handleRequest(post({ action: "rodar", sync: slug }), c);
    const body = await res.json();
    assertEquals(res.status, 200, slug);
    assertEquals(rpc, item?.rpc, slug);
    assertEquals(body.http, 200, slug);
    assertEquals(body.resposta, [{ inseridos: 1 }], slug);
    assertEquals(fetchChamado, false, slug);
  }
});

Deno.test("api-syncs: falha da função SQL responde 502 sem vazar a mensagem do banco", async () => {
  const c = ctx({ chamarRpc: () => Promise.reject(new Error("permission denied for function x")) });
  const res = await handleRequest(post({ action: "rodar", sync: "coletor-pgc" }), c);
  const texto = await res.text();
  assertEquals(res.status, 502);
  assertEquals(texto.includes("permission denied"), false);
});

Deno.test("api-syncs: último cron vem do pg_cron (jobs ok → success, run mais recente)", async () => {
  const c = ctx({
    lerStatusCron: statusDe([
      linha("pgc-sync-planejar", { run_id: 10, inicio: "2026-11-19T12:10:00Z" }),
      linha("pgc-sync-tick", { run_id: 11, inicio: "2026-11-19T18:00:00Z" }),
    ]),
  });
  const { por } = await listar(c);
  const pgc = por("coletor-pgc");
  assertEquals(pgc.ultimo_cron.run_id, 11);
  assertEquals(pgc.ultimo_cron.status, "completed");
  assertEquals(pgc.ultimo_cron.conclusion, "success");
  assertEquals(pgc.ultimo_cron.created_at, "2026-11-19T18:00:00Z");
  assertEquals(pgc.ultimo_cron.html_url, null);
  assertEquals(pgc.ultimo_cron.etapas.map((e: { nome: string }) => e.nome), ["pgc-sync-planejar", "pgc-sync-tick"]);
  assertEquals(pgc.pode_refazer, false);
  assertEquals(pgc.erro_ultimo_cron, null);
});

Deno.test("api-syncs: job que falhou vira failure e mostra a mensagem do pg_cron", async () => {
  const c = ctx({
    lerStatusCron: statusDe([
      linha("pgc-sync-planejar"),
      linha("pgc-sync-tick", { status: "failed", mensagem: "relation x does not exist" }),
    ]),
  });
  const { por } = await listar(c);
  const pgc = por("coletor-pgc");
  assertEquals(pgc.ultimo_cron.conclusion, "failure");
  const etapa = pgc.ultimo_cron.etapas.find((e: { nome: string }) => e.nome.startsWith("pgc-sync-tick"));
  assertEquals(etapa.nome, "pgc-sync-tick: relation x does not exist");
  assertEquals(etapa.conclusion, "failure");
});

Deno.test("api-syncs: job rodando deixa o último cron em andamento", async () => {
  const c = ctx({
    lerStatusCron: statusDe([
      linha("pgc-sync-planejar"),
      linha("pgc-sync-tick", { status: "running", fim: null }),
    ]),
  });
  const { por } = await listar(c);
  assertEquals(por("coletor-pgc").ultimo_cron.status, "in_progress");
  assertEquals(por("coletor-pgc").ultimo_cron.conclusion, null);
});

Deno.test("api-syncs: job sem agendamento aparece como não agendado, sem derrubar o resto", async () => {
  const c = ctx({ lerStatusCron: statusDe([linha("pgc-sync-tick")]) });
  const { por } = await listar(c);
  const nomes = por("coletor-pgc").ultimo_cron.etapas.map((e: { nome: string }) => e.nome);
  assertEquals(nomes, ["pgc-sync-planejar (não agendado)", "pgc-sync-tick"]);
});

Deno.test("api-syncs: job desativado e job que ainda não rodou não contam como falha", async () => {
  const c = ctx({
    lerStatusCron: statusDe([
      linha("pgc-sync-planejar", { ativo: false }),
      linha("pgc-sync-tick", { run_id: null, status: null, inicio: null, fim: null }),
    ]),
  });
  const { por } = await listar(c);
  const pgc = por("coletor-pgc");
  // o planejar desativado ainda tem run e início; o tick nunca rodou
  assertEquals(pgc.ultimo_cron.conclusion, "success");
  assertEquals(pgc.ultimo_cron.etapas.map((e: { nome: string }) => e.nome), ["pgc-sync-planejar (desativado)", "pgc-sync-tick (ainda não rodou)"]);
});

Deno.test("api-syncs: nenhum job rodou ainda → ultimo_cron null com motivo", async () => {
  const { por } = await listar(ctx({ lerStatusCron: () => Promise.resolve([]) }));
  const pgc = por("coletor-pgc");
  assertEquals(pgc.ultimo_cron, null);
  assertEquals(pgc.motivo_refazer, "Nenhum job agendado rodou ainda.");
  assertEquals(pgc.erro_ultimo_cron, null);
});

Deno.test("api-syncs: falha ao ler o pg_cron vira erro do item e os outros syncs seguem", async () => {
  const c = ctx({ lerStatusCron: () => Promise.reject(new Error("boom interno")) });
  const { body, por } = await listar(c);
  const pgc = por("coletor-pgc");
  assertEquals(pgc.ultimo_cron, null);
  assertEquals(pgc.pode_refazer, false);
  assertEquals(pgc.erro_ultimo_cron, "Falha ao ler o status dos jobs no pg_cron.");
  assertEquals(JSON.stringify(body).includes("boom interno"), false);
  assertEquals(body.syncs.length, SYNCS.length);
  assertEquals(por("sync-portal-compras").cron, "Todo dia às 08:00.");
});

Deno.test("api-syncs: refazer não existe mais (era do GitHub Actions) e responde 400 sem chamar nada", async () => {
  let chamou = false;
  const c = ctx({
    fetchFn: () => { chamou = true; return Promise.resolve(new Response("{}")); },
    chamarRpc: () => { chamou = true; return Promise.resolve(null); },
  });
  const res = await handleRequest(post({ action: "refazer", sync: "coletor-pncp" }), c);
  assertEquals(res.status, 400);
  assertEquals(chamou, false);
});

Deno.test("CA-4 (spec 0044): a legislação sai do catálogo e o disparo dela é slug desconhecido", async () => {
  assertEquals(SYNCS.some((s) => s.slug === "sync-pncp-legislation" || s.funcao === "sync-pncp-legislation"), false);
  const lista = await (await handleRequest(post({ action: "listar" }), ctx())).json();
  assertEquals(lista.syncs.some((s: { slug: string }) => s.slug === "sync-pncp-legislation"), false);
  let chamou = false;
  const res = await handleRequest(
    post({ action: "rodar", sync: "sync-pncp-legislation" }),
    ctx({ fetchFn: () => { chamou = true; return Promise.resolve(new Response("{}")); } }),
  );
  assertEquals(res.status, 400);
  assertEquals((await res.json()).error, "Sync desconhecido.");
  assertEquals(chamou, false);
});
