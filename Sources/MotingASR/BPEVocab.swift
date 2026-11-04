import Foundation

/// 识别库的热词编码要文本格式的 bpe.vocab（每行"词 分数"），很多模型仓库只给二进制的 bpe.model。
/// 这里按 sentencepiece 的 protobuf 结构读出来，第一次用时生成在模型目录里。
/// 给错文件时识别库会直接退出进程，所以格式不对必须在这里报错
enum BPEVocab {
    static func ensure(modelAt model: URL) throws -> URL {
        let vocab = model.deletingPathExtension().appendingPathExtension("vocab")
        if FileManager.default.fileExists(atPath: vocab.path) { return vocab }
        let text = try BPEVocab.text(fromModel: Data(contentsOf: model))
        try text.write(to: vocab, atomically: true, encoding: .utf8)
        return vocab
    }

    static func text(fromModel data: Data) throws -> String {
        var reader = Protobuf(data)
        var lines = ""
        while let field = try reader.nextField() {
            guard field.number == 1, case .bytes(let body) = field.value else { continue }
            var item = Protobuf(body)
            var token: String?
            var score: Float = 0
            while let f = try item.nextField() {
                switch (f.number, f.value) {
                case (1, .bytes(let d)): token = String(decoding: d, as: UTF8.self)
                case (2, .fixed32(let bits)): score = Float(bitPattern: bits)
                default: break
                }
            }
            guard let token else { throw OfflineASRError.modelMissing("bpe.model") }
            lines += "\(token) \(score)\n"
        }
        guard !lines.isEmpty else { throw OfflineASRError.modelMissing("bpe.model") }
        return lines
    }

    private struct Protobuf {
        enum Value { case varint(UInt64), fixed32(UInt32), fixed64, bytes(Data) }
        private let bytes: [UInt8]
        private var i = 0

        init(_ data: Data) { bytes = [UInt8](data) }

        mutating func nextField() throws -> (number: Int, value: Value)? {
            guard i < bytes.count else { return nil }
            let key = try varint()
            let number = Int(key >> 3)
            switch key & 7 {
            case 0: return (number, .varint(try varint()))
            case 1:
                try skip(8)
                return (number, .fixed64)
            case 2:
                let n = Int(clamping: try varint())
                let start = i
                try skip(n)
                return (number, .bytes(Data(bytes[start..<(start + n)])))
            case 5:
                let start = i
                try skip(4)
                let v = (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[start + $1]) << (8 * UInt32($1)) }
                return (number, .fixed32(v))
            default:
                throw OfflineASRError.modelMissing("bpe.model")
            }
        }

        private mutating func skip(_ n: Int) throws {
            guard n >= 0, n <= bytes.count - i else { throw OfflineASRError.modelMissing("bpe.model") }
            i += n
        }

        private mutating func varint() throws -> UInt64 {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            while i < bytes.count, shift < 64 {
                let b = bytes[i]
                i += 1
                result |= UInt64(b & 0x7F) << shift
                if b & 0x80 == 0 { return result }
                shift += 7
            }
            throw OfflineASRError.modelMissing("bpe.model")
        }
    }
}
