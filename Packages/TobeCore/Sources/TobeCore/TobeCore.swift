/// TobeCore の名前空間。
///
/// TobeCore は OS に依存しない純粋なロジック（ラベル生成、起動キー判定、状態遷移など）を置くパッケージで、
/// AppKit / ApplicationServices を import しない（design.md 2.1）。
/// 型名をモジュール名と同じ `TobeCore` にすると、`TobeCore.Foo` のようなモジュール修飾が型の参照と解釈されて
/// 壊れるため、別名にしている。
public enum TobeCoreModule {
    /// モジュール名。パッケージがリンクされていることの確認（スモークテスト）に使う。
    public static let name = "TobeCore"
}
