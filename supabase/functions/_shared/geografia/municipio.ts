import type { SupabaseClient } from "npm:@supabase/supabase-js@2";

export type MunicipioReferenciaFonte = {
  namespace: string;
  valor_externo: string;
};

/**
 * Expande uma FK municipal canônica para IDs verificados da fonte.
 * A RPC não retorna referências pendentes, conflitantes ou rejeitadas.
 * Em erro, lança exceção: filtros não podem continuar sem a restrição geográfica.
 */
export async function listarIdsMunicipioFonte(
  client: SupabaseClient,
  municipioId: string,
  fonte: string,
  namespaces?: readonly string[],
): Promise<MunicipioReferenciaFonte[]> {
  if (!municipioId.trim() || !fonte.trim()) {
    throw new Error("municipioId e fonte são obrigatórios");
  }
  const { data, error } = await client.rpc("listar_ids_municipio_fonte", {
    p_municipio_id: municipioId,
    p_fonte: fonte,
    p_namespaces: namespaces ? [...namespaces] : null,
  });
  if (error) throw new Error(`Falha ao expandir município para ${fonte}: ${error.message}`);
  if (!Array.isArray(data)) throw new Error(`Resposta inválida ao expandir município para ${fonte}`);

  return data.flatMap((item: Record<string, unknown>) => {
    const namespace = typeof item.namespace === "string" ? item.namespace : "";
    const valorExterno = typeof item.valor_externo === "string" ? item.valor_externo : "";
    return namespace && valorExterno ? [{ namespace, valor_externo: valorExterno }] : [];
  });
}
