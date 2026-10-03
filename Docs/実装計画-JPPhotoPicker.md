# 実装計画-JPPhotoPicker

## 変更履歴

| 日付 | 変更者 | 変更内容 |
| --- | --- | --- |
| 2026-09-29 | Claude | ユーザー判断により、1コマだけの連写を単写として扱うルールと、ペアをそろって移す（片方が失敗したら両方移さない）ルールを実装した。 |
| 2026-09-29 | Claude | 再レビューの指摘（重大1・中6）を修正してフェーズ7を完了し、バッジのガラスの見え方（目視が必要）だけ見送った。 |
| 2026-09-29 | Claude | 1回目のレビュー指摘を修正し、見送りは L9・L14・app-15・app-24、ユーザー判断待ちは M5（1枚だけの連写）と L12（ペアの片方だけ移動）とした。 |
| 2026-09-29 | Claude | フェーズ3〜6を完了し、DEBUG 用の操作再生とスナップショット（App/DebugSnapshot.swift）とピンチ等を NSView で受ける構成を追加した。 |
| 2026-09-29 | Claude | フェーズ1・2を完了。Sony の FocusFrameSize/FocusLocation は型宣言が undefined のことがあるため u16 の生読みにした。判定と履歴は `Decision.swift` に `DecisionBook`（判定一覧＋履歴）を追加し、フォルダ走査に `PhotoItem` とメタデータの並列読み取り `PhotoMetadataLoader` を置いた。 |
| 2026-09-29 | Claude | 初版作成。仕様.md の全機能を7フェーズ（基盤〜レビュー）に分けた。 |

## 概要

[仕様.md](仕様.md) の JPPhotoPicker を新規に作る。判定・グループ化・メタデータ読み取りなどのロジックは Swift Package `JPPhotoPickerCore` に置いて `swift test` で検証し、画面は XcodeGen で生成する macOS アプリ `JPPhotoPicker` に置く。

- **対象**: 仕様.md の「決定事項」〜「速度設計」のすべて
- **やらないこと**: 仕様.md の「対象外」、未決事項（キャッシュ上限は仮値で実装し、実測は後で行う）、コミット
- **関連**: [仕様.md](仕様.md) / [メタデータ調査.md](メタデータ調査.md)
- **進め方**: 実装は Sonnet のサブエージェントに任せる。全フェーズの後に code-reviewer でレビュー → 修正 → 再レビュー → 修正

## 進捗

**現在**: 全フェーズ完了（次の一手: 実機での目視確認）

| フェーズ | 状態 | 完了 | 備考 |
| --- | --- | --- | --- |
| 1. 基盤とメタデータ読み取り | ✅ 完了 | 6/6 | — |
| 2. グループ化・判定・保存 | ✅ 完了 | 6/6 | — |
| 3. 画面と選別操作 | ✅ 完了 | 7/7 | 実キー入力・ガラス表現の目視確認が残る |
| 4. 拡大表示とフォーカス | ✅ 完了 | 6/6 | ピンチ・ドラッグ・クリックの目視確認が残る |
| 5. ARW だけのファイル | ✅ 完了 | 4/4 | 実機 ARW が無く合成データとダミーでのみ確認 |
| 6. 適用（一括移動） | ✅ 完了 | 4/4 | コピーのフォルダで適用→取り消しを通しで確認済み |
| 7. レビューと修正 | ✅ 完了 | 4/4 | 2回のレビュー指摘を修正、テスト113件 pass |

> 状態: ⬜ 未着手 / 🔄 進行中 / ✅ 完了 / ⏸️ 保留。タスクは `- [ ]` / `- [x]`。
> フェーズ内の全タスクが `- [x]` になったら ✅ にする。備考は1行まで（詳細は各フェーズ本文へ）。

### 更新のきまり

- 更新は実装したターン内で行う（「動いた＝更新済み」と錯覚しない）
- **状態はこの表だけに書く**。フェーズ見出しには書かない
- 変更履歴は**新しい行を上に**足す。1行1文
- 計画とズレたら計画側を直し、変更履歴に残す

---

## フェーズ1: 基盤とメタデータ読み取り

**目標**: JPG の先頭を読むだけで、連写・フォーカス・サムネイル・MPF プレビューの情報が取れる

### タスク

- [x] **P1-1**: プロジェクトの骨組みを作る。`project.yml`（XcodeGen、macOS 26、アプリ `JPPhotoPicker`）、`Packages/JPPhotoPickerCore/Package.swift`、`.gitignore`
- [x] **P1-2**: TIFF / IFD の読み取り（エンディアン、IFD0・ExifIFD・IFD1 のたどり方）（`Packages/JPPhotoPickerCore/Sources/JPPhotoPickerCore/Metadata/TIFFReader.swift`）
- [x] **P1-3**: JPEG の APP1 と APP2(MPF) を探し、Exif・撮影時刻（SubSec・タイムゾーン込み）・Orientation・IFD1 サムネイル位置・MPF 2枚目の位置を取り出す（`.../Metadata/JPEGMetadataReader.swift`）
- [x] **P1-4**: Sony MakerNote（`SONY DSC \0\0\0` ヘッダー）から `ReleaseMode` / `SequenceNumber` / `FocusLocation` / `FocusFrameSize` を取り出す（`.../Metadata/SonyMakerNote.swift`）
- [x] **P1-5**: 結果をまとめる型 `PhotoMetadata` と、フォーカス位置の比率化・Orientation 変換（`.../Metadata/PhotoMetadata.swift`、`.../Geometry/FocusGeometry.swift`）
- [x] **P1-6**: 単体テスト。サンプル（`~/Dropbox/受け渡し用フォルダ/連射インターバル/`、無ければ skip）で exiftool の実測値と一致すること、Orientation 1〜8 の座標変換（`Packages/JPPhotoPickerCore/Tests/JPPhotoPickerCoreTests/`）

### 完了確認

```bash
cd Packages/JPPhotoPickerCore && swift test
# 期待: 全件 pass（A1_07913 → ReleaseMode 2, Seq 1, FocusLocation 8640 4864 5805 2452 など）
```

---

## フェーズ2: グループ化・判定・保存

**目標**: フォルダを渡すと、並び・連写グループ・判定状態・移動対象が決まり、`.jpphotopicker.json` に保存・復元できる

### タスク

- [x] **P2-1**: フォルダの走査。JPG と ARW を拡張子の大文字小文字を区別せずに対応付け、ペア / JPG だけ / ARW だけに分ける（`.../Library/FolderScanner.swift`）
- [x] **P2-2**: 並べ替えと連写グループ化（先頭番号 = ファイル番号 − SequenceNumber + 1、番号が取れないときの代替ルール）（`.../Library/BurstGrouper.swift`）
- [x] **P2-3**: 判定モデル（未判定 / 採用 / 不採用）と、適用時に移すかどうかのルール（`.../Library/Decision.swift`）
- [x] **P2-4**: 取り消し / やり直しの履歴（どのコマの判定かを持つ）（`.../Library/DecisionHistory.swift`）
- [x] **P2-5**: `.jpphotopicker.json` の保存と読み込み（判定、適用の記録）（`.../Library/SessionStore.swift`）
- [x] **P2-6**: 単体テスト（区切りはサンプル47枚の先頭番号表と一致、移動ルール、履歴、保存の往復）

### 完了確認

```bash
cd Packages/JPPhotoPickerCore && swift test
# 期待: 全件 pass
```

---

## フェーズ3: 画面と選別操作

**目標**: フォルダを開いてプレビューとフィルムストリップで選別でき、キーで判定・自動送り・取り消しができる

### タスク

- [x] **P3-1**: アプリの入口と状態（`App/JPPhotoPickerApp.swift`、`App/Browser/BrowserModel.swift`）。⌘O・ドラッグ&ドロップでフォルダを開く
- [x] **P3-2**: 画像の読み込みとキャッシュ（サムネイル / MPF プレビュー / 本体、NSCache、前後 N 枚の先読み）（`App/Imaging/ImagePipeline.swift`）
- [x] **P3-3**: 大プレビューと状態バッジ（`App/Browser/PreviewView.swift`）
- [x] **P3-4**: フィルムストリップ（連写グループの枠と背景、採用は緑・不採用は暗く）（`App/Browser/FilmstripView.swift`）
- [x] **P3-5**: ツールバー（フォルダ名、採用・不採用・残りの数、[適用]）（`App/Browser/BrowserView.swift`）
- [x] **P3-6**: キー操作（←→↑↓ P X U ⌘Z ⇧⌘Z）、判定後の自動送り、取り消しでそのコマへ戻る（`App/Browser/KeyCommands.swift`）
- [x] **P3-7**: 設定画面（⌘,、先読み枚数 初期値4、UserDefaults）（`App/Settings/SettingsView.swift`）

### 完了確認

```bash
xcodegen generate && xcodebuild -project JPPhotoPicker.xcodeproj -scheme JPPhotoPicker -configuration Debug build -quiet
# 期待: ビルド成功（警告は許容、エラー 0）
```

- [ ] サンプルフォルダを開き、→・P・X・⌘Z が仕様どおりに動く（目視）

---

## フェーズ4: 拡大表示とフォーカス

**目標**: Z・クリック・ピンチで拡大し、フォーカス位置と表示位置の保持が仕様どおりに動く

### タスク

- [x] **P4-1**: 拡大の状態とルールを純粋なロジックで持つ（全体 / 100% / 200% / 自由倍率、Z の段階送り、コマ移動時の位置保持）（`.../Viewer/ZoomState.swift`）
- [x] **P4-2**: ZoomState の単体テスト（仕様.md「拡大表示」の表の全行）
- [x] **P4-3**: 拡大表示のビュー（本体デコード、ドラッグ・2本指スクロールで移動、ピンチ、クリック）（`App/Viewer/ZoomableImageView.swift`）
- [x] **P4-4**: Z / Esc / F キーと [フォーカス位置へ] ボタン（`App/Browser/KeyCommands.swift`、`App/Browser/PreviewView.swift`）
- [x] **P4-5**: フォーカス枠の描画と ⇧F での切り替え（`App/Viewer/FocusFrameOverlay.swift`）
- [x] **P4-6**: 拡大表示中のグループ内先読み（`App/Imaging/ImagePipeline.swift`）

### 完了確認

```bash
cd Packages/JPPhotoPickerCore && swift test && cd ../.. && xcodebuild -project JPPhotoPicker.xcodeproj -scheme JPPhotoPicker build -quiet
# 期待: テスト全件 pass、ビルド成功
```

- [ ] A1_07913 で Z を押すと被写体（フォーカス枠）が中央に来る。縦位置 A1_01309 でも枠が正しい位置に出る（目視）

---

## フェーズ5: ARW だけのファイル

**目標**: ペアの JPG がない ARW も表示・選別でき、左上に ARW マークが出る

### タスク

- [x] **P5-1**: ARW（TIFF 構造）から Exif・MakerNote を読む（`.../Metadata/ARWMetadataReader.swift`）。サンプルが無いので、読めないタグは「なし」として扱う
- [x] **P5-2**: ARW のプレビュー・サムネイル（ImageIO の埋め込み JPEG）と、拡大時の RAW 現像（`App/Imaging/ImagePipeline.swift`）
- [x] **P5-3**: プレビューとフィルムストリップの左上に ARW マーク（`App/Browser/PreviewView.swift`、`App/Browser/FilmstripView.swift`）
- [x] **P5-4**: 単体テスト（TIFF 構造の合成データで読み取り、ARW だけのファイルの移動ルール）

### 完了確認

```bash
cd Packages/JPPhotoPickerCore && swift test
# 期待: 全件 pass
```

---

## フェーズ6: 適用（一括移動）

**目標**: 「適用」で `_rejected/` に JPG と ARW を移し、取り消しで元に戻せる

### タスク

- [x] **P6-1**: 移動の実行（`_rejected/` 作成、rename、衝突・失敗は飛ばして記録）（`.../Library/ApplyEngine.swift`）
- [x] **P6-2**: 適用の取り消し（`.jpphotopicker.json` の記録から戻す）（`.../Library/ApplyEngine.swift`）
- [x] **P6-3**: 確認ダイアログ（JPG と ARW の枚数）と失敗一覧の表示、適用の取り消しメニュー（`App/Browser/ApplyFlow.swift`）
- [x] **P6-4**: 単体テスト（一時ディレクトリで移動・衝突・取り消し）

### 完了確認

```bash
cd Packages/JPPhotoPickerCore && swift test && cd ../.. && xcodebuild -project JPPhotoPicker.xcodeproj -scheme JPPhotoPicker build -quiet
# 期待: テスト全件 pass、ビルド成功
```

- [ ] サンプルのコピーで適用 → 取り消しをして、ファイルが元に戻る（目視）

---

## フェーズ7: レビューと修正

**目標**: 独立したレビューの指摘のうち妥当なものを直し、再レビューでも重大な指摘が残らない

### タスク

- [x] **P7-1**: code-reviewer で全体レビュー（仕様との食い違い、正しさ、性能）
- [x] **P7-2**: 妥当な指摘を修正する（採否の理由を記録）
- [x] **P7-3**: 再レビュー
- [x] **P7-4**: 再レビューの妥当な指摘を修正する

### 完了確認

```bash
cd Packages/JPPhotoPickerCore && swift test && cd ../.. && xcodegen generate && xcodebuild -project JPPhotoPicker.xcodeproj -scheme JPPhotoPicker build -quiet
# 期待: テスト全件 pass、ビルド成功
```

---

## 全体の完了基準

- [ ] 仕様.md の決定事項・キー操作・拡大表示・適用がすべて実装されている
- [ ] `swift test` 全件 pass、`xcodebuild build` 成功
- [ ] サンプルフォルダで選別 → 適用 → 取り消しが通しで動く（目視）

## 注意点

- 実画像のサンプルは `~/Dropbox/受け渡し用フォルダ/連射インターバル/` にだけある。リポジトリにはコピーしない（テストは無ければ skip）
- ARW のサンプルは無い。P5 は ImageIO と合成データで作り、実機 ARW での確認は後回し
- 5,000 枚で数秒以内に一覧を出すため、メタデータ読み取りはファイル先頭だけを読み、並列で行う
- Swift 6 の厳格な並行性チェックでビルドする

## ディレクトリ構成

```
JPPhotoPicker/
├── project.yml                     # XcodeGen
├── App/                            # アプリ本体（SwiftUI）
│   ├── JPPhotoPickerApp.swift
│   ├── Browser/  Imaging/  Viewer/  Settings/
├── Packages/JPPhotoPickerCore/       # ロジック（swift test で検証）
│   ├── Sources/JPPhotoPickerCore/{Metadata,Geometry,Library,Viewer}/
│   └── Tests/JPPhotoPickerCoreTests/
└── Docs/
```
