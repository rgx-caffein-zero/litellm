# コントリビューションガイド

このプロジェクトへの貢献を歓迎します。人間の開発者も AI エージェントも、同じ手順と基準で作業します。

## はじめに

```sh
git clone <repository-url>
cd <repository>
# 依存関係のインストール（.harness/PROJECT.md の「コマンド」を参照）
scripts/harness/init.sh      # git hooks を有効化し、検出結果を表示
scripts/harness/check.sh     # すべての品質ゲートが通ることを確認
```

## 読んでおくもの

- [AGENTS.md](AGENTS.md) — 作業の基本ルール（短いので必ず読んでください）
- [.harness/PROJECT.md](.harness/PROJECT.md) — このプロジェクト固有の情報
- [docs/harness/CODING_STANDARDS.md](docs/harness/CODING_STANDARDS.md) — コーディング規約
- [docs/harness/WORKFLOW.md](docs/harness/WORKFLOW.md) — 作業の流れ
- [docs/harness/COMMIT_CONVENTION.md](docs/harness/COMMIT_CONVENTION.md) — コミットメッセージ規約

## 変更の流れ

1. 大きな変更は、先に Issue で相談してください。
2. `main` から作業ブランチ（`<type>/<短い説明>`）を作ります。
3. 変更し、テストを追加します。
4. `scripts/harness/check.sh` がすべて成功することを確認します。
5. PR を作成し、テンプレートの項目を埋めます。
6. レビューの指摘に対応し、承認を得てからマージします。

## レビューについて

レビューでは [docs/harness/REVIEW_CHECKLIST.md](docs/harness/REVIEW_CHECKLIST.md) を使います。
指摘には `[must]` / `[should]` / `[nit]` / `[question]` のラベルが付きます。`[must]` はマージ前に対応が必要です。

## 行動規範

すべての参加者に敬意を持って接してください。コードを批判しても、人を批判しないでください。
