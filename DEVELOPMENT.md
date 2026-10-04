# 開発手順

コマンドはリポジトリのルートで実行します。

## ビルドとテスト

macOS と Swift 6.0 以降が必要です。

```sh
swift build
swift test --explicit-target-dependency-import-check error
swift build -c release
```

開発時は `.build/debug/romsen`、リリースビルドは `.build/release/romsen` を使います。

## plugin の変更

`plugins/romsen/` を変更したら、commit 前に version を再生成します。新規ファイルは先に stage してください。Python 3 と Git が必要です。

```sh
scripts/plugin-version
scripts/plugin-version --check
```

検証するホストにローカル marketplace を登録します。`romsen` を Git marketplace として登録済みの場合は、分離したホスト設定を使ってください。

### Codex

```sh
codex plugin marketplace add .
codex plugin add romsen@romsen
```

### Claude Code

```sh
claude plugin validate ./plugins/romsen --strict
claude plugin validate . --strict
claude plugin marketplace add "$(pwd)"
claude plugin install romsen@romsen --scope user
```

`romsen` をホストの PATH に通し、新しいセッションでリポジトリ外から skill を試します。検証記録にはホスト、バージョン、導入経路、成功・失敗だけを残してください。

## snapshot で出力を比較する

Accessibility ツリーを保存し、比較するビルドで読み戻します。

```sh
.build/debug/romsen slack --save-snapshot /tmp/screen.json
.build/debug/romsen slack --from-snapshot /tmp/screen.json --last 10
```

Chrome でも同じオプションを使えます。読み戻しは保存内容に限られ、スクロールやスレッドを開く操作はできません。アクセシビリティの権限は不要です。詳細は各コマンドの `--help`、加工前のツリーは `--raw` で確認できます。

snapshot と取得した出力はリポジトリ外の非公開の場所に置き、使用後に削除してください。実際の Slack の内容、名前、リンク、ID を、commit するもの、公開物、検証記録に含めないでください。テストには合成したツリーを使います。

## リリース

未コミットの変更がなく、`origin/main` より遅れていない `main` で実行します。

```sh
scripts/release 1.2.3
```

テストを実行し、`main` とリリースタグを push します。リリースのワークフローが arm64 向けのバイナリを GitHub Releases に公開し、Homebrew の formula を更新します。ワークフローが失敗した場合は、同じタグのまま再実行してください。
