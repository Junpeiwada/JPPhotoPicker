# JPPhotoPicker

Sony α で JPG + ARW を同時記録した写真を、連写ごとにまとめて高速に選別する macOS アプリ。

採用したいコマにだけ印を付け、最後に「適用」すると、採用しなかったコマを JPG と ARW ごと、開いたフォルダの `_rejected/` へ移す。削除はしないので、「適用を取り消す」で元に戻せる。

## ダウンロード

[最新版（GitHub Releases）](https://github.com/Junpeiwada/JPPhotoPicker/releases/latest) から zip を落として展開し、`JPPhotoPicker.app` をアプリケーションフォルダへ入れる。紹介ページは <https://junpeiwada.github.io/JPPhotoPicker/>。

- Developer ID 署名・公証済みなので、初回起動で警告は出ない
- 起動のたびに新しい版を確認し、あればアプリ内で更新できる（Sparkle）。アプリメニューの「アップデートを確認…」からも確認できる。起動時の確認は設定画面（⌘,）で止められる

## 使い方

フォルダをウインドウにドロップするか、⌘O で開く。

| キー | 動作 |
|---|---|
| ← / → | 前 / 次の写真 |
| ⇧← / ⇧→ | 前 / 次のグループ（連写をまとめて飛ばす） |
| P | 採用（もう一度押すと外す） |
| Z | 拡大の切り替え（全体 → 100% → 200%。最初はフォーカス位置を拡大） |
| Esc | 全体表示に戻す |
| F | フォーカス位置へ移る |
| ⇧F | フォーカス枠の表示を切り替える |
| I | 撮影情報の表示を切り替える |
| ⌘Z / ⇧⌘Z | 判定の取り消し / やり直し |
| ⇧⌘A | 適用（確認ダイアログが出る） |

- 連写は Sony MakerNote の連写番号から自動でグループにまとまる。1コマだけの連写は単写として扱う
- 判定は「採用」だけ。採用していないコマは、連写・単写とも適用で移す
- 判定は開いたフォルダの `.jpphotopicker.json` に自動保存され、次に開くと最後に見ていたコマに戻る
- ペアの JPG が無い ARW も表示できる（埋め込みプレビューと RAW 現像）

詳しい仕様は [Docs/仕様.md](Docs/仕様.md)。

## 動作環境

- macOS 26 以降
- 写真は Mac の中だけで扱い、外部に送信しない。通信するのは更新の確認だけ

## ビルド

`.xcodeproj` は生成物なので版管理していない。[project.yml](project.yml) から生成する。

```sh
brew install xcodegen        # 未インストールなら
xcodegen generate
open JPPhotoPicker.xcodeproj
```

ロジック（メタデータの読み取り・連写のグループ化・判定・ズーム計算など）は Swift Package [Packages/JPPhotoPickerCore](Packages/JPPhotoPickerCore) にあり、単体でテストできる。

```sh
cd Packages/JPPhotoPickerCore && swift test
```

開発用の署名は `project.yml` で `Apple Development` / Team `L897K2C26B` に固定している。自分の環境でビルドするときは `DEVELOPMENT_TEAM` を自分の Team ID に変える。

リリースの出し方は [Docs/リリース手順.md](Docs/リリース手順.md)。

## ライセンス

[MIT](LICENSE)
