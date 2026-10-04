# romsen

[English](README.md)

Slack や Google Chrome の表示内容を、macOS の Accessibility API 経由で読み、エージェント向けのテキストとして出力します。
名前は「ROM専」(読むだけで書き込まない) から。

## 導入

```sh
brew install gin0606/tap/romsen
romsen slack --help
```

Homebrew の formula は、Apple silicon の macOS 13 以降向けのビルド済みバイナリを入れます。

ソースからビルドする場合は `swift build -c release` を実行し、`.build/release/romsen` を使います。
`romsen --version` は、リリースのワークフローでビルドしたもの以外では `0.0.0-dev` を表示します。

## アクセシビリティの権限

romsen は macOS の Accessibility API で Slack や Chrome を読みます。権限は romsen 自身ではなく、romsen を起動するアプリ
(ターミナルやエージェントのホスト) に付きます。システム設定 > プライバシーとセキュリティ > アクセシビリティ で
そのアプリを許可してください。

## エージェント用 plugin (Codex / Claude Code)

両ホストで共通の `slack` skill を提供します。開いている会話、メッセージのリンク、最新の発言、
テキスト探索、スレッド全体の読み取りに使えます。先に [Homebrew で本体を導入](#導入)してください。
plugin は romsen の実行ファイルを同梱しません。エージェントのシェルで `command -v romsen` が通ることを確認し、
起動元のアプリに[アクセシビリティの権限](#アクセシビリティの権限)を付け、人が Slack デスクトップアプリで対象の会話を開きます。
読み取りではスクロールやスレッド表示が起こりますが、送信や会話の切り替えは行いません。
標準エラーに警告があれば、skill は読み取りが不完全な可能性を伝えます。

以下の Git marketplace から導入します。ローカルの checkout は不要です。
skill は PATH 上の `romsen` を呼ぶので、どの作業ディレクトリからでも利用できます。
plugin の更新はこのリポジトリの既定ブランチ (`main`) に追従し、Homebrew の CLI のリリースとは独立しています。

### Codex

```sh
codex plugin marketplace add gin0606/romsen
codex plugin add romsen@romsen
```

新しい Codex セッションを開始します。導入時に有効になります。無効化していた場合は、
`~/.codex/config.toml` の `[plugins."romsen@romsen"]` で `enabled = true` にします。
`$romsen:slack いま Slack に表示されている内容を読んで` と呼び出します。

Codex CLI 0.160.0 では、セッション開始時に Git marketplace と導入済み plugin が裏で更新され、
新しい skill は次のセッションで利用できます。この自動更新は同バージョンでの確認結果であり、
すべての Codex ホスト・バージョンで保証された挙動としては文書化されていません。

### Claude Code

以前ローカルの checkout から `romsen` を登録していた場合は、先に
`claude plugin marketplace remove romsen --scope user` で登録を削除してから、Git から導入します。

```sh
claude plugin marketplace add gin0606/romsen
claude plugin install romsen@romsen --scope user
claude plugin list
```

`romsen@romsen` が有効であることを確認し、必要なら `claude plugin enable romsen@romsen` で有効化します。
新しいセッションで `/romsen:slack いま Slack に表示されている内容を読んで` と呼び出します。
`claude plugin details romsen` で共通の `slack` skill を確認できます。

`/plugin` の **Marketplaces** で **romsen** を選び、**Enable auto-update** を有効にします。
第三者の marketplace は既定で自動更新が無効です。対話セッションで最初のメッセージを送ってから、
最大 10 分の遅延後に裏で更新されます。更新後の skill は次のセッションで使うか、
更新の完了後に `/reload-plugins` で読み込みます。
[Claude Code の読み込み仕様](https://code.claude.com/docs/en/plugins/loading#when-auto-update-runs)を参照してください。

### ローカルの変更を検証する

このリポジトリを clone し、ルートディレクトリで次を実行します。
ローカル marketplace は skill の開発用で、GitHub から変更を取得しません。

```sh
codex plugin marketplace add .
codex plugin add romsen@romsen
claude plugin marketplace add "$(pwd)"
claude plugin install romsen@romsen --scope user
```

`romsen` を Git marketplace として登録済みの場合は、分離したホスト設定を使ってください。
`plugins/romsen/` の両ホスト用 manifest は、同じ `skills/slack/SKILL.md` を読み込みます。
Git 管理下の plugin ファイルを変更したら、commit 前に両ホストの version を再生成します。
新規の plugin ファイルは先に stage してください。Python 3 と Git が必要です。

```sh
scripts/plugin-version
scripts/plugin-version --check
```

両 manifest は同じ `0.1.0+plugin.<hash>` という version を使います。
hash は `plugins/romsen/` 内の Git 管理下のファイルのパスと内容から計算し、
両 manifest の生成する `version` フィールドを除外します。CI はどちらかの値が古ければ失敗します。
Claude Code の plugin と marketplace は次のコマンドで検証できます。

```sh
claude plugin validate ./plugins/romsen --strict
claude plugin validate . --strict
```

Codex はローカル marketplace からの導入を再実行し、新しいセッションで skill を確認します。
plugin CLI に単独の validator はありません。両ホストとも、このリポジトリの外から読み取りを試してください。
検証記録にはホスト、バージョン、導入経路、成功・失敗だけを残し、実際の Slack の内容やリンクを書かないでください。
形式の参照先: [Codex](https://developers.openai.com/plugins/build/plugins)、
[Claude Code](https://code.claude.com/docs/en/plugin-marketplaces)。

## Chrome を読む

```sh
romsen chrome
romsen chrome --all
romsen chrome --raw
```

Chrome のフォーカスされたウィンドウで選択中のタブを読み、タイトル、URL、構造を保ったテキストを出力します。
既定では、ページが指定するメイン領域と開いているダイアログを読み、周囲のナビゲーションやサイドバーを除外します。
メイン領域内の補足情報は残します。メイン領域の指定がない場合は、識別できたナビゲーション、サイドバー、
ヘッダー、フッター、検索領域を除外し、それ以外を残します。意味が付いていないサイドバーは残る場合があります。
`--all` では、それらの領域も含めてページ全体を読みます。

見出し、段落、リンク、入れ子のリストを区別し、表は列の対応を保ちます。結合セルや欠けたセルは位置と結合範囲を明示します。
操作部品はラベルと値に加え、チェック済み、選択中、無効などの取得できた状態を表示します。
本文、ナビゲーション、フォーム、ダイアログなど、ページが意味を付けている領域には境界を付けます。

同じ列に重ならず縦に並ぶブロックは、画面上の順序に補正します。文中の装飾用要素は、隣接する文字と同じ行にある場合に
文の一部として扱います。別カラム、重なった要素、クリップされた要素、有効な座標のない要素は Accessibility の順序を保ちます。
この補正で見出しをまたいで移動したり、表の行や番号付きリストの項目を並べ替えたりはしません。

ブラウザのツールバーは除外し、スクロール、タブ切り替え、Chrome を手前に出す操作は行いません。
Accessibility が公開する範囲を読むため、画面外のテキストを含む場合や、canvas に描画された文字などを取得できない場合があります。
意味が付いていない領域や画面配置を常に再現できるわけではありません。スクリーンショットや HTML 全体の取得ではなく、
未展開・未読み込みの内容は取得しません。

Slack と同様に `--save-snapshot /tmp/page.json` と `--from-snapshot /tmp/page.json` で対象ウィンドウを保存・再生できます。
保存ファイルと取得した出力は非公開の場所に置き、使用後に削除してください。`--raw` ではブラウザの操作部も含めて出力します。
古いスナップショットも読み戻せますが、保存時に取得していないリンク先や操作状態は復元できません。

## 同じ画面からの出力を比較する

最初に読み取った Accessibility ツリーを JSON で保存し、変更前後のビルドで読み戻せます。

```sh
.build/debug/romsen slack --save-snapshot /tmp/screen.json
.build/debug/romsen slack --from-snapshot /tmp/screen.json --last 10
```

読み戻すときは Slack に触れず、アクセシビリティの権限も不要です。`--raw` を含む既存のオプションを使えますが、
スクロールやスレッドを開く操作はできません。保存したメッセージの範囲だけを返し、検索やリンクの対象がなければエラーになります。
スレッドへのリンクは、そのスレッドが開かれており、スレッドの先頭も保存されている必要があります。
保存ファイルには Slack の内容が入るため、非公開の場所に置き、コミットせず、比較後は保存ファイルと出力を削除してください。

## 読み取りの警告

会話またはスレッドのビューを持つ Slack ウィンドウが2つ以上ある場合、メッセージリンク、`--last`、`--find`、
`--thread`、1以上の `--history` はスクロールやクリックを行う前に終了コード1で失敗します。
読みたい会話またはスレッドを表示するウィンドウを1つだけにしてください。これらのビューを持たないウィンドウは
数えません。オプションなしでは全ウィンドウを見出し付きで出力し、`--raw` と `--save-snapshot` も全ウィンドウを
含みます。通常の読み取りと `--from-snapshot` で同じ判定を使い、同じ会話を複数ウィンドウに表示している場合も失敗します。

Accessibility の取得失敗、探索上限への到達、Chromium の読み取り準備のタイムアウトはエラーとして扱い、
不完全なスナップショットを正常な読み取り結果として返しません。`--raw` と `--save-snapshot` にも適用します。

ビューの構造を認識できない場合や、メッセージ時刻の形式に合う行 ID が残っているのに行を解釈できない場合は、
出力が不完全な可能性を標準エラーへ警告します。スクロール中に見つかった未知の行も含め、取得できたテキストは
標準出力に残します。警告だけなら終了コードは 0 です。権限不足、読み取り失敗、リンクや検索の既存エラーは失敗のままです。

警告と代替テキストは、指定されたペインとメッセージ範囲に限ります。リンクは、スレッド内へのリンクか `--thread` 付きなら
スレッドだけを、それ以外は会話だけを読み、開いているスレッドの先頭のように同じメッセージが別のペインにあっても使いません。
`--last` や会話へのリンクなどでメッセージは見つかったが、それを含むビューを特定できない場合は、未特定のテキストを
除外したことを警告し、別のペインでは代用しません。リンク先のメッセージやスレッドが見つからない場合は失敗します。
既知の会話や検索結果が空であること、発言者や時刻の省略、日付区切りだけでは警告しません。

既知の構造との不一致を検知するもので、Slack の更新を原因と断定しません。行の手掛かりがすべて失われる変更や、
認識済みメッセージ内部の部分的な欠落まで検出を保証するものではありません。通常の読み取りと `--from-snapshot` は
同じ判定を使います。`--raw` は加工前のツリーを出力し、構造の警告を付けません。

## いまの方針

固定の規定ではなく、作業上の前提です。

- **Slack と Chrome。** Slack は会話を、Chrome は選択中のページをテキストとして読む。
- **人がいま見ているものをエージェントに見せる。** その表示の続きを読むためにスクロールはするが、会話やワークスペースは切り替えない。
- **閲覧専用。** スクロールとスレッドを開く操作だけを行う。文字入力や、送信・変更につながるクリックはしない。

## リリース

`scripts/release 1.2.3` は、`origin/main` より遅れていないきれいな `main` で実行します。
`v1.2.3` が origin にまだないことを確かめ、`swift test` を実行してから、注釈付きのタグ `v1.2.3` を打ち、`main` とタグを一緒に push します。
タグの push でリリースのワークフローが動き、テストと arm64 向けのビルド、GitHub Release の公開、`gin0606/homebrew-tap` の formula の更新を行います。
失敗した実行は、同じタグのまま再実行できます。

## ライセンス

[MIT](LICENSE)
