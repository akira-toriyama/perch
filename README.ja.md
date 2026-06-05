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

# アプリ単位の上書き — `roles` / `min-size` / `auto-click-on-unique`
# を bundle id ごとに差し替え。未設定キーは global の `[behavior]`
# にフォールバック（typo-tolerance policy の延長）。
[behavior."com.google.Chrome"]
min-size = 20                    # 16×16 ウィンドウコントロールを除外
```

編集後の反映: `perch --reload` (デーモン稼働中ならファイル保存
で自動再読み込み)。

## CLI

| フラグ | モード | 用途 |
|---|---|---|
| *(なし)* | server | デーモンを実行 |
| `--validate` | standalone | config.toml を検証 |
| `--doctor` | standalone | ヘルスチェック (AX / 設定 / デーモン / ホットキー) |
| `--activate` | client | ヒント overlay を表示 (ホットキーの代替) |
| `--scroll` | client | スクロールモード (`j/k/d/u/gg/G`, `esc` で抜ける) |
| `--search` | client | サーチモード (タイプして `1-9` で選択) |
| `--regional` | client | リージョナルモード — 大きいコンテナ (記事 / ペイン / 画像) だけにラベル |
| `--menu` | client | メニュー検索モード — 前面アプリのメニュー全体を fuzzy 検索 (深い項目も含む)、`1-9` で選択 |
| `--windows` | client | クロスアプリのウィンドウスイッチャー — 全アプリの全ウィンドウを fuzzy 検索、`1-9` でウィンドウを raise + 所有アプリを activate |
| `--emoji` | client | 絵文字ピッカー — 厳選した絵文字テーブルを名前で fuzzy 検索、`1-9` で caret に挿入（Unicode 注入 — pasteboard を汚さない）|
| `--grid` | client | 座標グリッド — 画面をラベル付きセルに分割、ラベルで合成 `CGEvent` クリック（Figma canvas / Photoshop / custom-drawn UI など hint mode が見えない領域の AX バイパス） |
| `--rgrid` | client | 再帰グリッド — 各ラベル選択でそのセルをさらに分割（最大 `[grid].max-depth` 段、既定 3 で 4K ≈ ピクセル精度）。`space` で現在セル中心クリック、`Backspace` で 1 段戻る |
| `--nudge` | client | 矢印 nudge カーソルモード — 矢印キーで 1/10/100/画面端 px 移動（modifier で段階切替）、`space` でクリック + 抜ける。`--grid` 後のラストマイル精度 |
| `--drag` | client | キーボードドラッグ — A まで nudge → `d` で grab（mouseDown）→ B まで nudge → `d` で release（mouseUp）。スプリッタ resize / 並び替え等の UI ドラッグ用 |
| `--cancel` | client | hint / scroll / search / regional / menu / windows / emoji / grid / rgrid / nudge / drag のうち動いてるモードをキャンセル |
| `--reload` | client | デーモンに設定再読み込みを通知 |
| `--quit` | client | デーモンを終了 |
| `--status` | client | 現在のホットキー / 最終アクティベーションを表示 |
| `--help` | standalone | ヘルプ |

### スクロールモード

`perch --scroll` (外部キーマッパで好きなキーに割当て可) で
スクロールモードに入る。以下を受け付ける:

| キー | 効果 |
|---|---|
| `j` | 1 ノッチ下スクロール |
| `k` | 1 ノッチ上スクロール |
| `d` / `Ctrl+d` | 半画面下 |
| `u` / `Ctrl+u` | 半画面上 |
| `Ctrl+f` | 1 画面下 |
| `Ctrl+b` | 1 画面上 |
| `<数字>` | 次のモーションの count プレフィクス（`5j` で 5 ノッチ、`12k` で 12 上） |
| `gg` | 一番上 |
| `Shift+g` | 一番下 |
| `esc` (or 設定したキャンセルキー) | 抜ける |
| その他のキー | 抜けて + キーは通過 |

Count プレフィクスは 200 で上限クランプ（`999999j` でデーモン
が固まらないように）。モーション発火時に消費、Esc / 未マップ
キーでクリアされる。`j` / `k` / `d` / `u` / `Ctrl+f` /
`Ctrl+b` に乗算。`gg` / `Shift+g` は count を **消費するが
乗算しない**（5 回トップへ移動は無意味）。`d` / `u` は vim
正統の `Ctrl+d` / `Ctrl+u` の alias として残す。

スクロールは `CGEvent.scrollWheelEvent` で前面ウィンドウに発射。
perch 自身は headless のままなのでフォーカスは奪わない。

### サーチモード

`perch --search` でサーチモード。要素数が多いアプリ(Xcode,
Logic, システム設定のサイドバー…)向け。要素の表示タイトルの
部分文字列をタイプ → マッチ要素に番号付きピル `1`〜`9` が乗る。
数字を押すとその要素を起動。

| キー | 効果 |
|---|---|
| 文字 / 数字 / 記号 / スペース | クエリに追加 |
| `backspace` | クエリから 1 文字削除 |
| `1`〜`9` (マッチがある時) | マッチ #N を起動 |
| `Enter` | マッチ #1 を起動 |
| `esc` (or 設定したキャンセルキー) | サーチモードを抜ける |

ヒントモードと同じ修飾キー規約: `Shift+1` で #1 を右クリック、
`Cmd+1` で #1 のタイトルをコピー、`Alt+1` でフォーカスのみ。

マッチが 0 件の時に数字をタイプすると、クエリ文字として扱われる
("v2" / "API 3" などを検索可能)。

### メニュー検索モード

`perch --menu` は `--search` の派生で、**前面アプリのメニュー全項目**
を再帰的に検索対象にする。マッチは Spotlight 風の中央寄せ縦リストで
描画 (メニュー項目は macOS が開くまで画面位置を持たないので、
要素ごとの pill 配置は使えない)。

メニューの 3 階層下にある "隠れコマンド" をマウスホバなしで一発で
呼べる:

- Safari の `Develop > Empty Caches` → `"empt"` とタイプ → `1`
- Xcode の `Editor > Refactor > Rename` → `"rename"` とタイプ
- システム設定のサイドバー項目、3 階層ホバが必要なアプリメニュー、
  すべて 1 キー + `1-9` で到達

修飾キー規約は `--search` と同じ: Cmd-1 でパスをコピー、Shift-1 で
コンテキストメニュー、Alt-1 でフォーカスのみ、Cmd+Shift-1 で発火 +
メニューモード継続 (連続発火)。

各 pill には AX バインドのキーボードショートカット（`⌘Q` /
`⇧⌘N` 等）が右側に薄色で表示される（issue #58）— Superkey 風の
学習ループ: `1-9` で選びつつ、ネイティブのショートカットを発見
できる。`config.toml` で `[overlay].show-shortcuts = false` に
すると非表示。

### グリッドモード（AX バイパス）

`perch --grid` は hint mode が **見えない** UI 用の明示的
フォールバック: Figma canvas、Photoshop、Logic、web `<canvas>`、
custom-drawn ビュー。AX に頼らず、画面を `[grid].cols ×
[grid].rows`（既定 12×8）のセル網に分割し、hint mode と同じ
アルファベットで各セルにラベルを付ける。

| キー | 効果 |
|---|---|
| `<ラベル>` | カーソルをセル中心に warp + 左クリック |
| `Shift+<ラベル>` | warp + 右クリック |
| `Cmd+<ラベル>` | warp のみ（クリックしない）— `--drag` の事前準備 |
| `Cmd+Shift+<ラベル>` | クリック + グリッド再エントリ（連続操作）|
| `esc` | 抜ける |

ディスパッチは **合成 `CGEvent` マウスイベント**（AX ではない）—
クリック時にカーソルが見える形でジャンプする。AX が見えない UI
に届くための許容コスト。hint mode (`shift+space` / `--activate`)
はカーソルジャンプ無しのスナップな既定経路として残るので、
`--grid` は hint mode が役立たないときだけ使う。

ピクセル精度は **再帰グリッド** (`perch --rgrid`) が、選んだセルを
さらに細分化して提供（既定 `[grid].max-depth = 3`、4K で 3 段
ドリル ≈ 5px 領域）。

| キー | 効果（`--rgrid`）|
|---|---|
| `<ラベル>` | 選んだセルにドリル（深度予算が尽きたらクリック）|
| `space` / `Enter` | 「ここで十分」— 現在セル中心でクリック |
| `Backspace` | 1 段戻る（親グリッドへ）|
| `Shift` / `Cmd` / `Cmd+Shift` modifier | `--grid` と同じアクションマッピング（クリック時に適用）|
| `esc` | 抜ける |

### 矢印 nudge カーソルモード（ラストマイル精度）

`perch --nudge` は `--grid` / `--rgrid` のカーソル移動補助。
グリッドモードでカーソルが目標近くに着いた後、残りを矢印キーで
歩かせる。

| キー | 効果 |
|---|---|
| `←` `↑` `↓` `→` | 1 px 移動（精密調整）|
| `Shift+矢印` | 10 px（小ステップ）|
| `Alt+矢印` | 100 px（中ステップ）|
| `Cmd+矢印` | 画面ユニオンの端まで一気にジャンプ |
| `space` / `Enter` | 左クリック + 抜ける |
| `Shift+(space\|Enter)` | 右クリック + 抜ける |
| `Cmd+(space\|Enter)` | 中クリック + 抜ける |
| `esc` | クリックせず抜ける |
| その他のキー | 抜けてキーは通過 |

オーバーレイは **無し** — カーソル自体が視覚フィードバック。
モード確認は `perch --status`。

Ctrl はステップ割当てしない（Ctrl+矢印は macOS の Mission
Control / Spaces 用に予約）。

### ドラッグモード（キーボード drag-and-drop）

`perch --drag` は hint mode が届かない UI ドラッグ操作用 —
Finder 列幅 resize、Safari タブ並び替え、テキストドラッグ選択、
NSSplitView ドラッグ、リスト並び替え等。

| フェーズ / キー | 効果 |
|---|---|
| **`.positioning`**（ボタン未保持）| |
| `矢印` (Shift/Alt/Cmd で 1/10/100/画面端 px) | A まで移動 |
| `d` | **掴む** — 現在カーソルで `mouseDown` → `.dragging` |
| `Esc` | 抜ける（ドラッグ未開始）|
| **`.dragging`**（ボタン保持中）| |
| `矢印` | B まで移動 + `mouseDragged` 発火（受け側 app の drop-target ハイライト更新）|
| `d` / `space` / `Enter` | **離す** — `mouseUp` + 抜ける |
| `Esc` | **安全リリース** — `mouseUp` を先に発火してから抜ける（`mouseDown` を残さない）|

事前に `--grid` / `--rgrid` で粗い位置決め、その後 `--drag` で
実際の操作。ドラッグ中の nudge で開始/終了点を微調整できる。

### ウィンドウスイッチャー

`perch --windows` は `--search` の派生で、対象は
**全 running app の全ウィンドウ**。ラベルは `"<App> — <Window Title>"`
（最小化は ` (min)` 付）、描画は `--menu` と同じ Spotlight 風の
中央寄せ縦リスト（ウィンドウ picker は frame に依存しない）。

- `1` — そのウィンドウを raise + 所有アプリを activate
  (`AXUIElementPerformAction(kAXRaiseAction)` +
  `NSRunningApplication.activate`)
- `Cmd-1` — `"App — Window Title"` 全体を pasteboard へコピー
- `Cmd+Shift-1` — 発火 + ウィンドウモード継続 (連続 raise)

`Cmd+Tab` がアプリ単位、Mission Control が視覚スキャン依存
なのに対し、`--windows` は **名前で特定ウィンドウを 1 キー + 数字
1 打** で開ける。

### Chord-suffix アクションモード

modifier ベースのアクションマップに対する vim 風の代替
（issue #57）。bare resolve（修飾キーなし）後、perch が
press を一時的に保留して chord suffix に振り替えられる:

| Chord | アクション |
|---|---|
| `,c` | タイトルをコピー（`Cmd+<label>` と等価）|
| `,o` | Finder で表示（file-URL 要素のみ）|
| `,u` | URL をコピー（リンク / file 要素）|
| `,s` | `AVSpeechSynthesizer` でタイトル読み上げ |
| `,m` | 合成 **Cmd-click**（リンクを新タブで開く等）|
| `,h` | 合成 **Shift-click**（multi-select リスト / テキスト範囲拡張）|

デフォルトは **オフ** — opt-in は `config.toml` に
`[chord].leader = ","` を設定。chord モード有効時:

- `<label>` 単体は `timeout-ms`（既定 600ms）経過後に
  `.press` 発火 — 微妙な遅延以外は変化なし。
- `<label>,c|o|u|s` で chord アクション発火。
- chord wait 中の `Esc` は press 自体をキャンセル。
- `Cmd+<label>` / `Shift+<label>` / `Alt+<label>` /
  `Cmd+Shift+<label>` は従来通り動作 — chord は modifier の
  **代替**であって置き換えではない。

`,m` / `,h` (M4-ε) は AX-bypass carve-out 経路 — カーソルが
要素にジャンプし、`CGEvent` で modifier フラグ付きクリックを
発火。`AXPress` は modifier を honor しないので「Cmd-click で
リンクを新タブで開く」は hint mode からこれ以外に到達できない。

### 絵文字ピッカー

`perch --emoji` は `--search` の派生で、対象は
**厳選した絵文字名テーブル**（≈250 件: 顔 / 手 / ハート /
動物 / 食べ物 / 天気 / 主要シンボル）。名前をタイプ →
マッチを `--menu` と同じ Spotlight 風縦リストで描画 →
数字を押す:

- `1` — その絵文字を focus 中のフィールドの caret に挿入。
  ディスパッチは `CGEvent.keyboardSetUnicodeString`（macOS
  内蔵ピッカーと同じ仕組）なので **pasteboard には一切書き
  込まない** — クリップボード履歴がクリーン。
- `Cmd-1` — グリフを pasteboard にコピー（ユーザーの明示
  要求があった場合のみ）。
- `Cmd+Shift-1` — 挿入 + 絵文字ピッカーに再エントリ
  （連続挿入用）。

テーブルは意図的に厳選している — CLDR の long-tail
（≈3700 件）は名前タイプでの検索頻度が低く、ニッチな絵文字は
システムピッカー（`Ctrl+Cmd+Space`）の方が早い。タイプして
見つからなかった絵文字は issue で報告してエントリを追加。

### リージョナルモード

`perch --regional` で **大きいコンテナ** (記事本文 / ペイン /
画像 / サイドバー) だけにラベルを付ける。"この記事を選択する"
"この画像をコピー" "そのペインにフォーカス" 向け。

ラベルと修飾キー規約は hint mode と同じ、対象だけが大きい:

- `a` (修飾なし) — コンテナを press (押せないコンテナでは効かない)
- `Cmd+a` — **コンテナのタイトルをコピー** (主用途)
- `Shift+a` — コンテキストメニュー
- `Alt+a` — フォーカスのみ
- `Cmd+Shift+a` — コピー + リージョナルモードを継続 (連続コピー)

対象 role: `AXGroup` / `AXArticle` / `AXSection` / `AXSplitGroup`
/ `AXScrollArea` / `AXOutline` / `AXImage`、frame >= `[regional].min-width`
× `min-height` (デフォルト 200×100 pt、両軸別々に設定可、`>= 0` に clamp)。
`kAXPressAction` は **不要** (regional pick は copy / focus が主)。

`--activate` / `--cancel` があるので Karabiner / skhd / Raycast の
スクリプトコマンドからも起動でき、perch 標準のホットキーを残した
まま別トリガーを併用できる。overlay 表示中は `Esc` で常にキャンセル、
ラベルにマッチしない文字をタイプしてもキャンセル。

終了コード: 0 = 成功 · 1 = `--doctor` が赤 · 2 = 不正な
フラグ / 設定 · 3 = デーモン未起動。

### 詳細ログ

perch は常に `/tmp/perch.log` に書き込む。環境変数
`PERCH_DEBUG` をセットして起動すると、全ログ行を stderr にも
ミラーし、walk 単位の詳細トレースを有効化する:

```sh
PERCH_DEBUG=1 perch
```

開発用ランチャ (`./run.sh`) が `PERCH_DEBUG` をセットする。
通常 / brew 起動では何もセットされず静かなまま。

## 開発

```sh
swift build                      # コンパイル (CommandLineTools で可)
swift test                       # テスト — Xcode 必須
./run.sh                         # debug を Perch-dev.app + ログ tail (dev loop)
./run.sh --no-tail               # 上と同じ、tail は省略
./run.sh --release               # release を Perch.app として起動 (公開前検証)
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
