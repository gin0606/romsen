# romsen

[English](README.md)

Slack や Google Chrome の表示を macOS の Accessibility API 経由で読み、エージェント向けのテキストを出力します。名前は「ROM専」(読むだけで書き込まない) から。

## 導入

Homebrew 版は Apple silicon の macOS 13 以降に対応しています。

```sh
brew install gin0606/tap/romsen
```

システム設定 > プライバシーとセキュリティ > アクセシビリティ で、romsen を起動するアプリ (ターミナルやエージェントのホスト) を許可してください。

## 使い方

### Slack

Slack デスクトップアプリで対象の会話を開いてから実行します。

```sh
romsen slack            # 現在の表示内容を読む
romsen slack --last 10   # 最新の10件を読む
romsen slack --thread    # 開いているスレッド全体を読む
```

オプションなしでは画面を操作しません。オプションによってスクロールやスレッド表示が起こります。会話やワークスペースの切り替え、メッセージの送信・編集は行いません。メッセージリンクやテキスト探索にも対応しています。詳細は `romsen slack --help` を参照してください。

### Chrome

```sh
romsen chrome           # 本文を中心に読む
romsen chrome --all     # ナビゲーションやサイドバーも含める
```

Chrome のフォーカスされたウィンドウで選択中のタブを読み、タイトル、URL、見出し・リンク・リスト・表などの構造を保ったテキストを出力します。スクロール、タブ切り替え、Chrome を手前に出す操作は行いません。全オプションは `romsen chrome --help` を参照してください。

## エージェント用 plugin

`slack` skill を提供します。[Homebrew で本体を導入](#導入)し、エージェントの PATH 上で `romsen` を使えるようにしてください。

### Codex

```sh
codex plugin marketplace add gin0606/romsen
codex plugin add romsen@romsen
```

新しいセッションで `$romsen:slack いま Slack に表示されている内容を読んで` と呼び出します。

### Claude Code

```sh
claude plugin marketplace add gin0606/romsen
claude plugin install romsen@romsen --scope user
```

新しいセッションで `/romsen:slack いま Slack に表示されている内容を読んで` と呼び出します。

## 読み取りの制約・警告

Accessibility が公開する範囲を読むため、画面外のテキストを含む場合や、canvas に描画された文字などを取得できない場合があります。警告がなくても、内容を完全に取得できるとは限りません。

Slack の表示の一部を解釈できない場合は、標準エラーへ警告し、取得できたテキストは標準出力に残します。警告だけなら終了コードは 0 です。権限不足や読み取りエラーでは失敗します。

複数の Slack ウィンドウが原因で読み取りが失敗した場合は、会話やスレッドを表示するウィンドウを読み取り対象の1つだけにして再実行してください。

## 開発

[開発手順](DEVELOPMENT.md)

## ライセンス

[MIT](LICENSE)
