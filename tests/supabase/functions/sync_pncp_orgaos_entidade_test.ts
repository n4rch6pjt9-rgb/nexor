// Regressão #321: o upsert de public.entidades não pode enviar coluna gerada.
// entidades.cnpj_normalizado é GENERATED ALWAYS (202609180002_entidades.sql); enviá-la faz o PostgREST
// responder 400 em todo PATCH/INSERT, e o sync de órgãos terminava com erro em todos os CNPJs.
// As colunas geradas são lidas das migrations, para que uma coluna gerada nova também seja coberta.
import { assert, assertEquals } from "jsr:@std/assert@1";
import { linhaEntidade } from "../../../supabase/functions/sync-pncp-orgaos/entidade.ts";
import {
  identificadorMunicipioFonte,
  linhaUnidade,
  municipioDaUnidade,
  normalizarNomeMunicipio,
} from "../../../supabase/functions/sync-pncp-orgaos/unidade.ts";


const MIGRATIONS = new URL("../../../supabase/migrations/", import.meta.url);

async function colunasGeradasDeEntidades(): Promise<Set<string>> {
  const colunas = new Set<string>();
  for await (const arq of Deno.readDir(MIGRATIONS)) {
    if (!arq.isFile || !arq.name.endsWith(".sql") || !/^\d/.test(arq.name)) continue;
    const sql = await Deno.readTextFile(new URL(arq.name, MIGRATIONS));
    // create table public.entidades ( ... ) e alter table public.entidades add column ...
    for (const m of sql.matchAll(/(?:create|alter)\s+table\s+(?:if\s+not\s+exists\s+)?public\.entidades\b([\s\S]*?);/gi)) {
      for (const c of m[1].matchAll(/(?:^|[,(\s])(?:add\s+column\s+(?:if\s+not\s+exists\s+)?)?(\w+)\s+[\w ]+?\s+generated\s+always/gi)) {
        colunas.add(c[1].toLowerCase());
      }
    }
  }
  return colunas;
}

Deno.test("#321: as migrations declaram cnpj_normalizado como coluna gerada de entidades", async () => {
  assert((await colunasGeradasDeEntidades()).has("cnpj_normalizado"));
});

Deno.test("#321: linha de entidades não contém coluna gerada", async () => {
  const geradas = await colunasGeradasDeEntidades();
  const enviadas = Object.keys(linhaEntidade("00394429000100"));
  assertEquals(enviadas.filter((c) => geradas.has(c)), [], "coluna gerada enviada no upsert");
});

Deno.test("#321: linha de entidades mantém os campos que o sync grava", () => {
  assertEquals(linhaEntidade("00394429000100"), {
    codigo_pncp: "00394429000100",
    cnpj: "00394429000100",
    tipo: "orgao",
  });
});

Deno.test("PNCP UnidadeOrgaoDTO preserva Municipio.id separado de codigoIbge", () => {
  const unidade = {
    codigoUnidade: "05001",
    nomeUnidade: "Secretaria da Saúde - SESA",
    municipio: {
      id: 4480,
      nome: "Navegantes",
      codigoIbge: "4211306",
      uf: { siglaUF: "SC", nomeUF: "Santa Catarina" },
    },
  };
  assertEquals(municipioDaUnidade(unidade), {
    id: "4480",
    nome: "Navegantes",
    uf: "SC",
    codigoIbge: "4211306",
  });
  assertEquals(linhaUnidade("orgao-uuid", unidade), {
    orgao_id: "orgao-uuid",
    codigo_unidade: "05001",
    nome: "Secretaria da Saúde - SESA",
    uf: "SC",
    municipio_ibge: "4211306",
  });
});

Deno.test("PNCP unidade não converte Municipio.id em municipio_ibge", () => {
  const unidade = {
    codigoUnidade: "0001",
    nomeUnidade: "Unidade sem código IBGE",
    municipio: { id: 4480, nome: "Navegantes", uf: { siglaUF: "SC" } },
  };
  assertEquals(linhaUnidade("orgao-uuid", unidade), {
    orgao_id: "orgao-uuid",
    codigo_unidade: "0001",
    nome: "Unidade sem código IBGE",
    uf: "SC",
  });
});

Deno.test("normalização de município é compatível com a chave SQL", () => {
  assertEquals(normalizarNomeMunicipio("São   José"), "sao jose");
});


Deno.test("id de nível superior é da unidade e nunca vira Municipio.id", () => {
  // Regressão: com `municipio` nulo/ausente o DTO da unidade era lido como se fosse o município.
  for (const unidade of [
    { id: 123, codigoUnidade: "0001", nomeUnidade: "Unidade A", municipio: null },
    { id: 123, codigoUnidade: "0001", nomeUnidade: "Unidade A" },
    { id: 123, nome: "Nome da unidade", codigoUnidade: "0001", municipioNome: "Navegantes", ufSigla: "SC" },
  ]) {
    const municipio = municipioDaUnidade(unidade);
    assertEquals(municipio?.id ?? null, null);
    assertEquals(municipio?.nome === "Nome da unidade", false);
  }
  // O DTO plano ainda fornece nome/UF/IBGE do município pelos campos próprios.
  assertEquals(
    municipioDaUnidade({ id: 123, municipioNome: "Navegantes", ufSigla: "SC", codigoIbge: "4211306" }),
    { id: null, nome: "Navegantes", uf: "SC", codigoIbge: "4211306" },
  );
});

Deno.test("Municipio.id sem codigoIbge fica não verificado (sem vínculo por nome+UF)", () => {
  const municipio = municipioDaUnidade({
    municipio: { id: 4480, nome: "Navegantes", uf: { siglaUF: "SC" } },
  });
  assert(municipio);
  assertEquals(identificadorMunicipioFonte(municipio), {
    namespace: "municipio_id",
    valor: "4480",
    verificado: false,
  });
});

Deno.test("Municipio.id usa namespace próprio e não é convertido em IBGE", () => {
  const municipio = municipioDaUnidade({
    municipio: { id: 4480, nome: "Navegantes", codigoIbge: "4211306", uf: { siglaUF: "SC" } },
  });
  assert(municipio);
  assertEquals(identificadorMunicipioFonte(municipio), {
    namespace: "municipio_id",
    valor: "4480",
    verificado: true,
  });
});
