import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// Wrapper SwiftUI do seletor de fotos do sistema (`PHPickerViewController`).
///
/// Configurado para UMA imagem por vez. Ao escolher, entrega os BYTES da imagem e uma
/// extensão de arquivo sugerida (ex.: "jpg"/"png"/"heic") para quem for gravar o asset.
/// Nunca acessa a biblioteca de fotos diretamente — o `PHPicker` roda fora do processo e
/// só devolve o que o usuário escolheu, sem precisar de permissão de fototeca.
struct PhotoPicker: UIViewControllerRepresentable {
    /// (bytes da imagem, extensão do arquivo como "jpg"/"png"). Sempre chamado na MAIN thread.
    var onPick: (Data, String) -> Void
    /// Cancelou, veio vazio ou falhou o carregamento. Também na MAIN thread.
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick, onCancel: onCancel)
    }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .images      // só imagens
        config.selectionLimit = 1    // uma por vez
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {
        // Nada a atualizar: o seletor não tem estado dinâmico vindo do SwiftUI.
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        // Guardamos as CLOSURES (não a struct PhotoPicker), pois a struct é recriada a cada
        // atualização de layout. As closures são o contrato estável com quem nos usa.
        private let onPick: (Data, String) -> Void
        private let onCancel: () -> Void

        init(onPick: @escaping (Data, String) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick
            self.onCancel = onCancel
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            // Fecha o seletor sempre, independentemente do resultado.
            picker.dismiss(animated: true)

            guard let result = results.first else {
                // Vazio = usuário cancelou.
                onCancel()
                return
            }

            let provider = result.itemProvider
            let imageTypeID = UTType.image.identifier
            guard provider.hasItemConformingToTypeIdentifier(imageTypeID) else {
                onCancel()
                return
            }

            // Capturamos as closures e os identificadores em LOCAIS antes da closure de
            // carregamento (que roda concorrente): assim o bloco não retém `self` nem
            // depende de estado mutável do coordinator (gotcha do projeto sobre captura).
            let onPick = self.onPick
            let onCancel = self.onCancel
            let registeredTypes = provider.registeredTypeIdentifiers

            // Preferimos o tipo genérico `public.image` para receber os bytes crus; a
            // extensão real é inferida à parte (dos tipos registrados / magic bytes).
            provider.loadDataRepresentation(forTypeIdentifier: imageTypeID) { data, error in
                guard let data = data, error == nil else {
                    DispatchQueue.main.async { onCancel() }
                    return
                }
                let ext = Self.inferExtension(registeredTypes: registeredTypes, data: data)
                DispatchQueue.main.async { onPick(data, ext) }
            }
        }

        // MARK: - Inferência da extensão

        /// Descobre uma extensão de arquivo adequada, na ordem:
        /// 1) tipo de imagem CONCRETO mais específico registrado pelo item;
        /// 2) "magic bytes" do conteúdo (fallback quando só há o tipo genérico);
        /// 3) "jpg" como último recurso.
        private static func inferExtension(registeredTypes: [String], data: Data) -> String {
            for identifier in registeredTypes {
                if let type = UTType(identifier),
                   type.conforms(to: .image),
                   type != .image,                       // ignora o guarda-chuva genérico
                   let ext = type.preferredFilenameExtension {
                    return ext
                }
            }
            if let sniffed = sniffExtension(data) {
                return sniffed
            }
            return "jpg"
        }

        /// Fareja os primeiros bytes para identificar formatos comuns. Retorna `nil` se
        /// não reconhecer (aí o chamador cai no padrão).
        private static func sniffExtension(_ data: Data) -> String? {
            guard data.count >= 12 else { return nil }
            let b = [UInt8](data.prefix(12))

            // PNG: 89 50 4E 47
            if b[0] == 0x89, b[1] == 0x50, b[2] == 0x4E, b[3] == 0x47 {
                return "png"
            }
            // JPEG: FF D8 FF
            if b[0] == 0xFF, b[1] == 0xD8, b[2] == 0xFF {
                return "jpg"
            }
            // GIF: "GIF"
            if b[0] == 0x47, b[1] == 0x49, b[2] == 0x46 {
                return "gif"
            }
            // TIFF: "II*\0" (little-endian) ou "MM\0*" (big-endian)
            let isLittleEndianTIFF = b[0] == 0x49 && b[1] == 0x49 && b[2] == 0x2A && b[3] == 0x00
            let isBigEndianTIFF = b[0] == 0x4D && b[1] == 0x4D && b[2] == 0x00 && b[3] == 0x2A
            if isLittleEndianTIFF || isBigEndianTIFF {
                return "tiff"
            }
            // HEIC/HEIF: box "ftyp" nos bytes 4..8, com marca "heic"/"heif"/"mif1"/"heix".
            if b[4] == 0x66, b[5] == 0x74, b[6] == 0x79, b[7] == 0x70 {
                let brand = String(bytes: b[8..<12], encoding: .ascii)
                if let brand = brand,
                   ["heic", "heif", "mif1", "heix", "hevc"].contains(brand) {
                    return "heic"
                }
            }
            return nil
        }
    }
}
