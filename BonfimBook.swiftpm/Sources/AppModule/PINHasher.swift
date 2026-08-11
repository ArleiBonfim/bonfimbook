import Foundation
import CryptoKit

/// Transforma a senha (PIN) do caderno num "hash" — um embaralhamento de mão única. A senha
/// original NUNCA é guardada; salvamos só este hash no manifest (via `NotebookStore.setLockHash`).
/// Para conferir, embaralhamos o que o usuário digitou e comparamos os hashes.
///
/// Fica na camada de UI (AppModule) de propósito: o CadernoCore continua só-Foundation, sem
/// depender de CryptoKit.
enum PINHasher {
    /// SHA-256 do PIN, em hexadecimal. Um "sal" fixo do app dificulta comparações triviais.
    static func hash(_ pin: String) -> String {
        let salted = "BonfimBook.v1.salt::" + pin
        let digest = SHA256.hash(data: Data(salted.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Confere se `pin` corresponde ao `hash` salvo.
    static func matches(_ pin: String, hash: String?) -> Bool {
        guard let hash = hash else { return false }
        return self.hash(pin) == hash
    }
}
