# perch

[English](README.md) · **日本語**

macOS 用のキーボード駆動 UI ナビゲータ。グローバルホットキー
を押すと前面アプリの全クリック要素にラベルが表示され、その
ラベルを打つだけでクリックできる。マウスもトラックパッドも
不要。

> ネイティブ Mac アプリ (AppKit / SwiftUI) を対象とし、
> Chrome / Electron は MVP では対象外。

![macOS 13+](https://img.shields.io/badge/macOS-13%2B-blue)
![Swift 6](https://img.shields.io/badge/Swift-6-orange)
![MIT](https://img.shields.io/badge/license-MIT-green)

## 動作

1. ホットキーを押す (デフォルト: `shift+space`)。
2. 前面アプリのクリック可能要素すべてに、1〜2 文字のラベル
   が「pill (薬カプセル状)」で表示される。ホームロー
   (`asdf jkl;`) を優先、画面中央付近の要素から短いキーが
   割り当てられる。
3. ラベルをタイプ → `AXUIElementPerformAction` が発火して
   クリック。仮想マウスクリックではなく、フォーカスも動かない。
4. Esc でキャンセル。マッチしない文字をタイプしても解除。

### アクション修飾キー

ラベルを打つときに以下を押さえると、アクションが変わる:

| 修飾キー | アクション | AX 呼び出し |
|---|---|---|
| *(なし)* | クリック | `AXPress` |
| **Shift** | 右クリック / コンテキストメニュー | `AXShowMenu` |
| **Cmd** | 要素のタイトルをクリップボードへ | pasteboard |
| **Alt** | フォーカスのみ — 発火しない | `AXFocused = true` |

Cmd-copy はコントロールの表示名を打ち直さずに取得するのに便利。
Alt-focus は入力したいテキストフィールドに向く。Ctrl は触らないので
システムショートカット(Ctrl-A 等)はそのまま — overlay 中に Ctrl を
押すとキャンセル。

デフォルトで対象とする AX ロール:
`Button`, `MenuItem`, `Link`, `Tab`, `CheckBox`, `RadioButton`,
`PopUpButton`, `TextField`, `SearchField`, `TabGroup`,
`MenuButton`。追加・削減は
[`config.toml`](config.toml) で行う。

## インストール

```sh
brew install akira-toriyama/tap/perch
curl --create-dirs -o ~/.config/perch/config.toml \
  https://raw.githubusercontent.com/akira-toriyama/perch/main/config.toml
perch                              # デーモン起動
# 初回はアクセシビリティ権限を許可
```

またはソースからビルド:

```sh
git clone https://github.com/akira-toriyama/perch
cd perch
./setup-signing-cert.sh            # TCC 維持用の永続署名 (1 回)
./run.sh                           # Perch.app をビルドして起動
```

## 設定

`~/.config/perch/config.toml` が唯一の真実の在り処。perch は
このファイルを **読むだけ** で、書き込まない。

```toml
[hotkey]
active = "shift+space"
cancel = "esc"                   # キャンセルキー(モディファイア不可)

[labels]
alphabet = "asdfjklghqweruiopzxcvbnm"
prioritise-center = true

[overlay]
accent = "system"                # マッチ中ピル/入力済プリフィックスのアクセント
                                 # "system" = macOS のアクセントカラー、#rrggbb 可
font-size = 14                   # 8..32  monospaced semibold
blur-enabled = true              # ピル背景のフロスト(磨りガラス)
anim-enabled = true              # 出現 150ms scale-in + ミス時 200ms 赤フラッシュ

[behavior]
auto-click-on-unique = true
roles = ["Button", "MenuItem", "Link", "Tab", ...]
exclude-apps = []
```

編集後の反映: `perch --reload` (デーモン稼働中ならファイル保存
で自動再読み込み)。

## CLI

| フラグ | モード | 用途 |
|---|---|---|
| *(なし)* | server | デーモンを実行 |
| `--debug` | server | stderr にもログ |
| `--validate` | standalone | config.toml を検証 |
| `--doctor` | standalone | ヘルスチェック (AX / 設定 / デーモン / ホットキー) |
| `--activate` | client | ヒント overlay を表示 (ホットキーの代替) |
| `--cancel` | client | overlay 表示中ならキャンセル |
| `--reload` | client | デーモンに設定再読み込みを通知 |
| `--quit` | client | デーモンを終了 |
| `--status` | client | 現在のホットキー / 最終アクティベーションを表示 |
| `--help` | standalone | ヘルプ |

`--activate` / `--cancel` があるので Karabiner / skhd / Raycast の
スクリプトコマンドからも起動でき、perch 標準のホットキーを残した
まま別トリガーを併用できる。overlay 表示中は `Esc` で常にキャンセル、
ラベルにマッチしない文字をタイプしてもキャンセル。

終了コード: 0 = 成功 · 1 = `--doctor` が赤 · 2 = 不正な
フラグ / 設定 · 3 = デーモン未起動。

## 開発

```sh
swift build                      # コンパイル (CommandLineTools で可)
swift test                       # テスト — Xcode 必須
./run.sh                         # release を Perch.app として起動
./stop.sh                        # 起動中のすべての instance を停止
```

アーキテクチャは Core / Adapter / App の hexagonal 3 層
([docs/architecture.md](docs/architecture.md))。
[stroke](https://github.com/akira-toriyama/stroke) と
[facet](https://github.com/akira-toriyama/facet) と同じ構造。

コミット規約: gitmoji + Conventional Commits
([docs/commit-convention.md](docs/commit-convention.md))。
ローカルフックの有効化:

```sh
git config core.hooksPath scripts/hooks
```

## ライセンス

MIT — [LICENSE](LICENSE) を参照。
