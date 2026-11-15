import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import { listarIdsMunicipioFonte } from "../../../supabase/functions/_shared/geografia/municipio.ts";

Deno.test("expansão municipal retorna somente referências recebidas da RPC verificada", async () => {
  let chamada: { nome: string; parametros: Record<string, unknown> } | null = null;
  const client = {
    rpc: async (nome: string, parametros: Record<string, unknown>) => {
      chamada = { nome, parametros };
      const todos = [
        { namespace: "municipio_id", valor_externo: "4480" },
        { namespace: "suggest_municipio", valor_externo: "4480" },
        { namespace: "", valor_externo: "ignorar" },
      ];
      const filtrados = parametros.p_namespaces
        ? todos.filter((item) => (parametros.p_namespaces as string[]).includes(item.namespace))
        : todos;
      return { data: filtrados, error: null };
    },
  } as never;

  const referencias = await listarIdsMunicipioFonte(client, "municipio-uuid", "pncp", ["municipio_id"]);
  assertEquals(referencias, [
    { namespace: "municipio_id", valor_externo: "4480" },
  ]);
  assertEquals(chamada, {
    nome: "listar_ids_municipio_fonte",
    parametros: {
      p_municipio_id: "municipio-uuid",
      p_fonte: "pncp",
      p_namespaces: ["municipio_id"],
    },
  });
});

Deno.test("falha ao expandir município não deve remover filtro geográfico", async () => {
  const client = {
    rpc: async () => ({ data: null, error: { message: "permission denied" } }),
  } as never;
  await assertRejects(
    () => listarIdsMunicipioFonte(client, "municipio-uuid", "pncp"),
    Error,
    "permission denied",
  );
});
