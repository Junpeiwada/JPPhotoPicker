import Foundation
import CoreGraphics
import CoreImage
import CoreVideo
import ImageIO
import IOSurface
import Synchronization
import JPPhotoPickerCore

/// 画像の取り出し元の種類。ARW だけのファイルは `.arw` の分岐で扱う。
enum ImageSource: Sendable {
    /// JPG（ペアの ARW があっても JPG を使う）
    case jpeg(URL)
    /// ARW だけのファイル（埋め込み JPEG プレビュー / RAW 現像）。
    case arw(URL)

    init(item: PhotoItem) {
        if let jpg = item.jpgURL { self = .jpeg(jpg) } else { self = .arw(item.primaryURL) }
    }
}

/// 画像の段階
enum ImageKind: Hashable, Sendable {
    case thumbnail
    /// MPF / 埋め込み JPEG（1920×1080）。最高画質が出るまでの仮表示
    case preview
    /// 全体表示用。本体を長辺 `maxPixel`（画面の物理ピクセル）に縮小したもの
    case screen(maxPixel: Int)
    /// 本体（フル解像度）
    case body

    /// 種類（`screen` の大きさは区別しない）
    var category: String {
        switch self {
        case .thumbnail: "thumbnail"
        case .preview: "preview"
        case .screen: "screen"
        case .body: "body"
        }
    }

    /// ジョブ・キャッシュのキーの接頭辞（`screen` は大きさ違いを別の画像として扱う）
    var keyPrefix: String {
        if case .screen(let maxPixel) = self { return "screen\(maxPixel)" }
        return category
    }
}

/// 読み込んだ画像。作成後は変更しない。
/// プレビュー・全体表示用・本体は IOSurface に描いて持つ。CGImage をレイヤーに渡すと、
/// Core Animation がコミット時にメインスレッドで色変換・コピーをする（6144px で 1 回 40ms ほど）。
/// IOSurface ならそのまま描画サーバーへ渡り、色の変換も GPU 側で済む。
/// サムネイルはフィルムストリップ（SwiftUI）で使うので CGImage のまま。
final class PipelineImage: @unchecked Sendable {
    let width: Int
    let height: Int
    /// サムネイルのときだけある
    let cgImage: CGImage?
    private let surface: IOSurface?

    init(cgImage: CGImage) {
        self.cgImage = cgImage
        self.surface = nil
        width = cgImage.width
        height = cgImage.height
    }

    init(surface: IOSurface) {
        self.cgImage = nil
        self.surface = surface
        width = surface.width
        height = surface.height
    }

    /// `CALayer.contents` に渡すもの
    var layerContents: Any? { surface ?? cgImage }

    var cost: Int { width * height * 4 }
}

/// デコード 1 件分のジョブ。状態（waiters など）は ImagePipeline のロックの下でだけ触る。
private final class DecodeJob: Operation, @unchecked Sendable {
    let key: String
    let kind: ImageKind
    let item: PhotoItem
    weak var pipeline: ImagePipeline?
    var waiters: [Int: CheckedContinuation<PipelineImage?, Never>] = [:]
    /// 先読みの対象に入っているか
    var prefetchWanted = false

    init(key: String, kind: ImageKind, item: PhotoItem, pipeline: ImagePipeline) {
        self.key = key
        self.kind = kind
        self.item = item
        self.pipeline = pipeline
    }

    override func main() {
        guard !isCancelled else { return }
        let decoded = ImagePipeline.decode(kind, item: item).flatMap { ImagePipeline.prepare($0, kind: kind) }
        pipeline?.finish(self, decoded: decoded)
    }
}

/// サムネイル / 大プレビュー / 全体表示用 / 本体の読み込みとキャッシュ、先読み。
/// - デコードは専用の `OperationQueue`（種類ごとに同時数を制限）で行い、Swift の協調プールを占有しない。
/// - 同じ画像の同時読み込みは 1 つのジョブにまとめる。待つ側のキャンセルは待ちを外すだけで、
///   誰も待たず先読みの対象でもなくなった未着手のジョブは取り消す。
/// - キャッシュはメモリ上だけ（NSCache、コスト = 幅 × 高さ × 4 で上限を付ける）。
final class ImagePipeline: @unchecked Sendable {
    private struct Caches: @unchecked Sendable {
        let thumbnail = NSCache<NSString, PipelineImage>()
        let preview = NSCache<NSString, PipelineImage>()
        let screen = NSCache<NSString, PipelineImage>()
        let body = NSCache<NSString, PipelineImage>()
    }

    private struct State {
        var jobs: [String: DecodeJob] = [:]
        /// 待ち番号 → ジョブのキー
        var waiterKeys: [Int: String] = [:]
        var nextWaiter = 0
    }

    private let caches = Caches()
    private let state = Mutex<State>(State())

    private let thumbnailQueue = ImagePipeline.makeQueue("thumbnail", concurrency: 2)
    private let previewQueue = ImagePipeline.makeQueue("preview", concurrency: 3)
    private let screenQueue = ImagePipeline.makeQueue("screen", concurrency: 2)
    private let bodyQueue = ImagePipeline.makeQueue("body", concurrency: 2)

    /// 全体表示用のキャッシュの上限（バイト）。先読み枚数はこれに収まる分までに絞る
    static let screenCacheLimit = 800 * 1024 * 1024

    init() {
        caches.thumbnail.totalCostLimit = 300 * 1024 * 1024
        caches.preview.totalCostLimit = 400 * 1024 * 1024
        caches.screen.totalCostLimit = Self.screenCacheLimit
        caches.body.totalCostLimit = 1024 * 1024 * 1024
    }

    private static func makeQueue(_ name: String, concurrency: Int) -> OperationQueue {
        let q = OperationQueue()
        q.name = "JPPhotoPicker.decode.\(name)"
        q.maxConcurrentOperationCount = concurrency
        q.qualityOfService = .userInitiated
        return q
    }

    private func queue(_ kind: ImageKind) -> OperationQueue {
        switch kind {
        case .thumbnail: thumbnailQueue
        case .preview: previewQueue
        case .screen: screenQueue
        case .body: bodyQueue
        }
    }

    // MARK: キャッシュ参照（同期。コマ送りの即時表示に使う）

    func cached(_ kind: ImageKind, for item: PhotoItem) -> PipelineImage? {
        cache(kind).object(forKey: Self.cacheKey(kind, item) as NSString)
    }

    /// キャッシュのキー。フォルダが違えば同じファイル名でも別の画像なので、ファイル名（`item.id`）ではなくパスを使う。
    private static func cacheKey(_ item: PhotoItem) -> String {
        item.primaryURL.standardizedFileURL.path
    }

    /// `screen` は大きさ違いを別の画像として持つ
    private static func cacheKey(_ kind: ImageKind, _ item: PhotoItem) -> String {
        if case .screen(let maxPixel) = kind { return "\(maxPixel)|\(cacheKey(item))" }
        return cacheKey(item)
    }

    private func cache(_ kind: ImageKind) -> NSCache<NSString, PipelineImage> {
        switch kind {
        case .thumbnail: caches.thumbnail
        case .preview: caches.preview
        case .screen: caches.screen
        case .body: caches.body
        }
    }

    /// ジョブのキー（種類 + パス）
    private static func key(_ kind: ImageKind, _ item: PhotoItem) -> String { "\(kind.keyPrefix)|\(cacheKey(item))" }

    /// すべてのキャッシュとジョブを捨てる（フォルダを開き直すとき）。
    /// 未着手のジョブは取り消し、待っている呼び出しは nil で再開する。実行中のデコードは結果を捨てる。
    func removeAll() {
        let waiters: [CheckedContinuation<PipelineImage?, Never>] = state.withLock { s in
            var list: [CheckedContinuation<PipelineImage?, Never>] = []
            for (_, job) in s.jobs {
                job.cancel()
                list.append(contentsOf: job.waiters.values)
                job.waiters = [:]
                job.prefetchWanted = false
            }
            s.jobs = [:]
            s.waiterKeys = [:]
            return list
        }
        caches.thumbnail.removeAllObjects()
        caches.preview.removeAllObjects()
        caches.screen.removeAllObjects()
        caches.body.removeAllObjects()
        for w in waiters { w.resume(returning: nil) }
    }

    // MARK: 読み込み

    /// 読み込んで返す。呼び出し側のタスクがキャンセルされたら、待ちをやめて nil を返す。
    /// `queuePriority` は待たれている間のジョブの優先度（今のコマは既定の `.high`）。
    func load(_ kind: ImageKind, for item: PhotoItem, queuePriority: Operation.QueuePriority = .high) async -> PipelineImage? {
        if let hit = cached(kind, for: item) { return hit }
        let key = Self.key(kind, item)
        let waiterID = state.withLock { s -> Int in
            s.nextWaiter += 1
            return s.nextWaiter
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<PipelineImage?, Never>) in
                register(cont, waiterID: waiterID, key: key, kind: kind, item: item, priority: queuePriority)
            }
        } onCancel: {
            self.cancelWaiter(waiterID)
        }
    }

    private func register(_ cont: CheckedContinuation<PipelineImage?, Never>, waiterID: Int, key: String,
                          kind: ImageKind, item: PhotoItem, priority: Operation.QueuePriority) {
        enum Outcome { case wait, cancelled, cached(PipelineImage) }
        let outcome: Outcome = state.withLock { s in
            if Task.isCancelled { return .cancelled }
            if let hit = cached(kind, for: item) { return .cached(hit) }
            let job: DecodeJob
            if let existing = s.jobs[key] {
                job = existing
                if priority.rawValue > job.queuePriority.rawValue { job.queuePriority = priority }
            } else {
                job = DecodeJob(key: key, kind: kind, item: item, pipeline: self)
                job.queuePriority = priority
                s.jobs[key] = job
                queue(kind).addOperation(job)
            }
            job.waiters[waiterID] = cont
            s.waiterKeys[waiterID] = key
            return .wait
        }
        switch outcome {
        case .wait: break
        case .cancelled: cont.resume(returning: nil)
        case .cached(let image): cont.resume(returning: image)
        }
    }

    private func cancelWaiter(_ waiterID: Int) {
        let cont: CheckedContinuation<PipelineImage?, Never>? = state.withLock { s in
            guard let key = s.waiterKeys.removeValue(forKey: waiterID), let job = s.jobs[key] else { return nil }
            let cont = job.waiters.removeValue(forKey: waiterID)
            if job.waiters.isEmpty {
                if !job.prefetchWanted, !job.isExecuting {
                    // 誰も必要としない未着手のジョブは取り消す
                    s.jobs[key] = nil
                    job.cancel()
                } else {
                    job.queuePriority = .low
                }
            }
            return cont
        }
        cont?.resume(returning: nil)
    }

    fileprivate func finish(_ job: DecodeJob, decoded: PipelineImage?) {
        if let decoded {
            cache(job.kind).setObject(decoded, forKey: Self.cacheKey(job.kind, job.item) as NSString, cost: decoded.cost)
        }
        let waiters: [CheckedContinuation<PipelineImage?, Never>] = state.withLock { s in
            if s.jobs[job.key] === job { s.jobs[job.key] = nil }
            let list = Array(job.waiters)
            job.waiters = [:]
            for (id, _) in list { s.waiterKeys[id] = nil }
            return list.map(\.value)
        }
        for w in waiters { w.resume(returning: decoded) }
    }

    /// 先読み（結果は待たない）。`items` は近い順。
    /// 呼ぶたびに、この種類の範囲外になった未着手の先読みジョブを取り消す（`screen` は大きさ違いも範囲外）。
    func prefetch(_ kind: ImageKind, items: [PhotoItem]) {
        let desired = Dictionary(items.map { (Self.key(kind, $0), $0) }, uniquingKeysWith: { a, _ in a })
        state.withLock { s in
            for (key, job) in s.jobs where job.kind.category == kind.category {
                if desired[key] != nil {
                    job.prefetchWanted = true
                } else {
                    job.prefetchWanted = false
                    if job.waiters.isEmpty, !job.isExecuting {
                        s.jobs[key] = nil
                        job.cancel()
                    }
                }
            }
            for item in items {
                let key = Self.key(kind, item)
                guard s.jobs[key] == nil, cached(kind, for: item) == nil else { continue }
                let job = DecodeJob(key: key, kind: kind, item: item, pipeline: self)
                job.queuePriority = .low
                job.prefetchWanted = true
                s.jobs[key] = job
                queue(kind).addOperation(job)
            }
        }
    }

    // MARK: デコード

    /// デコード結果を表示用の形にする（サムネイル以外は IOSurface に描く。失敗したら CGImage のまま）
    fileprivate static func prepare(_ image: CGImage, kind: ImageKind) -> PipelineImage {
        if kind == .thumbnail { return PipelineImage(cgImage: image) }
        if let surface = makeSurface(from: image) { return PipelineImage(surface: surface) }
        return PipelineImage(cgImage: image)
    }

    /// BGRA（プリマルチプライド）の IOSurface に描く。色空間は元画像のもの（RGB 以外は sRGB）を付けておき、
    /// 画面の色空間への変換は描画サーバーに任せる。
    private static func makeSurface(from image: CGImage) -> IOSurface? {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return nil }
        let props: [IOSurfacePropertyKey: any Sendable] = [
            .width: w,
            .height: h,
            .bytesPerElement: 4,
            .bytesPerRow: IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, w * 4),
            .pixelFormat: kCVPixelFormatType_32BGRA,
        ]
        guard let surface = IOSurface(properties: props) else { return nil }
        let space: CGColorSpace
        if let s = image.colorSpace, s.model == .rgb, s.supportsOutput {
            space = s
        } else {
            space = CGColorSpace(name: CGColorSpace.sRGB)!
        }
        surface.lock(options: [], seed: nil)
        defer { surface.unlock(options: [], seed: nil) }
        guard let ctx = CGContext(data: surface.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: surface.bytesPerRow, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                      | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        ctx.setBlendMode(.copy)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        if let plist = space.copyPropertyList() {
            IOSurfaceSetValue(surface, kIOSurfaceColorSpace, plist)
        }
        return surface
    }

    fileprivate static func decode(_ kind: ImageKind, item: PhotoItem) -> CGImage? {
        // フォルダを開いた直後はメタデータが未読み取り。埋め込み画像の位置と向きを知るため、その場で読む
        var item = item
        if item.metadata == nil { item.metadata = PhotoMetadataLoader.defaultReader(item) }
        switch ImageSource(item: item) {
        case .jpeg(let url):
            switch kind {
            case .thumbnail: return decodeJPEGThumbnail(url: url, metadata: item.metadata)
            case .preview: return decodeJPEGPreview(url: url, metadata: item.metadata)
            case .screen(let maxPixel): return decodeJPEGScreen(url: url, maxPixel: maxPixel)
            case .body: return decodeJPEGBody(url: url)
            }
        case .arw(let url):
            switch kind {
            case .thumbnail: return decodeARWThumbnail(url: url, metadata: item.metadata)
            case .preview: return decodeARWPreview(url: url, metadata: item.metadata)
            case .screen(let maxPixel): return decodeARWScreen(url: url, maxPixel: maxPixel)
            case .body: return decodeARWBody(url: url)
            }
        }
    }

    // MARK: ARW

    /// ARW のサムネイル。埋め込み JPEG（1920×1080、100KB 弱）を縮小デコードする。
    /// ImageIO に ARW を渡すと 1 枚 300ms ほどかかる（α1 II で実測）ので、埋め込みが取れないときだけ使う。
    private static func decodeARWThumbnail(url: URL, metadata: PhotoMetadata?) -> CGImage? {
        if let data = embeddedARWJPEGData(url: url, metadata: metadata),
           let source = CGImageSourceCreateWithData(data as CFData, nil) {
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: 320,
            ]
            // 向きはプレビューと同じく ARW の Orientation で当てる（ImageIO には当てさせない）
            if let image = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary) {
                return oriented(image, orientation: metadata?.orientation ?? 1)
            }
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: 320,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary)
    }

    /// ARW の大プレビュー。埋め込み JPEG があればそれ、無ければ ImageIO（長辺 1920、埋め込み優先）。
    private static func decodeARWPreview(url: URL, metadata: PhotoMetadata?) -> CGImage? {
        if let embedded = embeddedARWJPEG(url: url, metadata: metadata) {
            return oriented(embedded, orientation: metadata?.orientation ?? 1)
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: 1920,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary)
    }

    /// 全体表示用の RAW 現像（向き適用済み）。長辺 `maxPixel` になる倍率で現像する（縮小現像は速い）。
    /// CIRAWFilter が使えないときは ImageIO に現像させて縮小する（RAW 現像なので重い）。
    private static func decodeARWScreen(url: URL, maxPixel: Int) -> CGImage? {
        if let filter = CIRAWFilter(imageURL: url) {
            let native = filter.nativeSize
            let long = max(native.width, native.height)
            if long > 0 { filter.scaleFactor = Float(min(1, Double(maxPixel) / Double(long))) }
            if let output = filter.outputImage {
                let space = CGColorSpace(name: CGColorSpace.sRGB)!
                if let image = ciContext.createCGImage(output, from: output.extent.integral, format: .RGBA8,
                                                       colorSpace: space) {
                    return image
                }
            }
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return imageIOThumbnail(source: source, maxPixel: maxPixel)
    }

    /// 拡大用の RAW 現像（向き適用済み）。CIRAWFilter、使えなければ ImageIO のフル解像度。
    private static func decodeARWBody(url: URL) -> CGImage? {
        if let filter = CIRAWFilter(imageURL: url), let output = filter.outputImage {
            let space = CGColorSpace(name: CGColorSpace.sRGB)!
            if let image = ciContext.createCGImage(output, from: output.extent, format: .RGBA8, colorSpace: space) {
                return image
            }
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
        let w = (props?[kCGImagePropertyPixelWidth as String] as? Int) ?? 0
        let h = (props?[kCGImagePropertyPixelHeight as String] as? Int) ?? 0
        return imageIOThumbnail(source: source, maxPixel: max(w, h, 1920))
    }

    /// ARW に埋め込まれた JPEG（先頭が FF D8 のものだけ）。向きは未適用
    private static func embeddedARWJPEG(url: URL, metadata: PhotoMetadata?) -> CGImage? {
        embeddedARWJPEGData(url: url, metadata: metadata).flatMap(decodeData)
    }

    /// ARW に埋め込まれた JPEG のバイト列（先頭が FF D8 のものだけ）
    private static func embeddedARWJPEGData(url: URL, metadata: PhotoMetadata?) -> Data? {
        guard let range = metadata?.mpfPreview,
              let data = try? range.readData(from: url),
              data.count > 2, data[data.startIndex] == 0xFF, data[data.startIndex + 1] == 0xD8 else { return nil }
        return data
    }

    /// IFD1 のサムネイル（160×120）。無ければ ImageIO に任せる。
    private static func decodeJPEGThumbnail(url: URL, metadata: PhotoMetadata?) -> CGImage? {
        if let range = metadata?.thumbnail,
           let data = try? range.readData(from: url),
           let image = decodeData(data) {
            let cropped = croppedToContent(image, metadata: metadata)
            return oriented(cropped, orientation: metadata?.orientation ?? 1)
        }
        return imageIOThumbnail(url: url, maxPixel: 320)
    }

    /// MPF の 2 枚目（1920×1080 程度）。無ければ ImageIO の長辺 1920。
    private static func decodeJPEGPreview(url: URL, metadata: PhotoMetadata?) -> CGImage? {
        if let range = metadata?.mpfPreview,
           let data = try? range.readData(from: url),
           let image = decodeData(data) {
            return oriented(image, orientation: metadata?.orientation ?? 1)
        }
        return imageIOThumbnail(url: url, maxPixel: 1920)
    }

    /// 全体表示用。本体を長辺 `maxPixel` に縮小デコードする（向き適用済み）。
    /// ImageIO はフル解像度から縮小するので、MPF プレビューを引き伸ばすより細部が残る。
    private static func decodeJPEGScreen(url: URL, maxPixel: Int) -> CGImage? {
        imageIOThumbnail(url: url, maxPixel: maxPixel)
    }

    /// 本体（向き適用済み）
    private static func decodeJPEGBody(url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
        let w = (props?[kCGImagePropertyPixelWidth as String] as? Int) ?? 0
        let h = (props?[kCGImagePropertyPixelHeight as String] as? Int) ?? 0
        return imageIOThumbnail(source: source, maxPixel: max(w, h, 1920))
    }

    /// IFD1 のサムネイルは 4:3 に黒帯を足してあるので、本体の縦横比に合わせて帯を切り落とす
    private static func croppedToContent(_ image: CGImage, metadata: PhotoMetadata?) -> CGImage {
        guard let w = metadata?.imageWidth, let h = metadata?.imageHeight, w > 0, h > 0 else { return image }
        let content = Double(w) / Double(h)
        let iw = Double(image.width), ih = Double(image.height)
        let current = iw / ih
        guard abs(current - content) / content > 0.03 else { return image }
        let rect: CGRect
        if current < content {
            let newH = (iw / content).rounded()
            rect = CGRect(x: 0, y: ((ih - newH) / 2).rounded(), width: iw, height: newH)
        } else {
            let newW = (ih * content).rounded()
            rect = CGRect(x: ((iw - newW) / 2).rounded(), y: 0, width: newW, height: ih)
        }
        return image.cropping(to: rect) ?? image
    }

    private static func decodeData(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceShouldCacheImmediately: true]
        return CGImageSourceCreateImageAtIndex(source, 0, opts as CFDictionary)
    }

    private static func imageIOThumbnail(url: URL, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return imageIOThumbnail(source: source, maxPixel: maxPixel)
    }

    /// 向き（EXIF Orientation）を適用した縮小画像
    private static func imageIOThumbnail(source: CGImageSource, maxPixel: Int) -> CGImage? {
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary)
    }

    // MARK: 向きの適用

    private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    /// EXIF Orientation（1〜8）に従って回転・反転した画像を返す
    static func oriented(_ image: CGImage, orientation: Int) -> CGImage {
        guard (2...8).contains(orientation) else { return image }
        let ci = CIImage(cgImage: image).oriented(forExifOrientation: Int32(orientation))
        let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        return ciContext.createCGImage(ci, from: ci.extent, format: .RGBA8, colorSpace: space) ?? image
    }
}
