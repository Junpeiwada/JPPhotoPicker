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

/// `.jpphotopicker.json` の中身
public struct SessionData: Sendable, Codable, Equatable {
    public var version: Int
    /// コマ ID（ファイル名）→ 判定。採用していない（不採用）コマは持たない
    public var decisions: [String: Decision]
    /// 適用の記録（古い順）
    public var applied: [ApplyRecord]
    /// 最後に見ていたコマ ID（再開位置）。古いファイルには無い（nil）。nil なら書き出さない
    public var lastViewedID: String?

    public static let currentVersion = 1

    public init(version: Int = SessionData.currentVersion,
                decisions: [String: Decision] = [:],
                applied: [ApplyRecord] = [],
                lastViewedID: String? = nil) {
        self.version = version
        self.decisions = decisions
        self.applied = applied
        self.lastViewedID = lastViewedID
    }

    private enum CodingKeys: String, CodingKey { case version, decisions, applied, lastViewedID }

    /// decisions は要素ごとにデコードし、未知の値・採用していない（不採用）値は捨てる（全体を失敗させない）。
    /// 以前の版が書いた `rejected` も未知の値として捨てる（採用していないコマと同じ扱いになる）。
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
        // 再開位置は無くても・壊れていても困らないので、読めなければ nil
        lastViewedID = try? c.decodeIfPresent(String.self, forKey: .lastViewedID)
    }
}

/// `SessionData` のデコードと同時に、読めずに捨てた適用の記録の件数を数える
private struct SessionDataWithDropCount: Decodable {
    let session: SessionData
    let droppedAppliedCount: Int

    private enum CodingKeys: String, CodingKey { case applied }

    init(from decoder: Decoder) throws {
        session = try SessionData(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try c.decodeIfPresent([Lossy<ApplyRecord>].self, forKey: .applied) ?? []
        droppedAppliedCount = raw.count - session.applied.count
    }
}

/// `SessionStore.loadWithReport()` の結果
public struct SessionLoadResult: Sendable, Equatable {
    public let session: SessionData
    /// 壊れていて読めずに捨てた適用の記録（`applied` の要素）の件数。0 なら捨てていない
    public let droppedAppliedCount: Int
    /// 捨てた記録があったときの、元のファイルの退避先（`.jpphotopicker.json.broken-…`）。
    /// 捨てていない・新しい版のファイル（上書き保存しないので退避しない）・退避に失敗したときは nil
    public let backup: URL?
    /// 捨てた記録があったのに、元のファイルを退避できなかった。このまま保存すると記録が永久に失われるので、
    /// 呼び出し側は保存しない（読み取り専用で開く）こと
    public let backupFailed: Bool

    init(session: SessionData, droppedAppliedCount: Int, backup: URL?, backupFailed: Bool = false) {
        self.session = session
        self.droppedAppliedCount = droppedAppliedCount
        self.backup = backup
        self.backupFailed = backupFailed
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

/// 開いたフォルダ直下の `.jpphotopicker.json` の読み書き
public struct SessionStore: Sendable {
    public static let fileName = ".jpphotopicker.json"

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

    /// 読み込む（`loadWithReport()` の `session` だけを返す）。ファイルが無ければ空のデータを返す。
    /// 壊れた適用の記録を捨てたときも原本は退避される。捨てた件数を知りたいときは `loadWithReport()` を使う。
    /// 退避に失敗したときは、呼び出し側が保存して記録を失わないよう `SessionStoreError.corrupted(backup: nil, …)` を投げる。
    public func load() throws -> SessionData {
        let r = try loadWithReport()
        if r.backupFailed {
            throw SessionStoreError.corrupted(backup: nil, detail: "適用の記録 \(r.droppedAppliedCount) 件が壊れています")
        }
        return r.session
    }

    /// 読み込む。ファイルが無ければ空のデータを返す。
    ///
    /// - 読めない（JSON として壊れている）ときは、元のファイルを `.jpphotopicker.json.broken-<yyyyMMdd-HHmmss>` に
    ///   コピーして退避し、`SessionStoreError.corrupted`（退避先を含む）を投げる。
    /// - 壊れた適用の記録（`applied` の要素）は捨てて読むが、次の保存で永久に消えないよう、1 件でも捨てたら
    ///   元のファイルを同じ名前の規則で退避し、件数と退避先を結果に入れる。退避できなかったときも読めた内容
    ///   （判定など）は返し、`backupFailed` を true にする（呼び出し側は保存しないこと。保存すると記録が失われる）。
    /// - `version > currentVersion` のファイルは、読める範囲で読む（読めなくても空の `SessionData(version:)` を返す）。
    ///   `save` はこのファイルを上書きしないので、記録を捨てても退避はしない。
    public func loadWithReport() throws -> SessionLoadResult {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return SessionLoadResult(session: SessionData(), droppedAppliedCount: 0, backup: nil)
        }
        let data = try Data(contentsOf: fileURL)
        let decoder = makeDecoder()
        let probeVersion = (try? decoder.decode(VersionProbe.self, from: data))?.version
        let decoded: SessionDataWithDropCount
        do {
            decoded = try decoder.decode(SessionDataWithDropCount.self, from: data)
        } catch {
            if let v = probeVersion, v > SessionData.currentVersion {
                return SessionLoadResult(session: SessionData(version: v), droppedAppliedCount: 0, backup: nil)
            }
            let backup = backupBrokenFile()
            throw SessionStoreError.corrupted(backup: backup, detail: Self.describe(error))
        }
        let dropped = decoded.droppedAppliedCount
        guard dropped > 0, decoded.session.version <= SessionData.currentVersion else {
            return SessionLoadResult(session: decoded.session, droppedAppliedCount: dropped, backup: nil)
        }
        guard let backup = backupBrokenFile() else {
            return SessionLoadResult(session: decoded.session, droppedAppliedCount: dropped, backup: nil, backupFailed: true)
        }
        return SessionLoadResult(session: decoded.session, droppedAppliedCount: dropped, backup: backup)
    }

    /// アトミックに書き込む。
    /// 保存しようとするデータ、またはディスク上の既存ファイルが `currentVersion` より新しければ
    /// `SessionStoreError.unsupportedVersion` を投げて書かない。古い version（0 など）は `currentVersion` にそろえて書く。
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
        var normalized = session
        normalized.version = max(session.version, SessionData.currentVersion)
        let data = try encoder.encode(normalized)
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
        let dest = FileSafety.brokenDestination(for: Self.fileName, in: folder)
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
