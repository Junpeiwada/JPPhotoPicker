#!/usr/bin/env bash
#
# release.sh — ローカルから 1 コマンドでリリースを発火する。
#
#   Tools/release.sh <version> [-y]
#   例: Tools/release.sh 1.2.0
#
# やること:
#   1. project.yml の MARKETING_VERSION を <version> に更新
#   2. xcodegen が入っていれば再生成（yml の妥当性を早期検証 + Info.plist を更新）
#   3. project.yml と JPPhotoPicker-Info.plist をコミット
#   4. タグ v<version> を打って push（main と タグ の両方）
#   → GitHub Actions の Release ワークフローが自動で署名・公証・配布・appcast 更新まで実行する。
#
# CURRENT_PROJECT_VERSION（ビルド番号）は CI が run 番号で上書きするため手動更新は不要。
# 詳細は Docs/リリース手順.md を参照。
set -euo pipefail

# --- リポジトリルートへ移動（Tools/ からでもルートからでも動くように）---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${ROOT}"

PROJECT_YML="project.yml"
INFO_PLIST="JPPhotoPicker-Info.plist"
ASSUME_YES=0

# project.yml から現在の MARKETING_VERSION を取り出す。取れなければ空を返す。
#
# ★ grep を使わないこと。このスクリプトは `set -euo pipefail` なので、
#   grep が 1 行も拾えないと終了コード 1 → コマンド置換の代入が
#   set -e に捕まり、**何のメッセージも出さずにスクリプトごと死ぬ**。
#   sed -n の p は該当が無くても終了コード 0 なので安全に空を返せる。
#
# ★ 引用符の有無を問わず値だけを取ること。`MARKETING_VERSION: 0.1.2` のように
#   引用符無しで書かれた場合、引用符前提の抽出は「行全体」を返してしまい、
#   下の重複チェックが永久に偽になって上げ忘れ検出が黙って無効化される。
#
# ★ `\s` は GNU 拡張で BSD（macOS）の sed/grep では使えない。[[:space:]] を使う。
current_marketing_version() {
  [ -f "${PROJECT_YML}" ] || return 0
  sed -nE 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*"?([^"[:space:]]+)"?.*/\1/p' \
    "${PROJECT_YML}" | head -1
}

# 次に出すべきバージョンを提案する。現在の X.Y.Z の Z（パッチ）だけを +1 した値を返す。
#
# 元は project.yml の MARKETING_VERSION だが、タグの方が先に進んでいることがある
# （コミットを戻した、yml の更新だけ取り消した等）。両方を見て「大きい方」を基準に
# しないと、既にリリース済みの番号を提案してしまい重複チェックで弾かれる。
#
# ★ X.Y.Z 形式でないものは扱わない（空を返す）。無理に推測して誤った番号を
#   既定値として提示するより、入力を促す方が安全。
suggest_next_version() {
  local base
  base="$(current_marketing_version)"

  # タグ側の最新（v を落とした X.Y.Z のみ）
  local latest_tag
  latest_tag="$(git tag -l 'v[0-9]*.[0-9]*.[0-9]*' --sort=-v:refname 2>/dev/null \
    | sed -nE 's/^v([0-9]+\.[0-9]+\.[0-9]+)$/\1/p' | head -1)"

  # 大きい方を基準にする。sort -V は BSD/macOS でも使える。
  if [ -n "${latest_tag}" ]; then
    if [ -z "${base}" ]; then
      base="${latest_tag}"
    else
      base="$(printf '%s\n%s\n' "${base}" "${latest_tag}" | sort -V | tail -1)"
    fi
  fi

  [[ "${base}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 0

  local major minor patch
  major="${base%%.*}"
  patch="${base##*.}"
  minor="${base#*.}"; minor="${minor%%.*}"
  printf '%s.%s.%s\n' "${major}" "${minor}" "$((patch + 1))"
}

# --- 引数パース ---
VERSION=""
for arg in "$@"; do
  case "${arg}" in
    -y|--yes) ASSUME_YES=1 ;;
    -h|--help)
      # 先頭のバナーコメントブロックだけを表示（本文中の # コメントは出さない）。
      awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"
      exit 0 ;;
    -*) echo "エラー: 不明なオプション: ${arg}" >&2; exit 1 ;;
    *)  VERSION="${arg}" ;;
  esac
done

# バージョン未指定なら、端末なら対話で尋ねる（VSCode の npm パネルからクリック実行した
# 場合など引数を渡せないケース向け）。端末でなければエラーにする。
if [ -z "${VERSION}" ]; then
  if [ -t 0 ]; then
    # 既に出したバージョンを尋ねる前に見せる。番号を思い出せずに
    # リリース済みの値を入力してしまうのを防ぐ。
    # この時点では project.yml の存在チェックをまだ通っていないが、
    # current_marketing_version がファイルの有無を見るので止まらない。
    CURRENT_HINT="$(current_marketing_version)"
    if [ -n "${CURRENT_HINT}" ]; then
      echo "現在のバージョン: ${CURRENT_HINT}"
    fi

    EXISTING="$(git tag -l 'v*' --sort=-v:refname 2>/dev/null | head -10)"
    if [ -n "${EXISTING}" ]; then
      echo "リリース済みのバージョン（新しい順）:"
      printf '%s\n' "${EXISTING}" | sed 's/^/  /'
    else
      echo "リリース済みのバージョンはまだありません。"
    fi
    echo ""

    # パッチを +1 した値を既定値として提示する。Enter だけで採択できるようにし、
    # 別の番号（マイナー/メジャー上げなど）を出したいときは打ち直せばよい。
    SUGGESTED="$(suggest_next_version)"
    if [ -n "${SUGGESTED}" ]; then
      printf "リリースするバージョンを入力してください [%s]: " "${SUGGESTED}"
    else
      printf "リリースするバージョンを入力してください（例: 1.2.0）: "
    fi
    read -r VERSION
    # 空入力（Enter のみ）は提案値の採択とみなす。提案が作れなかった場合は
    # 空のままにして、下の未指定チェックにエラーを出させる。
    if [ -z "${VERSION}" ]; then
      VERSION="${SUGGESTED}"
    fi
  fi
fi
if [ -z "${VERSION}" ]; then
  echo "エラー: バージョンを指定してください（例: Tools/release.sh 1.2.0）" >&2
  exit 1
fi

# --- バージョン形式チェック（セマンティックな X.Y.Z）---
if ! [[ "${VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "エラー: バージョンは X.Y.Z 形式で指定してください（例: 1.2.0）。指定値: ${VERSION}" >&2
  exit 1
fi
TAG="v${VERSION}"

# --- 事前チェック ---
if [ ! -f "${PROJECT_YML}" ]; then
  echo "エラー: ${PROJECT_YML} が見つかりません。" >&2
  exit 1
fi

CURRENT="$(current_marketing_version)"
if [ -z "${CURRENT}" ]; then
  # 抽出できないのは書式が変わった等の異常。黙って進むと下の重複チェックが
  # 素通りし、更新用の sed も空振りして「nothing to commit」で落ちる。
  echo "エラー: ${PROJECT_YML} から MARKETING_VERSION を読み取れませんでした。" >&2
  echo "  書式が変わっていないか確認してください（期待: MARKETING_VERSION: \"X.Y.Z\"）。" >&2
  exit 1
fi

# --- バージョンの重複チェック ---
#
# 「既に出したバージョンをもう一度指定してしまった」を、他のどのチェックよりも
# 先に、具体的な理由を添えて弾く。ここを後ろに置くと、ワーキングツリーが
# 汚れている等の別のエラーが先に出てしまい、本当の原因が分からなくなる。
#
# 重複を検出する観点は 3 つ。どれか 1 つでも当たればリリース済みとみなす:
#   - project.yml が既にそのバージョン（＝上げ忘れ。sed が空振りしてコミットが
#     「nothing to commit」で落ちるが、その時点では理由が分からない）
#   - ローカルにタグがある
#   - リモートにタグがある（ローカルのタグを消して再実行した場合に効く）
DUPLICATE=0

if [ "${CURRENT}" = "${VERSION}" ]; then
  echo "エラー: project.yml の MARKETING_VERSION は既に ${VERSION} です。" >&2
  DUPLICATE=1
fi

if git rev-parse -q --verify "refs/tags/${TAG}" >/dev/null; then
  echo "エラー: タグ ${TAG} は既にローカルに存在します。" >&2
  DUPLICATE=1
fi

# リモートも見る。ローカルのタグだけ削除して再実行すると、ローカルの検査だけでは
# すり抜けて push で初めて失敗する。ネットワークが無い場合は検査を諦めて続行する
# （ここで止めるとオフラインでの作業が一切できなくなるため）。
#
# ★ 参照名を ls-remote に直接渡し、こちらでパターンマッチしない。
#   出力を grep すると TAG に含まれるドットが「任意の 1 文字」として効き、
#   v0X1X2 のような別のタグを v0.1.2 と誤検出する。
#
# ★ stderr は捨てずに見せる。失敗理由はオフラインとは限らず（認証失敗、
#   origin 未設定、リポジトリ削除など）、「ネットワーク未接続？」とだけ
#   出すと原因の切り分けを誤らせる。
if REMOTE_TAG_REF="$(git ls-remote --tags origin "refs/tags/${TAG}" 2>&1)"; then
  if [ -n "${REMOTE_TAG_REF}" ]; then
    echo "エラー: タグ ${TAG} は既にリモートに存在します（リリース済み）。" >&2
    DUPLICATE=1
  fi
else
  echo "警告: リモートのタグを確認できませんでした。重複の検査を省略します。理由:" >&2
  printf '%s\n' "${REMOTE_TAG_REF}" | sed 's/^/  /' >&2
fi

if [ "${DUPLICATE}" -ne 0 ]; then
  echo "" >&2
  echo "${VERSION} は既にリリース済みか、リリースの準備が済んでいます。" >&2
  echo "新しいバージョン番号を指定してください。既存のリリース:" >&2
  git tag -l 'v*' --sort=-v:refname | head -5 | sed 's/^/  /' >&2
  echo "" >&2
  echo "同じバージョンでリリースをやり直す場合は、先にタグを削除してください:" >&2
  echo "  git tag -d ${TAG} && git push origin :refs/tags/${TAG}" >&2
  exit 1
fi

BRANCH="$(git branch --show-current)"
if [ "${BRANCH}" != "main" ]; then
  echo "警告: 現在のブランチは '${BRANCH}' です（通常は main でリリースします）。" >&2
fi

# ワーキングツリーが汚れていると、意図しない変更を巻き込んでコミットしてしまう。
if [ -n "$(git status --porcelain)" ]; then
  echo "エラー: コミットされていない変更があります。先に整理してから実行してください:" >&2
  git status --short >&2
  exit 1
fi

echo "現在のバージョン: ${CURRENT:-不明}"
echo "新しいバージョン: ${VERSION}（タグ ${TAG}）"

# --- 発射確認（push はリリースを本番発火するため）---
if [ "${ASSUME_YES}" -ne 1 ]; then
  printf "この内容でリリースを発火します。よろしいですか？ [y/N] "
  read -r ANSWER
  case "${ANSWER}" in
    y|Y|yes|YES) ;;
    *) echo "中止しました。"; exit 0 ;;
  esac
fi

# --- 1. MARKETING_VERSION を更新（BSD/macOS sed）---
sed -i '' -E "s/^([[:space:]]*MARKETING_VERSION:[[:space:]]*)\"[^\"]*\"/\1\"${VERSION}\"/" "${PROJECT_YML}"
echo "→ ${PROJECT_YML} の MARKETING_VERSION を ${VERSION} に更新しました。"

# --- 2. xcodegen があれば再生成（yml の妥当性検証 + Info.plist 更新）---
#     .xcodeproj は Git 管理外だが、Info.plist は版管理しているので差分が出ることがある。
if command -v xcodegen >/dev/null 2>&1; then
  xcodegen generate >/dev/null
  echo "→ xcodegen generate 実行済み（プロジェクトと Info.plist を再生成）。"
else
  echo "→ xcodegen 未インストールのためローカル再生成はスキップ（CI 側で生成されます）。"
fi

# --- 3. コミット ---
git add "${PROJECT_YML}"
# Info.plist は MARKETING_VERSION を $(...) 参照で持つため通常は差分が出ないが、
# 生成器の更新等で変わることがあるので、変化していれば一緒にコミットする。
if [ -f "${INFO_PLIST}" ] && ! git diff --quiet -- "${INFO_PLIST}"; then
  git add "${INFO_PLIST}"
fi
git commit -m "${TAG} へバージョンを上げる"
echo "→ バージョン変更をコミットしました。"

# --- 4. タグを打って push ---
git tag "${TAG}"
git push origin "${BRANCH}"
git push origin "${TAG}"
echo "→ ${BRANCH} と ${TAG} を push しました。"

echo ""
echo "✅ リリースを発火しました。GitHub の Actions → Release ワークフローの完了を確認してください。"
echo "   Release ページに zip、gh-pages に更新後の appcast.xml が反映されます。"
