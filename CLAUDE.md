# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 概要

Sony α で JPG + ARW を同時記録した写真を高速に選別する macOS 26 向け SwiftUI アプリ。仕様の正本は [Docs/仕様.md](Docs/仕様.md)、Sony MakerNote の調査結果は [Docs/メタデータ調査.md](Docs/メタデータ調査.md)、進捗は [Docs/実装計画-JPPhotoPicker.md](Docs/実装計画-JPPhotoPicker.md)。挙動を変えるときはまず仕様.md を確認し、仕様側も更新する。

## コマンド

```bash
# ロジックのテスト（Swift Testing）
cd Packages/JPPhotoPickerCore && swift test
swift test --filter ZoomStateTests          # スイート単位
swift test --filter "ZoomStateTests/<関数名>" # 1件だけ

# アプリのビルド（JPPhotoPicker.xcodeproj は git 管理外。project.yml から生成する）
xcodegen generate
xcodebuild -project JPPhotoPicker.xcodeproj -scheme JPPhotoPicker -configuration Debug build -quiet
```

- Swift 6.0 / `SWIFT_STRICT_CONCURRENCY: complete`。並行性の警告・エラーを出さないこと
- ファイルを追加・削除したら `xcodegen generate` をやり直す（`project.yml` は `App/` をまるごとソースにしている）

### 開発用の起動引数（DEBUG ビルドのみ、`App/DebugSnapshot.swift`）

GUI を目視せずに動作を確かめる仕組み。

```bash
<ビルドした JPPhotoPicker.app>/Contents/MacOS/JPPhotoPicker \
  -openFolder /path/to/folder \
  -debugScript "wait,z,next,p,log:/tmp/state.txt,snap:/tmp/shot.png,quit"
```

ステップ: `wait` `next` `prev` `nextGroup` `z` `esc` `f` `i` `p` `x` `undo` `apply` `confirmApply` `undoApply` `confirmUndoApply` `ok` `quit` `open:<パス>` `goto:<id>` `log:<ファイル>`（モデル状態を1行追記） `snap:<png>`（ウインドウ画像を保存）。

## 構成

2層に分かれている。**判定・グループ化・メタデータ・ズーム計算などの純粋なロジックは `Packages/JPPhotoPickerCore` に置いて `swift test` で検証し**、`App/` は画面・画像デコード・AppKit 連携だけを持つ。新しいロジックはテストできるよう Core 側に置く。

### JPPhotoPickerCore

- `Metadata/` — exiftool に依存しない自前パーサー。JPEG の先頭（APP1 / APP2 MPF）だけを読み、Exif・Orientation・IFD1 サムネイル位置・MPF プレビュー位置と Sony MakerNote（`ReleaseMode` / `SequenceNumber` / `FocusLocation` / `FocusFrameSize`）を取り出す。ARW は TIFF 構造から同じ情報を読む。`FocusFrameSize` / `FocusLocation` は型宣言が undefined のことがあるため u16 として生読みしている
- `Geometry/FocusGeometry` — フォーカス位置を 0〜1 の比率にし、Orientation に合わせて変換する（座標はセンサー向きで記録されている）
- `Library/` — `FolderScanner`（JPG/ARW のペア付け、大文字小文字無視）→ `BurstGrouper`（連写グループ化）→ `Decision`/`DecisionHistory`（判定と取り消し履歴、`DecisionBook`）→ `SessionStore`（`.jpphotopicker.json`、version 付き。新しい版のファイルは読み取り専用扱い）→ `ApplyEngine`（`_rejected/` への一括移動と取り消し）
- `Viewer/` — `ZoomState`（全体 / 100% / 200% / ピンチ倍率、コマ移動時の位置保持ルール）と `ViewportGeometry`

### App

- `Browser/BrowserModel` — `@MainActor @Observable` の中心。コマ一覧・判定・ズーム・保存（遅延書き込み、終了時に flush）・適用の状態をすべて持ち、ビューとキー操作はこのメソッドを呼ぶだけ
- `Imaging/ImagePipeline` — サムネイル / 大プレビュー（MPF 1920px、仮表示）/ 全体表示用（本体を画面の画素数に縮小）/ 本体の4段階。種類ごとの `OperationQueue` でデコードし（Swift の協調プールを塞がない）、同じ画像の要求は1ジョブにまとめ、`NSCache` に置く。サムネイル以外は **IOSurface に描いてから持つ**（CGImage をレイヤーに渡すと、コミット時にメインスレッドで色変換・コピーが走り、コマ送りが 1 回 40ms ほど止まる）。ARW だけのファイルは埋め込み JPEG、全体表示・拡大時は RAW 現像
- `Viewer/ZoomableImageView` — ピンチ・ドラッグ・スクロール・クリックを NSView で受けて `BrowserModel` に渡す
- `AppLifecycle` — 適用・取り消しの実行中は終了やウインドウのクローズを止める

## 仕様上の要注意点（コードだけでは分かりにくいもの）

- 連写グループは「ファイル番号 − SequenceNumber + 1」（連写の先頭番号）で区切る。撮影時刻の差では区切らない
- 1コマだけの連写グループは単写として扱う（表示とグループ移動のみ。移動のルールは連写も単写も同じ）
- 適用時は採用以外（未判定・不採用）を連写・単写とも移動する。採用がひとつも無いときは確認で全コマが移ることを警告する
- JPG と ARW のペアは必ずそろって移す。片方が失敗したら戻して、そのペアは失敗一覧に出す

## テストデータ

- 実画像サンプルは `~/Dropbox/受け渡し用フォルダ/連射インターバル/` にだけあり、無ければ該当テストは skip する。**リポジトリにコピーしない**。期待値は exiftool の実測値として `Tests/.../SampleData.swift` に固定されている
- 実機の ARW サンプルは無い。ARW 関連は合成データ（`SyntheticJPEG.swift` など）でのみ検証している
