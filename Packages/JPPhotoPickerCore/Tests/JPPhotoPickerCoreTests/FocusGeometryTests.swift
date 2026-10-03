import Testing
import Foundation
@testable import JPPhotoPickerCore

@Suite("FocusGeometry")
struct FocusGeometryTests {
    private func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 }

    @Test("Orientation 1〜8 の座標変換", arguments: [
        // (orientation, 入力 (0.25, 0.75) の期待値)
        (1, 0.25, 0.75), (2, 0.75, 0.75), (3, 0.75, 0.25), (4, 0.25, 0.25),
        (5, 0.75, 0.25), (6, 0.25, 0.25), (7, 0.25, 0.75), (8, 0.75, 0.75),
    ])
    func transform(o: Int, ex: Double, ey: Double) {
        let p = FocusGeometry.transform(NormalizedPoint(x: 0.25, y: 0.75), orientation: o)
        #expect(near(p.x, ex) && near(p.y, ey), "orientation \(o): \(p)")
    }

    @Test("Orientation 8 は (x,y)→(y,1−x)、6 は (1−y,x)")
    func orientation8And6() {
        let p8 = FocusGeometry.transform(NormalizedPoint(x: 0.2, y: 0.9), orientation: 8)
        #expect(near(p8.x, 0.9) && near(p8.y, 0.8))
        let p6 = FocusGeometry.transform(NormalizedPoint(x: 0.2, y: 0.9), orientation: 6)
        #expect(near(p6.x, 0.1) && near(p6.y, 0.2))
    }

    @Test("A1_01309（Orientation 8）")
    func sample01309() {
        let g = FocusGeometry(
            location: FocusLocation(width: 8640, height: 4864, x: 4563, y: 2918),
            frameSize: FocusFrameSize(width: 189, height: 193, flag: 257), orientation: 8)
        #expect(g.hasFocusPosition)
        #expect(near(g.center.x, 2918.0 / 4864))
        #expect(near(g.center.y, 1 - 4563.0 / 8640))
        // 縦位置なので幅と高さを入れ替える
        let f = g.frameSize!
        #expect(near(f.width, 193.0 / 4864))
        #expect(near(f.height, 189.0 / 8640))
    }

    @Test("A1_07913（Orientation 1）")
    func sample07913() {
        let g = FocusGeometry(
            location: FocusLocation(width: 8640, height: 4864, x: 5805, y: 2452),
            frameSize: FocusFrameSize(width: 891, height: 392, flag: 257), orientation: 1)
        #expect(near(g.center.x, 5805.0 / 8640) && near(g.center.y, 2452.0 / 4864))
        #expect(near(g.frameSize!.width, 891.0 / 8640) && near(g.frameSize!.height, 392.0 / 4864))
    }

    @Test("枠が無効（3番目が0）なら中心・枠なし")
    func invalidFrame() {
        let g = FocusGeometry(
            location: FocusLocation(width: 8640, height: 4864, x: 4333, y: 2442),
            frameSize: FocusFrameSize(width: 6804, height: 4783, flag: 0), orientation: 1)
        #expect(g == .centered)
        #expect(!g.hasFocusPosition && g.frameSize == nil)
        #expect(g.center == NormalizedPoint(x: 0.5, y: 0.5))
    }

    @Test("FocusLocation が無ければ中心・枠なし")
    func noLocation() {
        let g = FocusGeometry(location: nil,
                              frameSize: FocusFrameSize(width: 10, height: 10, flag: 257), orientation: 6)
        #expect(g == .centered)
    }

    @Test("メタデータから作る")
    func fromMetadata() {
        let m = PhotoMetadata(orientation: 3,
                              focusLocation: FocusLocation(width: 100, height: 50, x: 10, y: 10),
                              focusFrameSize: FocusFrameSize(width: 20, height: 10, flag: 257))
        let g = FocusGeometry(metadata: m)
        #expect(near(g.center.x, 0.9) && near(g.center.y, 0.8))
        #expect(near(g.frameSize!.width, 0.2) && near(g.frameSize!.height, 0.2))
    }

    @Test("サンプルの A1_04911 は枠なし・中心", .enabled(if: sampleAvailable))
    func sampleInterval() throws {
        let m = try JPEGMetadataReader.read(url: sampleFolder.appendingPathComponent("A1_04911.JPG"))
        #expect(FocusGeometry(metadata: m) == .centered)
    }
}
