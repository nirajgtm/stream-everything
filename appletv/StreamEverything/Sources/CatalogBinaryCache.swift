import Foundation

/// Compact on-disk form of a parsed catalog. Reading it back is a straight byte walk
/// with no JSON, no Unicode folding and no adult-rule regex, which is what makes a
/// cold start show home in a second instead of re-deriving 300k entries.
enum CatalogBinaryCache {
    private static let version: UInt32 = 1

    static func write(_ entries: [Entry], to url: URL) {
        var data = Data()
        data.reserveCapacity(entries.count * 160)
        append(&data, version)
        append(&data, UInt32(entries.count))
        for e in entries {
            data.append(UInt8(e.kind == .live ? 0 : e.kind == .movie ? 1 : 2))
            append(&data, Int64(e.id))
            append(&data, e.name); append(&data, e.ext); append(&data, e.logo); append(&data, e.categoryId)
            append(&data, e.epgId)
            append(&data, Int32(e.archive))
            append(&data, e.searchKey)
            append(&data, e.lang ?? "")
            data.append(e.adult ? 1 : 0)
        }
        try? data.write(to: url, options: .atomic)
    }

    static func read(from url: URL) -> [Entry]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        var reader = Reader(data: data)
        guard reader.u32() == version, let count = reader.u32() else { return nil }
        var out: [Entry] = []
        out.reserveCapacity(Int(count))
        for _ in 0..<count {
            guard let kindByte = reader.u8(), let id = reader.i64(),
                  let name = reader.string(), let ext = reader.string(), let logo = reader.string(),
                  let categoryId = reader.string(), let epgId = reader.string(), let archive = reader.i32(),
                  let searchKey = reader.string(), let lang = reader.string(), let adult = reader.u8()
            else { return nil }
            let kind: Kind = kindByte == 0 ? .live : kindByte == 1 ? .movie : .series
            out.append(Entry(kind: kind, name: name, id: Int(id), ext: ext, logo: logo, categoryId: categoryId,
                             epgId: epgId, archive: Int(archive), searchKey: searchKey, adult: adult == 1,
                             lang: lang.isEmpty ? nil : lang))
        }
        return out
    }

    // MARK: Bytes

    private static func append(_ data: inout Data, _ value: UInt32) { var v = value.littleEndian; data.append(Data(bytes: &v, count: 4)) }
    private static func append(_ data: inout Data, _ value: Int32) { var v = value.littleEndian; data.append(Data(bytes: &v, count: 4)) }
    private static func append(_ data: inout Data, _ value: Int64) { var v = value.littleEndian; data.append(Data(bytes: &v, count: 8)) }
    private static func append(_ data: inout Data, _ value: String) {
        let bytes = Data(value.utf8)
        append(&data, UInt32(bytes.count))
        data.append(bytes)
    }

    private struct Reader {
        let data: Data
        var offset = 0
        init(data: Data) { self.data = data }

        mutating func u8() -> UInt8? {
            guard offset < data.count else { return nil }
            defer { offset += 1 }
            return data[data.startIndex + offset]
        }
        mutating func u32() -> UInt32? { fixed(4).map { $0.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian } }
        mutating func i32() -> Int32? { fixed(4).map { $0.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }.littleEndian } }
        mutating func i64() -> Int64? { fixed(8).map { $0.withUnsafeBytes { $0.loadUnaligned(as: Int64.self) }.littleEndian } }
        mutating func string() -> String? {
            guard let length = u32(), let bytes = fixed(Int(length)) else { return nil }
            return String(decoding: bytes, as: UTF8.self)
        }
        private mutating func fixed(_ count: Int) -> Data? {
            guard offset + count <= data.count else { return nil }
            defer { offset += count }
            let start = data.startIndex + offset
            return data.subdata(in: start..<(start + count))
        }
    }
}
