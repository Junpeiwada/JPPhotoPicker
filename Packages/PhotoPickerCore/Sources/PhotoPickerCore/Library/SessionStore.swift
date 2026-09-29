import Foundation

/// 移動 1 件の記録（フォルダからの相対パス）
public struct MoveRecord: Sendable, Codable, Hashable {
    public var from: String
    public var to: String

    public init(from: String, to: String) {
        self.from = from
        self.to = to
    }
}

/// 適用 1 回の記録
public struct ApplyRecord: Sendable, Codable, Hashable, Identifiable {
    /// 記録の ID。古い JSON に無い場合は読み込み時に生成する
    public var id: UUID
    public var date: Date
    public var moves: [MoveRecord]

    public init(id: UUID = UUID(), date: Date, moves: [MoveRecord]) {
        self.id = id
        self.date = date
        self.moves = moves
    }

    private enum CodingKeys: String, CodingKey { case id, date, moves }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        date = try c.decode(Date.self, forKey: .date)
        moves = try c.decode([MoveRecord].self, forKey: .moves)
    }
}

/// `.photopicker.json` の中身
public struct SessionData: Sendable, Codable, Equatable {
    public var version: Int
    /// コマ ID（ファイル名）→ 判定。未判定は持たない
    public var decisions: [String: Decision]
    /// 適用の記録（古い順）
    public var applied: [ApplyRecord]

    public static let currentVersion = 1

    public init(version: Int = SessionData.currentVersion,
                decisions: [String: Decision] = [:],
                applied: [ApplyRecord] = []) {
        self.version = version
        self.decisions = decisions
        self.applied = applied
    }

    private enum CodingKeys: String, CodingKey { case version, decisions, applied }

    /// decisions は要素ごとにデコードし、未知の値・未判定は捨てる（全体を失敗させない）。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        // 値・要素ごとにデコードし、壊れたもの（数値・null など）は捨てる。decisions / applied 自体の型が違えば全体を失敗させる
        let raw = try c.decodeIfPresent([String: Lossy<String>].self, forKey: .decisions) ?? [:]
        var d: [String: Decision] = [:]
        for (k, v) in raw {
            if let s = v.value, let dec = Decision(rawValue: s), dec != .undecided { d[k] = dec }
        }
        decisions = d
        applied = (try c.decodeIfPresent([Lossy<ApplyRecord>].self, forKey: .applied) ?? []).compactMap(\.value)
    }
}

/// デコードに失敗したら nil にする（配列・辞書の 1 要素の破損で全体を失わないため）
private struct Lossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}

/// `SessionStore` のエラー
public enum SessionStoreError: Error, Sendable, Equatable, LocalizedError {
    /// 読めない（壊れている）ファイル。`backup` は元ファイルの退避先（退避できなければ nil）
    case corrupted(backup: URL?, detail: String)
    /// 新しい版のアプリが書いたファイルなので、上書き保存しない
    case unsupportedVersion(found: Int, supported: Int)

    public var errorDescription: String? {
        switch self {
        case .corrupted(let backup, let detail):
            if let backup {
                return "\(SessionStore.fileName) を読めませんでした（\(detail)）。元のファイルを \(backup.lastPathComponent) に退避しました。"
            }
            return "\(SessionStore.fileName) を読めませんでした（\(detail)）。元のファイルの退避にも失敗しました。"
        case .unsupportedVersion(let found, let supported):
            return "\(SessionStore.fileName) は新しい版（version \(found)）で作られているため、この版（version \(supported)）では保存しません。"
        }
    }
}

/// 開いたフォルダ直下の `.photopicker.json` の読み書き
public struct SessionStore: Sendable {
    public static let fileName = ".photopicker.json"

    public let folder: URL

    public init(folder: URL) {
        self.folder = folder
    }

    public var fileURL: URL { folder.appendingPathComponent(Self.fileName) }

    private struct VersionProbe: Decodable { var version: Int? }

    private func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// 読み込む。ファイルが無ければ空のデータを返す。
    ///
    /// - 読めない（JSON として壊れている）ときは、元のファイルを `.photopicker.json.broken-<yyyyMMdd-HHmmss>` に
    ///   コピーして退避し、`SessionStoreError.corrupted`（退避先を含む）を投げる。
    /// - `version > currentVersion` のファイルは、読める範囲で読む（読めなくても空の `SessionData(version:)` を返す）。
    ///   `save` はこのファイルを上書きしない。
    public func load() throws -> SessionData {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return SessionData() }
        let data = try Data(contentsOf: fileURL)
        let decoder = makeDecoder()
        let probeVersion = (try? decoder.decode(VersionProbe.self, from: data))?.version
        do {
            return try decoder.decode(SessionData.self, from: data)
        } catch {
            if let v = probeVersion, v > SessionData.currentVersion {
                return SessionData(version: v)
            }
            let backup = backupBrokenFile()
            throw SessionStoreError.corrupted(backup: backup, detail: Self.describe(error))
        }
    }

    /// アトミックに書き込む。
    /// 保存しようとするデータ、またはディスク上の既存ファイルが `currentVersion` より新しければ
    /// `SessionStoreError.unsupportedVersion` を投げて書かない。
    public func save(_ session: SessionData) throws {
        if session.version > SessionData.currentVersion {
            throw SessionStoreError.unsupportedVersion(found: session.version, supported: SessionData.currentVersion)
        }
        if let existing = try? Data(contentsOf: fileURL),
           let v = (try? makeDecoder().decode(VersionProbe.self, from: existing))?.version,
           v > SessionData.currentVersion {
            throw SessionStoreError.unsupportedVersion(found: v, supported: SessionData.currentVersion)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(session)
        try data.write(to: fileURL, options: .atomic)
    }

    // MARK: - 内部

    private func backupBrokenFile() -> URL? {
        let fm = FileManager.default
        // 同じ内容の退避ファイルが既にあれば、新たに作らずそれを返す（開くたびに増えるのを防ぐ）
        let prefix = "\(Self.fileName).broken-"
        if let current = try? Data(contentsOf: fileURL),
           let names = try? fm.contentsOfDirectory(atPath: folder.path) {
            for name in names.sorted() where name.hasPrefix(prefix) {
                let url = folder.appendingPathComponent(name)
                if let old = try? Data(contentsOf: url), old == current { return url }
            }
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = f.string(from: Date())
        var dest = folder.appendingPathComponent("\(Self.fileName).broken-\(stamp)")
        var n = 2
        while fm.fileExists(atPath: dest.path) {
            dest = folder.appendingPathComponent("\(Self.fileName).broken-\(stamp)-\(n)")
            n += 1
        }
        do {
            try fm.copyItem(at: fileURL, to: dest)
            return dest
        } catch {
            return nil
        }
    }

    private static func describe(_ error: Error) -> String {
        if let e = error as? DecodingError {
            switch e {
            case .dataCorrupted: return "JSON として不正です"
            case .keyNotFound(let k, _): return "項目 \(k.stringValue) がありません"
            case .typeMismatch(_, let c), .valueNotFound(_, let c):
                return "型が合いません（\(c.codingPath.map(\.stringValue).joined(separator: "."))）"
            @unknown default: return "形式が不正です"
            }
        }
        return error.localizedDescription
    }
}
