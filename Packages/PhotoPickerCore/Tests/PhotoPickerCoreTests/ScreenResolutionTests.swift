import Testing
import Foundation
@testable import PhotoPickerCore

@Suite("全体表示用の画像の大きさ（ScreenResolution）")
struct ScreenResolutionTests {
    @Test("ツールバーを引いた領域の長辺を物理ピクセルにし、256 単位で切り上げる")
    func roundsUp() {
        // 1500×952pt、ツールバー 52pt → 1500×900pt → 長辺 3000px → 3072
        #expect(ScreenResolution.maxPixel(viewSize: CGSize(width: 1500, height: 952), topInset: 52, backingScale: 2) == 3072)
    }

    @Test("縦長のウインドウは高さが長辺になる")
    func portrait() {
        #expect(ScreenResolution.maxPixel(viewSize: CGSize(width: 600, height: 1052), topInset: 52, backingScale: 2) == 2048)
    }

    @Test("ちょうど刻みの値は切り上げない")
    func exactStep() {
        #expect(ScreenResolution.maxPixel(viewSize: CGSize(width: 1024, height: 600), topInset: 0, backingScale: 1) == 1024)
    }

    @Test("先読み枚数: キャッシュに収まる分まで絞る")
    func prefetchLimited() {
        // 6144px の 3:2 は約 100MB。800MB に 7 枚 → 今のコマ 1 枚＋前後 3 枚ずつ
        #expect(ScreenResolution.prefetchCount(requested: 12, maxPixel: 6144, cacheLimit: 800 << 20) == 3)
        // 収まるなら頼まれた枚数のまま
        #expect(ScreenResolution.prefetchCount(requested: 2, maxPixel: 6144, cacheLimit: 800 << 20) == 2)
    }

    @Test("先読み枚数: 1 枚も収まらない・頼まれていないときは 0")
    func prefetchZero() {
        #expect(ScreenResolution.prefetchCount(requested: 4, maxPixel: 6144, cacheLimit: 50 << 20) == 0)
        #expect(ScreenResolution.prefetchCount(requested: 0, maxPixel: 2048, cacheLimit: 800 << 20) == 0)
        #expect(ScreenResolution.prefetchCount(requested: 4, maxPixel: 0, cacheLimit: 800 << 20) == 0)
    }

    @Test("領域が無いときは 0")
    func empty() {
        #expect(ScreenResolution.maxPixel(viewSize: .zero, topInset: 0, backingScale: 2) == 0)
        #expect(ScreenResolution.maxPixel(viewSize: CGSize(width: 800, height: 40), topInset: 52, backingScale: 2) == 0)
    }
}
