import Foundation

/// 情報パネルの 1 行（項目名と値）
public struct PhotoInfoRow: Sendable, Hashable, Identifiable {
    public var id: String { label }
    public let label: String
    public let value: String

    public init(label: String, value: String) {
        self.label = label
        self.value = value
    }
}

/// 情報パネルの見出し付きのまとまり（`{Exif}` などの辞書 1 つ）
public struct PhotoInfoSection: Sendable, Hashable, Identifiable {
    public var id: String { title }
    public let title: String
    public let rows: [PhotoInfoRow]

    public init(title: String, rows: [PhotoInfoRow]) {
        self.title = title
        self.rows = rows
    }
}

/// 1 枚の写真の情報。ImageIO のプロパティ辞書（`CGImageSourceCopyPropertiesAtIndex`）から作る
public struct PhotoInfo: Sendable, Hashable {
    /// 上段に出す主要項目（機種・レンズ・露出など）
    public let summary: [PhotoInfoRow]
    /// 全タグ。辞書ごとのまとまり
    public let sections: [PhotoInfoSection]

    public init(summary: [PhotoInfoRow], sections: [PhotoInfoSection]) {
        self.summary = summary
        self.sections = sections
    }

    /// 値が長すぎる行（配列など）はここで切る
    static let maxValueLength = 240

    /// まとまりの並び順。これ以外の辞書は名前順で後ろに並べる
    static let sectionOrder = ["{TIFF}", "{Exif}", "{ExifAux}", "{GPS}", "{IPTC}", "{JFIF}"]

    /// ImageIO のプロパティ辞書から作る。辞書でない最上位の値は「ファイル」のまとまりに入れる
    public init(properties: [String: Any]) {
        self.summary = Self.makeSummary(properties)

        var sections: [PhotoInfoSection] = []
        let fileRows = properties.filter { !($0.value is [String: Any]) }
            .map { PhotoInfoRow(label: $0.key, value: Self.format($0.value)) }
            .sorted { $0.label < $1.label }
        if !fileRows.isEmpty { sections.append(PhotoInfoSection(title: "ファイル", rows: fileRows)) }

        let dictionaries = properties.compactMap { key, value in
            (value as? [String: Any]).map { (key, $0) }
        }.sorted { a, b in
            let ia = Self.sectionOrder.firstIndex(of: a.0) ?? Int.max
            let ib = Self.sectionOrder.firstIndex(of: b.0) ?? Int.max
            return ia != ib ? ia < ib : a.0 < b.0
        }
        for (key, dict) in dictionaries {
            let rows = dict.map { PhotoInfoRow(label: $0.key, value: Self.format($0.value)) }
                .sorted { $0.label < $1.label }
            guard !rows.isEmpty else { continue }
            let title = key.trimmingCharacters(in: CharacterSet(charactersIn: "{}"))
            sections.append(PhotoInfoSection(title: title, rows: rows))
        }
        self.sections = sections
    }

    // MARK: 主要項目

    private static func makeSummary(_ p: [String: Any]) -> [PhotoInfoRow] {
        let tiff = p["{TIFF}"] as? [String: Any] ?? [:]
        let exif = p["{Exif}"] as? [String: Any] ?? [:]
        let aux = p["{ExifAux}"] as? [String: Any] ?? [:]
        var rows: [PhotoInfoRow] = []
        func add(_ label: String, _ value: String?) {
            if let value, !value.isEmpty { rows.append(PhotoInfoRow(label: label, value: value)) }
        }

        let make = (tiff["Make"] as? String)?.trimmingCharacters(in: .whitespaces)
        let model = (tiff["Model"] as? String)?.trimmingCharacters(in: .whitespaces)
        add("機種", [make, model].compactMap { $0 }.joined(separator: " "))
        add("レンズ", (exif["LensModel"] as? String) ?? (aux["LensModel"] as? String))
        add("撮影日時", captureDate(exif))
        add("シャッター速度", (exif["ExposureTime"] as? Double).map(shutterSpeed))
        add("絞り", (exif["FNumber"] as? Double).map { "f/\(number($0))" })
        add("ISO", (exif["ISOSpeedRatings"] as? [Int])?.first.map(String.init))
        add("焦点距離", focalLength(exif))
        add("露出補正", (exif["ExposureBiasValue"] as? Double).map(exposureBias))
        add("露出モード", (exif["ExposureProgram"] as? Int).flatMap { exposurePrograms[$0] })
        add("測光モード", (exif["MeteringMode"] as? Int).flatMap { meteringModes[$0] })
        if let w = p["PixelWidth"] as? Int, let h = p["PixelHeight"] as? Int {
            add("画像サイズ", "\(w) × \(h)")
        }
        return rows
    }

    private static func captureDate(_ exif: [String: Any]) -> String? {
        guard var text = exif["DateTimeOriginal"] as? String else { return nil }
        if let sub = exif["SubsecTimeOriginal"] as? String, !sub.isEmpty { text += ".\(sub)" }
        if let offset = exif["OffsetTimeOriginal"] as? String, !offset.isEmpty { text += " \(offset)" }
        return text
    }

    /// 1 秒未満は 1/n 秒、それ以上は小数の秒
    static func shutterSpeed(_ seconds: Double) -> String {
        guard seconds > 0 else { return number(seconds) }
        if seconds < 1 {
            let denominator = 1 / seconds
            // 1/3 秒などの割り切れない値は小数第 1 位まで
            let rounded = denominator.rounded()
            return abs(denominator - rounded) < 0.05 ? "1/\(Int(rounded)) 秒" : "1/\(number(denominator, digits: 1)) 秒"
        }
        return "\(number(seconds, digits: 1)) 秒"
    }

    static func exposureBias(_ ev: Double) -> String {
        if abs(ev) < 0.005 { return "0 EV" }
        return (ev > 0 ? "+" : "") + number(ev, digits: 2) + " EV"
    }

    private static func focalLength(_ exif: [String: Any]) -> String? {
        guard let mm = exif["FocalLength"] as? Double else { return nil }
        var text = "\(number(mm)) mm"
        if let full = exif["FocalLenIn35mmFilm"] as? Int, full > 0, Double(full) != mm {
            text += "（35mm 判 \(full) mm）"
        }
        return text
    }

    static let exposurePrograms: [Int: String] = [
        1: "マニュアル", 2: "プログラム", 3: "絞り優先", 4: "シャッター優先",
        5: "クリエイティブ", 6: "アクション", 7: "ポートレート", 8: "風景",
    ]

    static let meteringModes: [Int: String] = [
        1: "平均", 2: "中央重点", 3: "スポット", 4: "マルチスポット", 5: "マルチパターン", 6: "部分",
    ]

    // MARK: 値の文字列化

    /// ImageIO が返す値（数値・文字列・配列・辞書・Data）を 1 行の文字列にする
    static func format(_ value: Any) -> String {
        let text: String
        switch value {
        case let s as String: text = s
        case let n as NSNumber: text = number(n.doubleValue)
        case let a as [Any]: text = a.map(format).joined(separator: ", ")
        case let d as [String: Any]:
            text = d.sorted { $0.key < $1.key }.map { "\($0.key)=\(format($0.value))" }.joined(separator: "; ")
        case let data as Data: text = "\(data.count) バイト"
        default: text = String(describing: value)
        }
        guard text.count > maxValueLength else { return text }
        return String(text.prefix(maxValueLength)) + "…"
    }

    /// 整数ならそのまま、小数なら最大 `digits` 桁（末尾の 0 は落とす）
    static func number(_ value: Double, digits: Int = 4) -> String {
        if value == value.rounded(), abs(value) < 1e15 { return String(Int(value)) }
        return value.formatted(.number.precision(.fractionLength(0...digits)).grouping(.never)
            .locale(Locale(identifier: "en_US_POSIX")))
    }
}

extension PhotoMetadata {
    /// ImageIO では読めない Sony MakerNote の値（自前パーサーで読んだもの）
    public var sonyInfoRows: [PhotoInfoRow] {
        var rows: [PhotoInfoRow] = []
        if let mode = releaseMode {
            let name = [0: "単写", 2: "連写"][mode].map { "\($0)（\(mode)）" } ?? "\(mode)"
            rows.append(PhotoInfoRow(label: "ReleaseMode", value: name))
        }
        if let seq = sequenceNumber {
            rows.append(PhotoInfoRow(label: "SequenceNumber", value: "\(seq)"))
        }
        if let f = focusLocation {
            rows.append(PhotoInfoRow(label: "FocusLocation", value: "\(f.width) \(f.height) \(f.x) \(f.y)"))
        }
        if let s = focusFrameSize {
            rows.append(PhotoInfoRow(label: "FocusFrameSize",
                                     value: "\(s.width) × \(s.height)（\(s.isValid ? "有効" : "無効")）"))
        }
        return rows
    }
}
