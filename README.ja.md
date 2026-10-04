# romsen

[English](README.md)

Slack デスクトップアプリの表示内容を、macOS の Accessibility API 経由で読み、エージェント向けのテキストとして出力します。
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

romsen は macOS の Accessibility API で Slack を読みます。権限は romsen 自身ではなく、romsen を起動するアプリ
(ターミナルやエージェントのホスト) に付きます。システム設定 > プライバシーとセキュリティ > アクセシビリティ で
そのアプリを許可してください。

## エージェント用 plugin (Codex / Claude Code)

両ホストで共通の `slack` skill を提供します。開いている会話、メッセージのリンク、最新の発言、
テキスト探索、スレッド全体の読み取りに使えます。先に [Homebrew で本体を導入](#導入)してください。
plugin は romsen の実行ファイルを同梱しません。エージェントのシェルで `command -v romsen` が通ることを確認し、
起動元のアプリに[アクセシビリティの権限](#アクセシビリティの権限)を付け、人が Slack デスクトップアプリで対象の会話を開きます。
読み取りではスクロールやスレッド表示が起こりますが、送信や会話の切り替えは行いません。
標準エラーに警告があれば、skill は読み取りが不完全な可能性を伝えます。

このリポジトリを取得するか、`plugins/romsen/` を含む既存の checkout を使います。

```sh
git clone https://github.com/gin0606/romsen.git
cd romsen
```

以下の導入コマンドはこのディレクトリで実行します。ローカル marketplace の更新に使うため checkout は残してください。
導入後の skill は PATH 上の `romsen` を呼ぶので、エージェントは別の作業ディレクトリから利用できます。

### Codex

```sh
codex plugin marketplace add .
codex plugin add romsen@romsen
```

新しい Codex セッションを開始します。導入時に有効になります。無効化していた場合は、
`~/.codex/config.toml` の `[plugins."romsen@romsen"]` で `enabled = true` にします。
`$romsen:slack いま Slack に表示されている内容を読んで` と呼び出します。

### Claude Code

```sh
claude plugin marketplace add "$(pwd)"
claude plugin install romsen@romsen --scope user
claude plugin list
```

`romsen@romsen` が有効であることを確認し、必要なら `claude plugin enable romsen@romsen` で有効化します。
新しいセッションで `/romsen:slack いま Slack に表示されている内容を読んで` と呼び出します。
`claude plugin details romsen` で共通の `slack` skill を確認できます。

### ローカルの変更を検証する

`plugins/romsen/` の両ホスト用 manifest は、同じ `skills/slack/SKILL.md` を読み込みます。
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

- **Slack のみ。** チャットアプリをまたいで出力形式を揃えるのは難しそうだったため。
- **人がいま見ているものをエージェントに見せる。** その表示の続きを読むためにスクロールはするが、会話やワークスペースは切り替えない。
- **閲覧専用。** スクロールとスレッドを開く操作だけを行う。文字入力や、送信・変更につながるクリックはしない。

## リリース

`scripts/release 1.2.3` は、`origin/main` より遅れていないきれいな `main` で実行します。
`v1.2.3` が origin にまだないことを確かめ、`swift test` を実行してから、注釈付きのタグ `v1.2.3` を打ち、`main` とタグを一緒に push します。
タグの push でリリースのワークフローが動き、テストと arm64 向けのビルド、GitHub Release の公開、`gin0606/homebrew-tap` の formula の更新を行います。
失敗した実行は、同じタグのまま再実行できます。

## ライセンス

[MIT](LICENSE)
