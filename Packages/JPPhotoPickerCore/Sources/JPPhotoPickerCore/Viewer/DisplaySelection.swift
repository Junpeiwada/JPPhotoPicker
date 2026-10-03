/// どの段階の画像を表示しているか
public enum DisplaySource: Sendable, Equatable {
    case body
    case screen
    case preview
    case none
}

/// 表示中の画像の質
public enum DisplayQuality: Sendable, Equatable {
    /// 最高画質（全体表示は今の大きさの全体表示用、拡大は本体）
    case best
    /// 最高画質を読み込み中（仮の画像を出している）
    case loading
    /// 最高画質を作れなかった（仮の画像のまま。ピントの判断に使えない）
    case degraded
}

/// 手元にある画像から、表示する画像とその質を決める。
/// 全体表示は 全体表示用 → 大プレビュー、拡大は 本体 → 全体表示用 → 大プレビュー の順に、あるものを出す。
public struct DisplaySelection: Sendable, Equatable {
    public let source: DisplaySource
    public let quality: DisplayQuality

    public init(source: DisplaySource, quality: DisplayQuality) {
        self.source = source
        self.quality = quality
    }

    /// - Parameters:
    ///   - screenIsCurrent: 手元の全体表示用の画像が、今のコマ・今の画面の大きさのものか
    ///     （ウインドウの大きさを変えた直後は古い大きさのものを引き伸ばして出す）
    public static func choose(isFit: Bool, hasBody: Bool, hasScreen: Bool, screenIsCurrent: Bool,
                              hasPreview: Bool, screenFailed: Bool, bodyFailed: Bool) -> DisplaySelection {
        if isFit {
            let source: DisplaySource = hasScreen ? .screen : (hasPreview ? .preview : .none)
            let quality: DisplayQuality = (hasScreen && screenIsCurrent) ? .best : (screenFailed ? .degraded : .loading)
            return DisplaySelection(source: source, quality: quality)
        }
        let source: DisplaySource = hasBody ? .body : (hasScreen ? .screen : (hasPreview ? .preview : .none))
        let quality: DisplayQuality = hasBody ? .best : (bodyFailed ? .degraded : .loading)
        return DisplaySelection(source: source, quality: quality)
    }
}
