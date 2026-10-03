import Testing
@testable import JPPhotoPickerCore

@Suite("表示する画像の選択（DisplaySelection）")
struct DisplaySelectionTests {
    private func fit(body: Bool = false, screen: Bool = false, current: Bool = true, preview: Bool = false,
                     screenFailed: Bool = false) -> DisplaySelection {
        DisplaySelection.choose(isFit: true, hasBody: body, hasScreen: screen, screenIsCurrent: current,
                                hasPreview: preview, screenFailed: screenFailed, bodyFailed: false)
    }

    private func zoomed(body: Bool = false, screen: Bool = false, preview: Bool = false,
                        bodyFailed: Bool = false) -> DisplaySelection {
        DisplaySelection.choose(isFit: false, hasBody: body, hasScreen: screen, screenIsCurrent: true,
                                hasPreview: preview, screenFailed: false, bodyFailed: bodyFailed)
    }

    @Test("全体表示: 全体表示用があれば最高画質")
    func fitBest() {
        #expect(fit(screen: true, preview: true) == DisplaySelection(source: .screen, quality: .best))
    }

    @Test("全体表示: 本体があっても使わない（全体表示用が最高画質）")
    func fitIgnoresBody() {
        #expect(fit(body: true, preview: true) == DisplaySelection(source: .preview, quality: .loading))
    }

    @Test("全体表示: 大きさ違いの古い全体表示用は出すが、読み込み中")
    func fitStaleScreen() {
        #expect(fit(screen: true, current: false, preview: true) == DisplaySelection(source: .screen, quality: .loading))
    }

    @Test("全体表示: 作れなかったら大プレビューのまま、劣化として扱う")
    func fitFailed() {
        #expect(fit(preview: true, screenFailed: true) == DisplaySelection(source: .preview, quality: .degraded))
    }

    @Test("全体表示: 何も無いときは none")
    func fitNone() {
        #expect(fit() == DisplaySelection(source: .none, quality: .loading))
    }

    @Test("拡大: 本体があれば最高画質")
    func zoomBest() {
        #expect(zoomed(body: true, screen: true, preview: true) == DisplaySelection(source: .body, quality: .best))
    }

    @Test("拡大: 本体ができるまでは全体表示用、無ければ大プレビュー")
    func zoomFallback() {
        #expect(zoomed(screen: true, preview: true) == DisplaySelection(source: .screen, quality: .loading))
        #expect(zoomed(preview: true) == DisplaySelection(source: .preview, quality: .loading))
    }

    @Test("拡大: 本体を作れなかったら劣化")
    func zoomFailed() {
        #expect(zoomed(screen: true, bodyFailed: true) == DisplaySelection(source: .screen, quality: .degraded))
    }
}
