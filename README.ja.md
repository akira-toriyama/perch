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
| **Cmd+Shift** | クリック + ヒントモード再エントリ（連続操作）| `AXPress` + Controller 再武装 |

Cmd-copy はコントロールの表示名を打ち直さずに取得するのに便利。
Alt-focus は入力したいテキストフィールドに向く。Cmd+Shift は
continuous-follow / chain モード — PR を 5 件続けて開く、通知を
8 件続けて閉じる、等を hotkey 再押下なしでこなせる。Ctrl は
触らないのでシステムショートカット(Ctrl-A 等)はそのまま — overlay 中に
Ctrl を押すとキャンセル。

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
./run.sh                           # Perch-dev.app をビルド + 起動
./install-cli.sh                   # `perch` を $PATH に symlink
```

`./install-cli.sh` は `Perch-dev.app`（`./run.sh` の出力）を
優先し、無ければ `Perch.app`（release）にフォールバック。
書き込み可能な PATH ディレクトリを
`/opt/homebrew/bin` → `/usr/local/bin` → `~/.local/bin` の順で
拾う。

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
theme = "system"                 # パレットプリセット — 下の "テーマ" 参照
accent = "system"                # theme の上に重ねるアクセント上書き、#rrggbb 可
pill-shape = "pill"              # pill / square / circle / underline / tag
font-size = 14                   # 8..32
blur-enabled = true              # ピル背景のフロスト
anim-enabled = true              # 全演出の大元キル スイッチ
peek-key = "space"               # ホールドでオーバーレイ一時非表示 (hint / grid)
show-modifier-badge = "off"      # off / glyph / action — ピル角に⌃⌥⇧⌘表示

# アニメ — kind 語彙は下の "演出" 参照
[overlay.effect]
appear         = "pop"           # 入場: none / pop / cascade / fade-in / drop-in / bloom / random
match          = "off"          # 確定時（勝者 pill のみ）
unmatch        = "off"          # ミス時（赤フラッシュに重畳）
narrow         = "off"          # 絞り込みで消える pill の演出
intensity      = "normal"        # subtle / normal / bold / wild
duration-scale = 1.0             # 0.1..5.0 — 全 duration の倍率

# ネオン ボーダー（既定 off）
[overlay.border]
effect        = "off"            # off / neon / cyber / vapor / kawaii / rainbow / random
glow          = true
width         = 1.5
color-cycle-ms = 3000            # 色相回転周期（整数 ms）

# サウンド — システムサウンド名 ("Tink" / "Pop" / ...) または
# ファイルパス ("~/foo.mp3" 等)。空 ("") でサイレント。
[overlay.sound]
match    = ""
unmatch  = ""
activate = ""
volume   = 0.5                   # 0..1

[exclude]
apps = []                        # 無効化する bundle-id glob（family 共通形）

[behavior]
auto-click-on-unique = true
roles = ["Button", "MenuItem", "Link", "Tab", ...]

# アプリ単位の上書き — `roles` / `min-size` / `auto-click-on-unique`
# + 演出系 (`match-effect` / `appear-effect` / `unmatch-effect` /
# `narrow-effect`) を bundle id ごとに差し替え。
[behavior."com.google.Chrome"]
min-size = 20

[behavior."com.figma.Desktop"]
match-effect = "off"            # Figma 内では派手な演出を抑制
```

### テーマ

`[overlay].theme` で pill 背景 / アクセント / テキスト / フォントを一括指定。
カタログは **facet と共有**（[`sill`](https://github.com/akira-toriyama/sill)
テーマライブラリ）— background / accent / text / font が完全一致なので、
facet の設定から持ち込んだテーマ名は同じ見た目で描画される。pill の半透明は
perch 側で上乗せ（light テーマは摺りガラスで淡色が飛ばないよう不透明度を上げる）:

- **Favorites**: `terminal`（古典的な緑 on 黒）/ `chomp`（アーケード Pac-Man）/ `rainbow`（派手なフルスペクトル）
- **Reference**: `cobalt2` / `shades-of-purple` / `tokyo-hack`
- **Popular dark**: `github-dark` / `dracula` / `catppuccin-mocha` / `gruvbox`
- **Light**: `github-light`
- **Adaptive**: `system`（既定 — macOS アクセント追従。pill 自体は常にダークの摺りガラスチップ）
- **Special**: `random`（`daemon --reload` ごとにランダム）

自分でも定義可能（`[overlay.themes.<name>]`）:

```toml
[overlay.themes.my-theme]
pill-bg = "#1a1a1a"
accent  = "#ff8800"
text    = "#ffffff"
font    = "rounded"

[overlay]
theme = "my-theme"
```

### 演出

`[overlay.effect]` は 4 系統、それぞれ独自の kind セット — 入場
系と退場系は別物、`match` と `unmatch` も 1 つだけ kind が
入れ替わる:

- **`appear`** — 出現時。Kind: `none` / `pop` / `cascade` /
  `fade-in` / `drop-in` / `bloom` / `random`。既定 `pop`
  （150ms scale-in）。退場系 kind（`fade` / `explode` 等）を
  書くと silent fallback で `pop`。
- **`match`** — 確定時（勝者 pill）。Kind: `none` / `fade` /
  **`explode`** / `drop` / `rise` / `slide-left` / `slide-right` /
  `vibrate` / `fireworks` / `confetti` / `random`。
- **`unmatch`** — ミス時（赤フラッシュに重畳）。`match` から
  `explode` を抜いて **`shake`** を足した語彙: `none` /
  **`shake`** / `fade` / `drop` / `rise` / `slide-left` /
  `slide-right` / `vibrate` / `fireworks` / `confetti` / `random`。
- **`narrow`** — 絞り込みで消える pill。`match` と同じ kind。
  ただし `fireworks` / `confetti` は実行時に `fade` に自動降格
  (per-pill パーティクルは負荷が乗りすぎるため)。

`intensity`（subtle/normal/bold/wild）で振幅、`duration-scale`
（0.1..5.0）で速度。screencast 用は 2.5 推奨。

### サウンド

`[overlay.sound]` は macOS システムサウンド名 OR ファイルパス対応:

```toml
[overlay.sound]
match    = "Tink"                # macOS 標準
unmatch  = "Sosumi"
activate = "~/Music/click.mp3"   # 自分の音声 (mp3/m4a/wav/aiff)
volume   = 0.5
```

編集後の反映: `perch daemon --reload` (デーモン稼働中ならファイル保存
で自動再読み込み)。

上記スニペットは編集頻度が高い knob のみ。`[behavior].min-size` /
`[behavior.web].roles` (web context での role 上書き) /
`[search.synonyms]` (fuzzy 拡張) / `[grid]` 密度 / depth /
nest-min-size / `[chord]` leader + timeout /
`[overlay].shortcut-badge` を含む完全リファレンスは
[config.toml](config.toml) 参照。各 knob にヒアドキュメントと
clamp 範囲が併記されている。

## CLI

| コマンド | モード | 用途 |
|---|---|---|
| *(なし)* | server | デーモンを実行 |
| `config --validate` | standalone | config.toml を schema 検証 (exit 0 = valid / 1 = schema 違反 / 2 = parse 不能) |
| `config --doctor` | standalone | ヘルスチェック (AX / 設定 / デーモン / ホットキー) |
| `config --emit-schema` | standalone | config.toml の JSON Schema (Draft-07) を stdout に出力 |
| `overlay --activate` | client | ヒント overlay を表示 (ホットキーの代替) |
| `overlay --scroll` | client | スクロールモード (`j/k/d/u/gg/G`, `esc` で抜ける) |
| `overlay --search` | client | サーチモード (タイプして `1-9` で選択) |
| `overlay --regional` | client | リージョナルモード — 大きいコンテナ (記事 / ペイン / 画像) だけにラベル |
| `overlay --menu` | client | メニュー検索モード — 前面アプリのメニュー全体を fuzzy 検索 (深い項目も含む)、`1-9` で選択 |
| `overlay --windows` | client | クロスアプリのウィンドウスイッチャー — 全アプリの全ウィンドウを fuzzy 検索、`1-9` でウィンドウを raise + 所有アプリを activate |
| `overlay --emoji` | client | 絵文字ピッカー — 厳選した絵文字テーブルを名前で fuzzy 検索、`1-9` で caret に挿入（Unicode 注入 — pasteboard を汚さない）|
| `overlay --grid` | client | 座標グリッド — 画面をラベル付きセルに分割、ラベルで合成 `CGEvent` クリック（Figma canvas / Photoshop / custom-drawn UI など hint mode が見えない領域の AX バイパス） |
| `overlay --rgrid` | client | 再帰グリッド — 各ラベル選択でそのセルをさらに分割（最大 `[grid].max-depth` 段、既定 3 で 4K ≈ ピクセル精度）。`space` で現在セル中心クリック、`Backspace` で 1 段戻る |
| `overlay --nudge` | client | 矢印 nudge カーソルモード — 矢印キーで 1/10/100/画面端 px 移動（modifier で段階切替）、`space` でクリック + 抜ける。`overlay --grid` 後のラストマイル精度 |
| `overlay --drag` | client | キーボードドラッグ — A まで nudge → `d` で grab（mouseDown）→ B まで nudge → `d` で release（mouseUp）。スプリッタ resize / 並び替え等の UI ドラッグ用 |
| `overlay --vision` | client | Vision-OCR hint モード — Apple Vision で表示中のテキストを認識、各 word を hint 化。Screen Recording 権限が必要。AX が無効でかつ grid では粗すぎる場面（Figma レイヤパネル / web canvas テキスト）用 |
| `overlay --cancel` | client | hint / scroll / search / regional / menu / windows / emoji / grid / rgrid / nudge / drag / vision のうち動いてるモードをキャンセル |
| `daemon --reload` | client | デーモンに設定再読み込みを通知 (`overlay --theme ''` セッション override もクリア) |
| `daemon --quit` | client | デーモンを終了 |
| `daemon --show` | client | 現在のホットキー / 最終アクティベーションを表示 |
| `overlay --theme <name>` | client | テーマのライブ override (built-in 名 or `[overlay.themes.<name>]` カスタム名)。`daemon --reload` か `overlay --theme ''` で解除されるまで全 activation に適用。即時反映には `overlay --activate` と併用: `perch overlay --activate --theme dracula` |
| `ax --dump` | standalone | 前面アプリの perch がラベリングする AX 要素を全 dump — バグレポート用 |
| `ax --tree` | standalone | フォーカスウィンドウの生 AX tree (深さ優先、フィルタ前)。web/Electron で見えない領域の調査用 |
| `ax --regions` | standalone | `ax --dump` と同じ形式で `overlay --regional` のコンテナを dump |
| `--help` | standalone | ヘルプ |

すべての client コマンドは Karabiner / skhd / Raycast 等の外部キー
マッパからも呼び出せる。perch 標準のホットキーを残したまま別トリガーを
併用可。各ドメインは verb をちょうど 1 つ取る — verb を複数並べたり
(`daemon --reload --quit` 等)、ドメイン外の flag を使うと exit 2
(silent fallback 無し。未知の flag には "did you mean ...?" のヒント)。
値はスペース区切り (`--theme NAME`)、`--theme=NAME` は不可。終了コード:
0 = 成功 / 1 = 診断チェック失敗 (`config --doctor` / AX 権限が無い
`ax --*`) / 2 = usage・不正な flag・不正な設定 (loud stderr) / 3 =
デーモン未起動。共有 sill `CLIKit` tokenizer を土台にしつつ、perch は
独自の verb 語彙を持つ。

### 移行(フラット flag → yabai 式 domain)

deprecation シムは **無い** — 旧フラット flag は exit 2。対応表:

| 旧 | 新 |
|---|---|
| `perch --activate` | `perch overlay --activate` |
| `perch --cancel` | `perch overlay --cancel` |
| `perch --scroll` | `perch overlay --scroll` |
| `perch --search` | `perch overlay --search` |
| `perch --regional` | `perch overlay --regional` |
| `perch --menu` | `perch overlay --menu` |
| `perch --windows` | `perch overlay --windows` |
| `perch --emoji` | `perch overlay --emoji` |
| `perch --grid` | `perch overlay --grid` |
| `perch --rgrid` | `perch overlay --rgrid` |
| `perch --nudge` | `perch overlay --nudge` |
| `perch --drag` | `perch overlay --drag` |
| `perch --vision` | `perch overlay --vision` |
| `perch --theme=NAME` / `--theme=` (クリア) | `perch overlay --theme NAME` / `overlay --theme ''` |
| `perch --reload` | `perch daemon --reload` |
| `perch --quit` | `perch daemon --quit` |
| `perch --status` | `perch daemon --show` |
| `perch --validate` | `perch config --validate` |
| `perch --doctor` | `perch config --doctor` |
| `perch --emit-schema` | `perch config --emit-schema` |
| `perch --dump-ax` | `perch ax --dump` |
| `perch --dump-ax-tree` | `perch ax --tree` |
| `perch --dump-regions` | `perch ax --regions` |

リネームは 4 つ: `--status` → `daemon --show`、`--dump-ax` → `ax --dump`、
`--dump-ax-tree` → `ax --tree`、`--dump-regions` → `ax --regions`。
`--theme` は値がスペース区切りになり (`--theme NAME`、`=` は廃止)、
override のクリアは `--theme ''` (空文字列。値なしの bare `--theme` は
エラー)。`--help` / `-h`、bare `perch` (agent / server モード)、`PERCH_DEBUG=1`
は不変。

### スクロールモード

`perch overlay --scroll` (外部キーマッパで好きなキーに割当て可) で
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

`perch overlay --search` でサーチモード。要素数が多いアプリ(Xcode,
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

`perch overlay --menu` は `overlay --search` の派生で、**前面アプリのメニュー全項目**
を再帰的に検索対象にする。マッチは Spotlight 風の中央寄せ縦リストで
描画 (メニュー項目は macOS が開くまで画面位置を持たないので、
要素ごとの pill 配置は使えない)。

メニューの 3 階層下にある "隠れコマンド" をマウスホバなしで一発で
呼べる:

- Safari の `Develop > Empty Caches` → `"empt"` とタイプ → `1`
- Xcode の `Editor > Refactor > Rename` → `"rename"` とタイプ
- システム設定のサイドバー項目、3 階層ホバが必要なアプリメニュー、
  すべて 1 キー + `1-9` で到達

修飾キー規約は `overlay --search` と同じ: Cmd-1 でパスをコピー、Shift-1 で
コンテキストメニュー、Alt-1 でフォーカスのみ、Cmd+Shift-1 で発火 +
メニューモード継続 (連続発火)。

各 pill には AX バインドのキーボードショートカット（`⌘Q` /
`⇧⌘N` 等）が右側に薄色で表示される（issue #58）— Superkey 風の
学習ループ: `1-9` で選びつつ、ネイティブのショートカットを発見
できる。`config.toml` で `[overlay].shortcut-badge = false` に
すると非表示。

### グリッドモード（AX バイパス）

`perch overlay --grid` は hint mode が **見えない** UI 用の明示的
フォールバック: Figma canvas、Photoshop、Logic、web `<canvas>`、
custom-drawn ビュー。AX に頼らず、画面を `[grid].cols ×
[grid].rows`（既定 12×8）のセル網に分割し、hint mode と同じ
アルファベットで各セルにラベルを付ける。

| キー | 効果 |
|---|---|
| `<ラベル>` | カーソルをセル中心に warp + 左クリック |
| `Shift+<ラベル>` | warp + 右クリック |
| `Cmd+<ラベル>` | warp のみ（クリックしない）— `overlay --drag` の事前準備 |
| `Cmd+Shift+<ラベル>` | クリック + グリッド再エントリ（連続操作）|
| `esc` | 抜ける |

ディスパッチは **合成 `CGEvent` マウスイベント**（AX ではない）—
クリック時にカーソルが見える形でジャンプする。AX が見えない UI
に届くための許容コスト。hint mode (`shift+space` / `overlay --activate`)
はカーソルジャンプ無しのスナップな既定経路として残るので、
`overlay --grid` は hint mode が役立たないときだけ使う。

ピクセル精度は **再帰グリッド** (`perch overlay --rgrid`) が、選んだセルを
さらに細分化して提供（既定 `[grid].max-depth = 3`、4K で 3 段
ドリル ≈ 5px 領域）。

| キー | 効果（`overlay --rgrid`）|
|---|---|
| `<ラベル>` | 選んだセルにドリル（深度予算が尽きたらクリック）|
| `space` / `Enter` | 「ここで十分」— 現在セル中心でクリック |
| `Backspace` | 1 段戻る（親グリッドへ）|
| `Shift` / `Cmd` / `Cmd+Shift` modifier | `overlay --grid` と同じアクションマッピング（クリック時に適用）|
| `esc` | 抜ける |

### 矢印 nudge カーソルモード（ラストマイル精度）

`perch overlay --nudge` は `overlay --grid` / `overlay --rgrid` のカーソル移動補助。
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
モード確認は `perch daemon --show`。

Ctrl はステップ割当てしない（Ctrl+矢印は macOS の Mission
Control / Spaces 用に予約）。

### ドラッグモード（キーボード drag-and-drop）

`perch overlay --drag` は hint mode が届かない UI ドラッグ操作用 —
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

事前に `overlay --grid` / `overlay --rgrid` で粗い位置決め、その後 `overlay --drag` で
実際の操作。ドラッグ中の nudge で開始/終了点を微調整できる。

### Vision-OCR hint モード

`perch overlay --vision` は **最終 AX-bypass レイヤ**、`overlay --grid` の補完。
grid が「ラベル付きセル」で座標を選ぶのに対し、vision は
「**見えているテキスト**」で選ぶ。Apple Vision が main display の
全ての文字を認識、perch が各 word に hint を振り、ラベル選択で
認識重心にカーソル warp + クリック。

用途:
- Figma レイヤパネルラベル（AX が不透明）
- Web `<canvas>` テキスト（Slides / Maps / ブラウザ内エディタ）
- PDF / スクリーンショットビューアの画像テキスト
- ゲーム UI / 非 AppKit chrome

**Screen Recording 権限が必要**: System Settings →
Privacy & Security → Screen Recording で perch を有効化。
未付与だと `CGDisplayCreateImage` が nil 返却 → overlay
silent dismiss。初回 invocation でプロンプト表示。

**レイテンシ**: Apple Silicon で 1 invocation あたり 100-400ms
（1 回の screen capture + 1 回の Vision request、キーストローク
毎の再 capture は無し）。hint mode (<30ms) と比べると遅いが、
明示的に呼ぶ fallback としては許容範囲。

v1 では dispatch が左クリック / 右クリック / Cmd-click /
Shift-click / ダブル・トリプルクリック（hint mode と同じ chord
動詞）に対応。`.copyTitle` / `.revealInFinder` /
`.speakTitle` は vision に AX target が無く URL / file /
スピーチ元データが取れないため defer。

### ウィンドウスイッチャー

`perch overlay --windows` は `overlay --search` の派生で、対象は
**全 running app の全ウィンドウ**。ラベルは `"<App> — <Window Title>"`
（最小化は ` (min)` 付）、描画は `overlay --menu` と同じ Spotlight 風の
中央寄せ縦リスト（ウィンドウ picker は frame に依存しない）。

- `1` — そのウィンドウを raise + 所有アプリを activate
  (`AXUIElementPerformAction(kAXRaiseAction)` +
  `NSRunningApplication.activate`)
- `Cmd-1` — `"App — Window Title"` 全体を pasteboard へコピー
- `Cmd+Shift-1` — 発火 + ウィンドウモード継続 (連続 raise)

`Cmd+Tab` がアプリ単位、Mission Control が視覚スキャン依存
なのに対し、`overlay --windows` は **名前で特定ウィンドウを 1 キー + 数字
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
| `,d` | 合成 **ダブルクリック**（テキストで word 選択、Finder で "開く"）|
| `,t` | 合成 **トリプルクリック**（行 / 段落選択）|
| `,g` | **ネストグリッド** — クリックする代わりに、選んだ要素をグリッドで再分割（M5+）。小さい要素は AXPress にフォールバック |

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

`perch overlay --emoji` は `overlay --search` の派生で、対象は
**厳選した絵文字名テーブル**（≈400 件: 顔 / 手 / ハート /
動物 / 食べ物 / 天気 / 主要シンボル）。名前をタイプ →
マッチを `overlay --menu` と同じ Spotlight 風縦リストで描画 →
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

`perch overlay --regional` で **大きいコンテナ** (記事本文 / ペイン /
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

overlay 表示中は `Esc` で常にキャンセル、ラベルにマッチしない文字を
タイプしてもキャンセル。

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
([CONTRIBUTING.md](https://github.com/akira-toriyama/.github/blob/main/CONTRIBUTING.md))。
ローカルフックの有効化:

```sh
git config core.hooksPath scripts/hooks
```

## ライセンス

MIT — [LICENSE](LICENSE) を参照。
