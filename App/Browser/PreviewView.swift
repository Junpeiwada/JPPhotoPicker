import SwiftUI
import PhotoPickerCore

/// 写真の閲覧領域。ダークニュートラルの背景に写真を置き、バッジ類は Liquid Glass で角に重ねる。
struct PreviewView: View {
    @Environment(BrowserModel.self) private var model
    @Environment(\.displayScale) private var displayScale

    /// 写真アプリのように写真が主役になる落ち着いた背景
    private static let background = Color(white: 0.08)

    var body: some View {
        // 外側の GeometryReader は安全領域を守るので、ここでツールバー（タイトルバー）の高さが取れる。
        // 内側は ignoresSafeArea で上端まで広げるため、内側の safeAreaInsets は 0 になる。
        GeometryReader { outer in
            preview(topInset: outer.safeAreaInsets.top)
        }
    }

    private func preview(topInset: CGFloat) -> some View {
        GeometryReader { proxy in
            ZStack {
                Self.background

                if model.currentItem != nil {
                    // 画像が一時的に nil でもビューは作り直さない（ProgressView を重ねる）
                    ZoomableImageView(
                        image: model.displayBody ?? model.displayPreview,
                        imageRect: model.geometry.imageRect,
                        isZoomed: !model.zoom.isFit,
                        onClick: { model.click(atViewPoint: $0) },
                        onPan: { model.pan(contentDelta: $0) },
                        onPinch: { phase, magnification, point in
                            switch phase {
                            case .began: model.beginPinch()
                            case .changed: model.pinch(magnification: magnification, anchorViewPoint: point)
                            case .ended: model.endPinch()
                            }
                        })
                        .accessibilityLabel(accessibilityText)
                    if model.displayBody == nil && model.displayPreview == nil {
                        ProgressView().controlSize(.small)
                    }
                }

                if model.showFocusFrame {
                    FocusFrameOverlay(focus: model.currentFocus, geometry: model.geometry)
                }

                // 拡大中は写真がツールバーの下まで来るので、タイトル・進捗が読めるよう上端に控えめな黒を重ねる
                if !model.zoom.isFit, topInset > 0 {
                    VStack(spacing: 0) {
                        LinearGradient(colors: [.black.opacity(0.4), .black.opacity(0)],
                                       startPoint: .top, endPoint: .bottom)
                            .frame(height: topInset)
                        Spacer(minLength: 0)
                    }
                    .allowsHitTesting(false)
                }

                overlays(topInset: topInset)
            }
            .clipped()
            // 全体表示は安全領域（ツールバーの下）の内側に収める。拡大中はツールバーの下まで描く。
            // ビューの大きさ・上端の空きはモデルへ渡し、クリック・ピンチの座標変換も同じ値で行う。
            .onChange(of: proxy.size, initial: true) { _, size in
                model.viewportChanged(size: size, scale: displayScale, topInset: topInset)
            }
            .onChange(of: topInset) { _, inset in
                model.viewportChanged(size: proxy.size, scale: displayScale, topInset: inset)
            }
            .onChange(of: displayScale) { _, scale in
                model.viewportChanged(size: proxy.size, scale: scale, topInset: topInset)
            }
        }
        // 写真をツールバー（Liquid Glass）の下まで回り込ませる（全体表示の配置だけは上端を空ける）
        .ignoresSafeArea(edges: .top)
    }

    private func overlays(topInset: CGFloat) -> some View {
        VStack {
            HStack {
                if model.currentItem?.kind == .arwOnly {
                    badge { Text("ARW").font(.caption.weight(.semibold)) }
                        .accessibilityLabel("ARW だけのファイル")
                        .help("ペアの JPG がない ARW ファイルです")
                }
                Spacer()
            }
            Spacer()
            HStack(alignment: .bottom) {
                GlassEffectContainer(spacing: 8) { statusBadges }
                Spacer()
                GlassEffectContainer(spacing: 8) { zoomControls }
            }
        }
        .padding(14)
        .padding(.top, topInset)
    }

    private var statusBadges: some View {
        HStack(spacing: 8) {
            switch model.currentDecision {
            case .picked:
                badge { Label("採用", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
            case .rejected:
                badge { Label("不採用", systemImage: "xmark.circle.fill").foregroundStyle(.secondary) }
            case .undecided:
                EmptyView()
            }
            if let e = model.currentEntry, e.isBurst {
                badge { Label("連写 \(e.positionInGroup + 1)/\(e.groupCount)", systemImage: "square.stack.3d.down.right") }
            }
            if let item = model.currentItem {
                badge { Text(item.id).monospaced().foregroundStyle(.secondary) }
            }
        }
        .font(.callout.weight(.medium))
    }

    private var zoomControls: some View {
        VStack(alignment: .trailing, spacing: 8) {
            decisionSegment
            HStack(spacing: 8) {
                if !model.zoom.isFit {
                    badge { Text(zoomLabel).monospacedDigit() }
                }
                Button {
                    model.moveToFocus()
                } label: {
                    Label("フォーカス位置へ", systemImage: "scope")
                }
                .buttonStyle(.glass)
                .help(model.currentFocus.hasFocusPosition
                      ? "ソニーのフォーカス位置を拡大表示します（F）"
                      : "フォーカス位置がないので、中心を拡大表示します（F）")
            }
        }
        .font(.callout.weight(.medium))
    }

    /// 採用 / 不採用の切り替え。選ばれている方を押すと未判定に戻る。次のコマへは進まない。
    private var decisionSegment: some View {
        HStack(spacing: 2) {
            segmentButton(.picked, title: "採用", systemImage: "checkmark.circle.fill", tint: .green, key: "P",
                          help: "採用にします。もう一度押すと未判定に戻します（P）")
            segmentButton(.rejected, title: "不採用", systemImage: "xmark.circle.fill", tint: .red, key: "X",
                          help: "不採用にします。もう一度押すと未判定に戻します（X）")
        }
        .padding(3)
        .glassEffect(.regular, in: .capsule)
        .disabled(model.currentItem == nil)
    }

    private func segmentButton(_ decision: Decision, title: String, systemImage: String,
                               tint: Color, key: String, help: String) -> some View {
        let selected = model.currentDecision == decision
        return Button {
            model.toggleDecision(decision)
        } label: {
            HStack(spacing: 6) {
                Label(title, systemImage: systemImage)
                keyCap(key, selected: selected)
            }
            .foregroundStyle(selected ? Color.white : Color.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(selected ? tint.opacity(0.85) : .clear, in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// ショートカットキーの表示（キーキャップ風の小さな枠）
    private func keyCap(_ key: String, selected: Bool) -> some View {
        Text(key)
            .font(.caption2.weight(.semibold).monospaced())
            .opacity(0.75)
            .frame(minWidth: 16, minHeight: 16)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.primary.opacity(selected ? 0.6 : 0.35), lineWidth: 1))
            .accessibilityHidden(true)
    }

    private var zoomLabel: String {
        let percent = (model.zoom.scale ?? 1) * 100
        return "\(Int(percent.rounded()))%"
    }

    private func badge<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .glassEffect(.regular, in: .capsule)
    }

    private var accessibilityText: String {
        guard let e = model.currentEntry else { return "写真" }
        var text = e.item.id
        switch model.currentDecision {
        case .picked: text += "、採用"
        case .rejected: text += "、不採用"
        case .undecided: break
        }
        if e.isBurst { text += "、連写 \(e.groupCount) 枚中 \(e.positionInGroup + 1) 枚目" }
        return text
    }
}
