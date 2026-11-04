import AppKit
import CoreGraphics
import TobiCore

/// 1 枚の画面に出すラベルを、`draw(_:)` でまとめて描くビュー（design.md 9.3、D-17）。
///
/// - 座標は画面ローカル（左上原点、y 下向き）。`isFlipped = true` なので `HintPlacement.anchor` をそのまま使える
///   （design.md 9.1）。
/// - `show` で、ラベルの文字列（大文字。Q-8）と実寸を 1 回だけ作ってキャッシュする。`draw(_:)` ではキャッシュを
///   並べるだけにし、`HintPlacement.clamp` で画面内に収める（F-3.5）。
/// - `update(visibleIDs:typedCount:)` は表示するラベルの集合を差し替えて再描画する（位置も実寸も変えない。F-4）。
///   入力済みの文字（ラベルの先頭 `typedCount` 文字）は薄い色で描く（Vimium と同じ見せ方。T50 の要望）。
///   薄くした文字列は、入力済みの文字数が変わったときに、表示するラベルの分だけ作り直す（色が変わるだけで実寸は同じ）。
/// - ラベルの文字列や要素の内容はログに出さない（design.md 14 章）。
///
/// スレッド: MainActor でだけ使う（AppKit のビュー）。
@MainActor
final class HintOverlayView: NSView {
    /// `show` で作った、描画の準備が済んだラベル。
    private struct PreparedLabel {
        let elementID: ElementID
        /// 画面ローカルの左上（clamp 前）。
        let anchor: CGPoint
        /// 大文字にして、フォントと文字色を付けた文字列。入力済みの文字がないときに描く。
        let text: NSAttributedString
        /// 背景を含むラベルの実寸。
        let size: CGSize
        /// 先頭の `count` 文字を薄い色にした `text`。入力済みの文字数が変わったときにだけ作り直す。
        var dimmed: (count: Int, text: NSAttributedString)?

        /// 入力済みの文字数に合わせて描く文字列。薄くした文字列は `prepareDimmedTexts` で用意してある。
        func text(typedCount: Int) -> NSAttributedString {
            guard typedCount > 0 else { return text }
            guard let dimmed, dimmed.count == typedCount else {
                // update で表示するラベルの分は必ず作るので、ここに来るのは作り忘れ。濃いままで描く（ラベルは隠さない）
                assertionFailure("入力済みの文字数 \(typedCount) の文字列を作っていない")
                return text
            }
            return dimmed.text
        }
    }

    /// `show` で決まる、1 回のセッション中は変わらない描画の設定（S-0.4）。
    private struct LabelStyle {
        /// 入力済みの文字の不透明度を、設定の文字色の何倍にするか。
        ///
        /// 0.4 倍: 背景の上でまだ読めるが、濃いままの「次に打つ文字」とはひと目で区別できる濃さ
        /// （T50 の手動確認で承認された見せ方）。背景色は変えず、文字の色だけを薄くする。
        private static let typedAlphaFactor: CGFloat = 0.4

        let backgroundColor: NSColor
        /// 入力済みの文字の色（`LabelAppearance.textColor` の不透明度を `typedAlphaFactor` 倍したもの）。
        let typedTextColor: NSColor
        /// 文字の周りの余白（左右・上下）。
        let padding: CGSize
        let cornerRadius: CGFloat

        init(appearance: LabelAppearance) {
            let fontSize = CGFloat(appearance.fontSize)
            backgroundColor = NSColor(appearance.backgroundColor)
            let textColor = NSColor(appearance.textColor)
            typedTextColor = textColor.withAlphaComponent(textColor.alphaComponent * Self.typedAlphaFactor)
            // フォントサイズに比例させ、設定で大きくしても小さくしても見た目の比率が変わらないようにする
            // （12pt で左右 4pt・上下 2pt・角丸 3pt。T7 のスパイクで見やすかった値）
            padding = CGSize(width: (fontSize / 3).rounded(), height: (fontSize / 6).rounded())
            cornerRadius = (fontSize / 4).rounded()
        }
    }

    private var labels: [PreparedLabel] = []
    private var visibleIDs: Set<ElementID> = []
    /// 入力済みの文字数。表示中のラベルはすべて入力済みの文字列を接頭辞に持つので、ラベルごとには持たない。
    private var typedCount = 0
    private var style: LabelStyle?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // パネルの frame（= 画面の大きさ）に合わせて伸び縮みする
        autoresizingMask = [.width, .height]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    // 左上原点にして、HintPlacement.anchor（画面ローカル、y 下向き）を変換なしで使う
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    /// このビューの画面に出すラベルを置き換え、すべて表示する状態にする。
    ///
    /// `placements` は、このビューの画面に割り当てられたもの（`screenID` が一致するもの）だけを渡す。
    /// 振り分けは呼び出し側（`OverlayController`、T45）が行う。ラベルの実寸はここで 1 回だけ測る。
    func show(_ placements: [HintPlacement], appearance: LabelAppearance) {
        let font = NSFont.monospacedSystemFont(ofSize: CGFloat(appearance.fontSize), weight: .bold)
        let attributes: [NSAttributedString.Key: NSObject] = [
            .font: font,
            .foregroundColor: NSColor(appearance.textColor),
        ]
        let style = LabelStyle(appearance: appearance)
        labels = placements.map { placement in
            // ラベルは小文字で持ち、表示するときだけ大文字にする（Q-8）
            let text = NSAttributedString(string: placement.label.uppercased(), attributes: attributes)
            let textSize = text.size()
            // 半端な寸法だと文字と背景の縁がぼけるため、ポイントの整数に切り上げる
            let size = CGSize(
                width: (textSize.width + style.padding.width * 2).rounded(.up),
                height: (textSize.height + style.padding.height * 2).rounded(.up)
            )
            return PreparedLabel(
                elementID: placement.elementID,
                anchor: placement.anchor,
                text: text,
                size: size,
                dimmed: nil
            )
        }
        visibleIDs = Set(labels.map(\.elementID))
        typedCount = 0
        self.style = style
        needsDisplay = true
    }

    /// 絞り込みの結果を反映する。`visibleIDs` に含まれないラベルを隠し、表示するラベルの先頭 `typedCount` 文字を
    /// 薄い色で描く（F-4）。`typedCount` が 0 なら、すべての文字を元の色で描く（Backspace で戻したとき）。
    ///
    /// 他の画面の要素の ID が混ざっていてもよい（このビューのラベルだけを見る）。位置と実寸は `show` のまま変えない。
    func update(visibleIDs: Set<ElementID>, typedCount: Int) {
        assert(typedCount >= 0, "入力済みの文字数は 0 以上")
        self.visibleIDs = visibleIDs
        self.typedCount = typedCount
        if typedCount > 0, let style {
            prepareDimmedTexts(typedCount: typedCount, color: style.typedTextColor)
        }
        needsDisplay = true
    }

    /// ラベルとキャッシュをすべて捨てる。次にパネルを出したときに前のセッションのラベルが見えないようにする。
    func clear() {
        labels = []
        visibleIDs = []
        typedCount = 0
        style = nil
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        // 透過のウィンドウなので、前の絵を透明で上書きして消す（.copy で、下の内容と合成しない）
        NSColor.clear.setFill()
        dirtyRect.fill(using: .copy)

        guard let style, !labels.isEmpty else { return }
        let screenSize = bounds.size
        for label in labels where visibleIDs.contains(label.elementID) {
            let origin = HintPlacement.clamp(origin: label.anchor, labelSize: label.size, screenSize: screenSize)
            let rect = CGRect(origin: origin, size: label.size)
            guard rect.intersects(dirtyRect) else { continue }
            // 文字の描画が塗りの色を変えるので、ラベルごとに設定し直す
            style.backgroundColor.setFill()
            NSBezierPath(roundedRect: rect, xRadius: style.cornerRadius, yRadius: style.cornerRadius).fill()
            let textOrigin = CGPoint(x: origin.x + style.padding.width, y: origin.y + style.padding.height)
            label.text(typedCount: typedCount).draw(at: textOrigin)
        }
        // N-1.1 の計測: ラベルを描き終えた時点（ヒントモードの外の空の描画では打たない）
        Signposts.rendered()
    }

    /// 表示するラベルのうち、薄くした文字列が `typedCount` 文字分になっていないものだけを作り直す。
    ///
    /// 隠れたラベルは作り直さない（Backspace で再び表示するときに、文字数が違えばここで作り直す）。
    private func prepareDimmedTexts(typedCount: Int, color: NSColor) {
        for index in labels.indices where visibleIDs.contains(labels[index].elementID) {
            guard labels[index].dimmed?.count != typedCount else { continue }
            let text = NSMutableAttributedString(attributedString: labels[index].text)
            let string = text.string
            // 表示中のラベルは入力済みの文字列より長い（同じ長さなら確定して消えている）。prefix は長さを超えない
            let typed = string.prefix(typedCount)
            let range = NSRange(typed.startIndex..<typed.endIndex, in: string)
            text.addAttribute(.foregroundColor, value: color, range: range)
            labels[index].dimmed = (count: typedCount, text: text)
        }
    }
}

extension NSColor {
    /// 設定の色（`RGBAColor`）から作る。成分は sRGB の値として扱う。
    fileprivate convenience init(_ color: RGBAColor) {
        self.init(
            srgbRed: CGFloat(color.red),
            green: CGFloat(color.green),
            blue: CGFloat(color.blue),
            alpha: CGFloat(color.alpha)
        )
    }
}
