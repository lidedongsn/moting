import CSherpaOnnx
import Foundation

public protocol Punctuating {
    func punctuate(_ text: String) -> String
}

/// 给没有标点的识别结果加标点（CT-Transformer）
public final class Punctuator: Punctuating {
    private let handle: OpaquePointer

    public init(model: AuxModel, directory: URL) throws {
        guard let name = model.files.first?.name else { throw OfflineASRError.modelMissing(model.id) }
        let path = directory.appendingPathComponent(name).path
        guard FileManager.default.fileExists(atPath: path) else { throw OfflineASRError.modelMissing(name) }
        let pool = CStringPool()
        var config = SherpaOnnxOfflinePunctuationConfig()
        config.model.ct_transformer = pool.c(path)
        config.model.num_threads = 1
        config.model.provider = pool.c("cpu")
        guard let h = SherpaOnnxCreateOfflinePunctuation(&config) else { throw OfflineASRError.createFailed(model.id) }
        handle = h
    }

    deinit {
        SherpaOnnxDestroyOfflinePunctuation(handle)
    }

    public func punctuate(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        guard let out = text.withCString({ SherpaOfflinePunctuationAddPunct(handle, $0) }) else { return text }
        defer { SherpaOfflinePunctuationFreeText(out) }
        return String(cString: out)
    }
}
