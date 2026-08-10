import Foundation

/// Migração de manifest entre versões de schema.
///
/// Na v1 é a identidade, mas a estrutura já está pronta para o futuro: cada versão antiga
/// tem um `case` que transforma o manifest e sobe UM número por vez (migração incremental).
/// Isso garante que um caderno criado em v1 continue abrindo quando o schema for para v2, v3…
public enum Migrator {
    public static func migrate(_ manifest: Manifest) throws -> Manifest {
        var m = manifest

        // Só migramos para frente. Quem chama (NotebookStore.open) já garante que
        // schemaVersion <= current; versões futuras demais são barradas antes daqui.
        while m.schemaVersion < CadernoSchema.current {
            switch m.schemaVersion {
            // Exemplo para o futuro:
            // case 1:
            //     // ... transformar campos da v1 -> v2 ...
            //     m.schemaVersion = 2
            default:
                // Não há transformação definida para esta versão anterior: nada a mudar
                // nos dados, apenas reconhecemos a versão seguinte. Passo seguro (sem perda).
                m.schemaVersion += 1
            }
        }
        return m
    }
}
