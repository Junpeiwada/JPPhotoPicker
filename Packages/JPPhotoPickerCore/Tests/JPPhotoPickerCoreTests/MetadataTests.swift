import Testing
import Foundation
@testable import JPPhotoPickerCore

@Suite("メタデータ読み取り")
struct MetadataTests {
    @Test("サンプル49枚が exiftool の実測値と一致する", .enabled(if: sampleAvailable))
    func allSamplesMatchExiftool() throws {
        #expect(sampleTable.count == 49)
        for e in sampleTable {
            let url = sampleFolder.appendingPathComponent(e.name + ".JPG")
            let m = try JPEGMetadataReader.read(url: url)
            #expect(m.orientation == e.orientation, "\(e.name) orientation")
            #expect(m.releaseMode == e.releaseMode, "\(e.name) releaseMode")
            #expect(m.sequenceNumber == e.seq, "\(e.name) seq")
            #expect(m.focusLocation == FocusLocation(width: e.focusLocation[0], height: e.focusLocation[1],
                                                    x: e.focusLocation[2], y: e.focusLocation[3]), "\(e.name) focusLocation")
            #expect(m.focusFrameSize == FocusFrameSize(width: e.frameSize[0], height: e.frameSize[1],
                                                      flag: e.frameSize[2]), "\(e.name) frameSize")
            #expect(m.thumbnail == FileRange(offset: e.thumbOffset, length: e.thumbLength), "\(e.name) thumbnail")
            #expect(m.mpfPreview == FileRange(offset: e.mpfOffset, length: e.mpfLength), "\(e.name) mpf")
            #expect(m.imageWidth == 8640 && m.imageHeight == 4864, "\(e.name) size")
            let t = try #require(m.captureDate, "\(e.name) date")
            #expect(abs(t.timeIntervalSince1970 - e.time) < 0.0005, "\(e.name) date")
        }
    }

    @Test("代表的なファイルの値", .enabled(if: sampleAvailable))
    func representativeFiles() throws {
        let a = try JPEGMetadataReader.read(url: sampleFolder.appendingPathComponent("A1_07913.JPG"))
        #expect(a.releaseMode == 2 && a.sequenceNumber == 1)
        #expect(a.focusLocation == FocusLocation(width: 8640, height: 4864, x: 5805, y: 2452))
        #expect(a.focusFrameSize == FocusFrameSize(width: 891, height: 392, flag: 257))
        #expect(a.isBurstFrame)
        #expect(a.mpfPreview == FileRange(offset: 7_299_072, length: 106_072))

        let b = try JPEGMetadataReader.read(url: sampleFolder.appendingPathComponent("A1_01309.JPG"))
        #expect(b.orientation == 8)
        #expect(b.focusLocation == FocusLocation(width: 8640, height: 4864, x: 4563, y: 2918))

        let c = try JPEGMetadataReader.read(url: sampleFolder.appendingPathComponent("A1_04911.JPG"))
        #expect(c.releaseMode == 0 && c.sequenceNumber == 0)
        #expect(c.focusFrameSize == FocusFrameSize(width: 0, height: 0, flag: 0))
        #expect(!c.isBurstFrame)
    }

    @Test("サムネイルと MPF プレビューの位置が JPEG（SOI）を指している", .enabled(if: sampleAvailable))
    func rangesPointToJPEG() throws {
        let url = sampleFolder.appendingPathComponent("A1_07913.JPG")
        let m = try JPEGMetadataReader.read(url: url)
        for r in [try #require(m.thumbnail), try #require(m.mpfPreview)] {
            let d = try r.readData(from: url)
            #expect(d.count == r.length)
            #expect(d[d.startIndex] == 0xFF && d[d.startIndex + 1] == 0xD8)
            #expect(d[d.endIndex - 2] == 0xFF && d[d.endIndex - 1] == 0xD9)
        }
    }

    @Test("先頭 128KB だけで解析できる", .enabled(if: sampleAvailable))
    func parsesFromPrefixOnly() throws {
        let url = sampleFolder.appendingPathComponent("A1_07913.JPG")
        let h = try FileHandle(forReadingFrom: url)
        let prefix = try #require(try h.read(upToCount: 128 * 1024))
        let m = try JPEGMetadataReader.parse(prefix: prefix)
        #expect(m.sequenceNumber == 1)
        #expect(m.mpfPreview?.length == 106_072)
    }

    @Test("JPEG でないデータはエラー")
    func notJPEG() {
        #expect(throws: MetadataError.notJPEG) {
            _ = try JPEGMetadataReader.parse(prefix: Data([0x00, 0x01, 0x02, 0x03, 0x04]))
        }
    }

    @Test("日付の解析（オフセットあり・ミリ秒）")
    func dateParsing() throws {
        let d = try #require(JPEGMetadataReader.parseDate("2026:09:27 08:32:00", subSec: "761", offset: "+09:00"))
        // 2026-09-26T23:32:00.761Z
        #expect(abs(d.timeIntervalSince1970 - 1_790_465_520.761) < 0.0005)
        let d2 = try #require(JPEGMetadataReader.parseDate("2026:09:27 08:32:00", subSec: nil, offset: "-05:30"))
        // 08:32:00-05:30 = 14:02:00Z（+09:00 の同時刻より 14.5 時間後）
        #expect(abs(d2.timeIntervalSince1970 - (1_790_465_520 + 52_200)) < 0.0005)
        #expect(JPEGMetadataReader.parseDate("garbage", subSec: nil, offset: nil) == nil)
    }

    @Test("表示向きの画素サイズ: Orientation 5〜8 は縦横を入れ替え、サイズが無ければ nil")
    func displayPixelSize() {
        for o in 1...8 {
            let m = PhotoMetadata(orientation: o, imageWidth: 6000, imageHeight: 4000)
            let expected = (5...8).contains(o) ? CGSize(width: 4000, height: 6000) : CGSize(width: 6000, height: 4000)
            #expect(m.displayPixelSize == expected, "orientation \(o)")
        }
        #expect(PhotoMetadata(orientation: 6, imageWidth: 6000).displayPixelSize == nil)
        #expect(PhotoMetadata(imageWidth: 0, imageHeight: 4000).displayPixelSize == nil)
        #expect(PhotoMetadata(imageWidth: 6000, imageHeight: -1).displayPixelSize == nil)
    }
}
