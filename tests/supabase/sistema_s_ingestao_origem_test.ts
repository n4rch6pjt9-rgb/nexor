import { assert } from "jsr:@std/assert@1";
import { type FonteColeta, linhaLicitacao } from "../../supabase/functions/_shared/coletor/paradigma-coleta.ts";

// Regressão da primeira execução real do sescdn (2026-11-21): a linha trazia ingestao_origem = 'sistema_s_cron' e o banco
// recusou, porque licitacoes_externas_ingestao_origem_chk aceita apenas os valores abaixo.
const VALORES_ACEITOS_PELO_CHECK = ["cron", "manual"];

Deno.test("linhaLicitacao usa um valor de ingestao_origem aceito pelo check do banco", () => {
  const f: FonteColeta = {
    slug: "t1", base_url: "https://portal.exemplo.invalid/p", ativo: true, robots_permite: null,
    mural_autorizado: false, pausada_ate: null, delay_ms: 1000, entidade: "SESC", uf: "DN",
  };
  const l = linhaLicitacao(f, { nCdProcesso: 1, nCdModulo: 22, sDsObjeto: "x", sDsSituacao: "Em andamento" });
  assert(VALORES_ACEITOS_PELO_CHECK.includes(l.ingestao_origem as string), `ingestao_origem = ${l.ingestao_origem}`);
});
