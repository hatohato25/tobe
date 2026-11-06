import CoreGraphics

/// 前面のウィンドウに隠れた要素・ウィンドウを除く（F-2.11、Q-12、design.md 8.1・8.6）。
///
/// `windows` には、レイヤー 0 のウィンドウだけでなく、メニューバー（`kCGMainMenuWindowLevel`）や
/// 開いているメニュー（`kCGPopUpMenuWindowLevel`）など全レイヤーのウィンドウを渡す。
/// 前後関係は `layer` ではなく `zIndex`（`CGWindowList` の並び順。0 が最前面）だけで決める。
/// メニューバーの項目はメニューバーのウィンドウを自分のウィンドウとして扱うので、それより前面のもの
/// （開いているメニューなど）だけで判定される。
public enum OcclusionFilter {
    /// 要素の中心点が、その要素のウィンドウより前面にあるウィンドウの frame に含まれていれば除外する。
    ///
    /// 中心点で判定するのは、代替クリック（design.md 10 章）が中心点を押すため。中心点が隠れている要素を
    /// 押すと、クリックが前面の別のウィンドウに当たる。
    ///
    /// 要素のウィンドウが `windows` にない場合も除外する。前後関係が分からず、押したときにクリックが
    /// どこに当たるかを保証できないため（収集とウィンドウ一覧は同じ列挙から作るので、通常は起きない）。
    ///
    /// 戻り値は入力の順序を保つ。
    public static func visibleElements(_ elements: [CollectedElement], windows: [WindowInfo]) -> [CollectedElement] {
        let frontToBack = windows.sorted { $0.zIndex < $1.zIndex }
        var zIndexByWindow: [WindowID: Int] = [:]
        for window in frontToBack where zIndexByWindow[window.id] == nil {
            zIndexByWindow[window.id] = window.zIndex
        }

        return elements.filter { element in
            guard let ownZIndex = zIndexByWindow[element.windowID] else { return false }
            let center = element.frame.center
            // `CGRect.contains(_: CGPoint)` は左端・上端を含み、右端・下端を含まない
            let isHidden = frontToBack.lazy
                .prefix { $0.zIndex < ownZIndex }
                .contains { $0.frame.rect.contains(center) }
            return !isHidden
        }
    }

    /// 画面全体に重ねられた、通常のレイヤーより上のウィンドウか（D-33）。
    ///
    /// 画面共有（Slack のハドルなど）や ⌘⇧5 は、画面全体を覆う見えないウィンドウを手前に置く。遮蔽の判定に入れると、
    /// すべての要素が隠れていることになってラベルが出ないため、呼び出し側で判定の入力から除く。
    /// クリックを素通りさせるかどうかはウィンドウの一覧からは分からないので、位置と大きさで見分ける。
    /// 全画面表示の通常のアプリはレイヤー 0 なので、ここには当てはまらない。
    public static func isFullScreenOverlay(_ window: WindowInfo, screens: [GlobalRect]) -> Bool {
        window.layer > 0 && screens.contains { !$0.rect.isEmpty && window.frame.rect.contains($0.rect) }
    }

    /// `window` が、それより前面にある 1 枚のウィンドウに完全に覆われているか。覆われていれば走査自体を省く
    /// （design.md 8.1 の手順 3）。
    ///
    /// 複数のウィンドウを合わせて覆われている場合は判定しない（見えている部分がないことの確認が重く、
    /// 走査を省けなくても遮蔽の判定で要素は除かれるため）。面積 0 のウィンドウは何も覆わない。
    public static func isFullyCovered(_ window: WindowInfo, by windows: [WindowInfo]) -> Bool {
        windows.contains { other in
            other.id != window.id
                && other.zIndex < window.zIndex
                && !other.frame.rect.isEmpty
                && other.frame.rect.contains(window.frame.rect)
        }
    }
}
