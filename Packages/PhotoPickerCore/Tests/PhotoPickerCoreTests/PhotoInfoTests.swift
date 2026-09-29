import Testing
import Foundation
@testable import PhotoPickerCore

@Suite struct PhotoInfoTests {
    /// ImageIO が返す形に近い辞書（値は NSNumber / NSString / NSArray で来る）
    private let properties: [String: Any] = [
        "PixelWidth": NSNumber(value: 8640),
        "PixelHeight": NSNumber(value: 5760),
        "Orientation": NSNumber(value: 1),
        "{TIFF}": ["Make": "SONY", "Model": "ILCE-1M2 "] as [String: Any],
        "{Exif}": [
            "ExposureTime": NSNumber(value: 0.0005),
            "FNumber": NSNumber(value: 5.6),
            "ISOSpeedRatings": [NSNumber(value: 800)],
            "FocalLength": NSNumber(value: 400),
            "FocalLenIn35mmFilm": NSNumber(value: 400),
            "ExposureBiasValue": NSNumber(value: -0.3),
            "ExposureProgram": NSNumber(value: 3),
            "MeteringMode": NSNumber(value: 5),
            "DateTimeOriginal": "2026:05:03 10:12:34",
            "SubsecTimeOriginal": "123",
            "OffsetTimeOriginal": "+09:00",
            "LensModel": "FE 400mm F2.8 GM OSS",
        ] as [String: Any],
        "{GPS}": ["Latitude": NSNumber(value: 35.5)] as [String: Any],
        "{MakerFoo}": ["X": NSNumber(value: 1)] as [String: Any],
    ]

    @Test func summaryHasMainItems() {
        let info = PhotoInfo(properties: properties)
        let rows = Dictionary(uniqueKeysWithValues: info.summary.map { ($0.label, $0.value) })
        #expect(rows["機種"] == "SONY ILCE-1M2")
        #expect(rows["レンズ"] == "FE 400mm F2.8 GM OSS")
        #expect(rows["撮影日時"] == "2026:05:03 10:12:34.123 +09:00")
        #expect(rows["シャッター速度"] == "1/2000 秒")
        #expect(rows["絞り"] == "f/5.6")
        #expect(rows["ISO"] == "800")
        #expect(rows["焦点距離"] == "400 mm")   // 35mm 判と同じなら重ねて書かない
        #expect(rows["露出補正"] == "-0.3 EV")
        #expect(rows["露出モード"] == "絞り優先")
        #expect(rows["測光モード"] == "マルチパターン")
        #expect(rows["画像サイズ"] == "8640 × 5760")
        #expect(info.summary.first?.label == "機種")
    }

    @Test func sectionsListAllTagsInOrder() {
        let info = PhotoInfo(properties: properties)
        #expect(info.sections.map(\.title) == ["ファイル", "TIFF", "Exif", "GPS", "MakerFoo"])
        #expect(info.sections[0].rows.map(\.label) == ["Orientation", "PixelHeight", "PixelWidth"])
        #expect(info.sections[2].rows.count == 12)
        #expect(info.sections[2].rows.first { $0.label == "ISOSpeedRatings" }?.value == "800")
    }

    @Test func emptyPropertiesGiveEmptyInfo() {
        let info = PhotoInfo(properties: [:])
        #expect(info.summary.isEmpty)
        #expect(info.sections.isEmpty)
    }

    @Test func shutterSpeedFormats() {
        #expect(PhotoInfo.shutterSpeed(1.0 / 250) == "1/250 秒")
        #expect(PhotoInfo.shutterSpeed(0.3) == "1/3.3 秒")
        #expect(PhotoInfo.shutterSpeed(2.5) == "2.5 秒")
        #expect(PhotoInfo.shutterSpeed(30) == "30 秒")
    }

    @Test func exposureBiasFormats() {
        #expect(PhotoInfo.exposureBias(0) == "0 EV")
        #expect(PhotoInfo.exposureBias(0.7) == "+0.7 EV")
        #expect(PhotoInfo.exposureBias(-1.33) == "-1.33 EV")
    }

    @Test func formatHandlesVariousValues() {
        #expect(PhotoInfo.format([NSNumber(value: 1), NSNumber(value: 2.5)]) == "1, 2.5")
        #expect(PhotoInfo.format(["b": NSNumber(value: 2), "a": "x"] as [String: Any]) == "a=x; b=2")
        #expect(PhotoInfo.format(Data(count: 10)) == "10 バイト")
        let long = PhotoInfo.format(Array(repeating: NSNumber(value: 123), count: 200))
        #expect(long.count == PhotoInfo.maxValueLength + 1)
        #expect(long.hasSuffix("…"))
    }

    @Test func sonyRows() {
        let m = PhotoMetadata(releaseMode: 2, sequenceNumber: 3,
                              focusLocation: FocusLocation(width: 8640, height: 5760, x: 100, y: 200),
                              focusFrameSize: FocusFrameSize(width: 300, height: 200, flag: 257))
        #expect(m.sonyInfoRows.map(\.value) == ["連写（2）", "3", "8640 5760 100 200", "300 × 200（有効）"])
        #expect(PhotoMetadata().sonyInfoRows.isEmpty)
    }
}
