import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import Synchronization
import PhotoPickerCore

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
enum ImageKind: String, Sendable {
    case thumbnail
    case preview
    case body
}

/// CGImage を Sendable として渡すための包み（CGImage は作成後に変更されない）
struct SendableImage: @unchecked Sendable {
    let image: CGImage
}

/// デコード 1 件分のジョブ。状態（waiters など）は ImagePipeline のロックの下でだけ触る。
private final class DecodeJob: Operation, @unchecked Sendable {
    let key: String
    let kind: ImageKind
    let item: PhotoItem
    weak var pipeline: ImagePipeline?
    var waiters: [Int: CheckedContinuation<SendableImage?, Never>] = [:]
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
        let decoded = ImagePipeline.decode(kind, item: item)
        pipeline?.finish(self, decoded: decoded)
    }
}

/// サムネイル / 大プレビュー / 本体の読み込みとキャッシュ、先読み。
/// - デコードは専用の `OperationQueue`（種類ごとに同時数を制限）で行い、Swift の協調プールを占有しない。
/// - 同じ画像の同時読み込みは 1 つのジョブにまとめる。待つ側のキャンセルは待ちを外すだけで、
///   誰も待たず先読みの対象でもなくなった未着手のジョブは取り消す。
/// - キャッシュはメモリ上だけ（NSCache、コスト = 幅 × 高さ × 4 で上限を付ける）。
final class ImagePipeline: @unchecked Sendable {
    private struct Caches: @unchecked Sendable {
        let thumbnail = NSCache<NSString, CGImage>()
        let preview = NSCache<NSString, CGImage>()
        let body = NSCache<NSString, CGImage>()
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
    private let bodyQueue = ImagePipeline.makeQueue("body", concurrency: 2)

    init() {
        caches.thumbnail.totalCostLimit = 300 * 1024 * 1024
        caches.preview.totalCostLimit = 400 * 1024 * 1024
        caches.body.totalCostLimit = 1024 * 1024 * 1024
    }

    private static func makeQueue(_ name: String, concurrency: Int) -> OperationQueue {
        let q = OperationQueue()
        q.name = "PhotoPicker.decode.\(name)"
        q.maxConcurrentOperationCount = concurrency
        q.qualityOfService = .userInitiated
        return q
    }

    private func queue(_ kind: ImageKind) -> OperationQueue {
        switch kind {
        case .thumbnail: thumbnailQueue
        case .preview: previewQueue
        case .body: bodyQueue
        }
    }

    // MARK: キャッシュ参照（同期。コマ送りの即時表示に使う）

    func cached(_ kind: ImageKind, for item: PhotoItem) -> CGImage? {
        cache(kind).object(forKey: Self.cacheKey(item) as NSString)
    }

    /// キャッシュのキー。フォルダが違えば同じファイル名でも別の画像なので、ファイル名（`item.id`）ではなくパスを使う。
    private static func cacheKey(_ item: PhotoItem) -> String {
        item.primaryURL.standardizedFileURL.path
    }

    private func cache(_ kind: ImageKind) -> NSCache<NSString, CGImage> {
        switch kind {
        case .thumbnail: caches.thumbnail
        case .preview: caches.preview
        case .body: caches.body
        }
    }

    /// ジョブのキー（種類 + パス）
    private static func key(_ kind: ImageKind, _ item: PhotoItem) -> String { "\(kind.rawValue)|\(cacheKey(item))" }

    /// すべてのキャッシュとジョブを捨てる（フォルダを開き直すとき）。
    /// 未着手のジョブは取り消し、待っている呼び出しは nil で再開する。実行中のデコードは結果を捨てる。
    func removeAll() {
        let waiters: [CheckedContinuation<SendableImage?, Never>] = state.withLock { s in
            var list: [CheckedContinuation<SendableImage?, Never>] = []
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
        caches.body.removeAllObjects()
        for w in waiters { w.resume(returning: nil) }
    }

    // MARK: 読み込み

    /// 読み込んで返す。呼び出し側のタスクがキャンセルされたら、待ちをやめて nil を返す。
    /// `queuePriority` は待たれている間のジョブの優先度（今のコマは既定の `.high`）。
    func load(_ kind: ImageKind, for item: PhotoItem, queuePriority: Operation.QueuePriority = .high) async -> CGImage? {
        if let hit = cached(kind, for: item) { return hit }
        let key = Self.key(kind, item)
        let waiterID = state.withLock { s -> Int in
            s.nextWaiter += 1
            return s.nextWaiter
        }
        let result: SendableImage? = await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<SendableImage?, Never>) in
                register(cont, waiterID: waiterID, key: key, kind: kind, item: item, priority: queuePriority)
            }
        } onCancel: {
            self.cancelWaiter(waiterID)
        }
        return result?.image
    }

    private func register(_ cont: CheckedContinuation<SendableImage?, Never>, waiterID: Int, key: String,
                          kind: ImageKind, item: PhotoItem, priority: Operation.QueuePriority) {
        enum Outcome { case wait, cancelled, cached(CGImage) }
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
        case .cached(let image): cont.resume(returning: SendableImage(image: image))
        }
    }

    private func cancelWaiter(_ waiterID: Int) {
        let cont: CheckedContinuation<SendableImage?, Never>? = state.withLock { s in
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

    fileprivate func finish(_ job: DecodeJob, decoded: CGImage?) {
        if let decoded {
            cache(job.kind).setObject(decoded, forKey: Self.cacheKey(job.item) as NSString, cost: Self.cost(of: decoded))
        }
        let waiters: [CheckedContinuation<SendableImage?, Never>] = state.withLock { s in
            if s.jobs[job.key] === job { s.jobs[job.key] = nil }
            let list = Array(job.waiters)
            job.waiters = [:]
            for (id, _) in list { s.waiterKeys[id] = nil }
            return list.map(\.value)
        }
        let image = decoded.map(SendableImage.init)
        for w in waiters { w.resume(returning: image) }
    }

    /// 先読み（結果は待たない）。`items` は近い順。
    /// 呼ぶたびに、この種類の範囲外になった未着手の先読みジョブを取り消す。
    func prefetch(_ kind: ImageKind, items: [PhotoItem]) {
        let desired = Dictionary(items.map { (Self.key(kind, $0), $0) }, uniquingKeysWith: { a, _ in a })
        state.withLock { s in
            for (key, job) in s.jobs where job.kind == kind {
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

    private static func cost(of image: CGImage) -> Int { image.width * image.height * 4 }

    fileprivate static func decode(_ kind: ImageKind, item: PhotoItem) -> CGImage? {
        switch ImageSource(item: item) {
        case .jpeg(let url):
            switch kind {
            case .thumbnail: return decodeJPEGThumbnail(url: url, metadata: item.metadata)
            case .preview: return decodeJPEGPreview(url: url, metadata: item.metadata)
            case .body: return decodeJPEGBody(url: url)
            }
        case .arw(let url):
            switch kind {
            case .thumbnail: return decodeARWThumbnail(url: url, metadata: item.metadata)
            case .preview: return decodeARWPreview(url: url, metadata: item.metadata)
            case .body: return decodeARWBody(url: url)
            }
        }
    }

    // MARK: ARW

    /// ARW のサムネイル。ImageIO が埋め込みを使う（IfAbsent）。取れなければ埋め込み JPEG を縮小する。
    private static func decodeARWThumbnail(url: URL, metadata: PhotoMetadata?) -> CGImage? {
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil) {
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: 320,
            ]
            if let image = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary),
               max(image.width, image.height) >= 160 {
                return image
            }
        }
        // 埋め込みのサムネイルが小さすぎる・取れないときは、埋め込み JPEG から縮小する
        if let embedded = embeddedARWJPEG(url: url, metadata: metadata) {
            return oriented(downscaled(embedded, maxPixel: 320), orientation: metadata?.orientation ?? 1)
        }
        return nil
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
        guard let range = metadata?.mpfPreview,
              let data = try? range.readData(from: url),
              data.count > 2, data[data.startIndex] == 0xFF, data[data.startIndex + 1] == 0xD8 else { return nil }
        return decodeData(data)
    }

    private static func downscaled(_ image: CGImage, maxPixel: Int) -> CGImage {
        guard max(image.width, image.height) > maxPixel else { return image }
        let scale = Double(maxPixel) / Double(max(image.width, image.height))
        let ci = CIImage(cgImage: image).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        return ciContext.createCGImage(ci, from: ci.extent, format: .RGBA8, colorSpace: space) ?? image
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
