import SwiftUI
#if canImport(ImagePlayground)
import ImagePlayground
#endif

/// Ponte para o Image Playground da Apple (gera imagem NO PRÓPRIO iPad, de graça e privado).
///
/// Tudo aqui é protegido por `#if canImport(ImagePlayground)`: em iPads/versões antigas que
/// não têm o framework, este código simplesmente "some" na compilação — o app continua
/// compilando e a opção não aparece. Onde existe (iPadOS 18.1+ com Apple Intelligence), a
/// folha nativa aparece e devolve a imagem gerada.
extension View {

    /// Anexa a folha do Image Playground. Quando indisponível, não faz nada (retorna a view).
    /// `seed` é um texto inicial opcional; o usuário pode refinar dentro da folha da Apple.
    @ViewBuilder
    func appleImagePlaygroundSheet(isPresented: Binding<Bool>,
                                   seed: String,
                                   onImageData: @escaping (Data) -> Void) -> some View {
        #if canImport(ImagePlayground)
        if #available(iOS 18.1, *) {
            self.imagePlaygroundSheet(isPresented: isPresented, concept: seed) { url in
                if let data = try? Data(contentsOf: url) {
                    onImageData(data)
                }
            }
        } else {
            self
        }
        #else
        self
        #endif
    }
}

/// true se este build/aparelho tem o Image Playground disponível (SDK + versão do sistema).
/// Não garante que a conta tem Apple Intelligence ligado — mas basta para mostrar/ocultar a opção.
var appleImageGenAvailable: Bool {
    #if canImport(ImagePlayground)
    if #available(iOS 18.1, *) { return true } else { return false }
    #else
    return false
    #endif
}
