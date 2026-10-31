---
name: pr-ready
description: 変更を PR として出せる状態に仕上げる。コミットの整理、コミット規約の確認、最終の品質ゲート、PR タイトルと説明の作成を行う。「PR を作って」「PR の説明を書いて」と頼まれたときに使う。
---

# PR の準備

## 1. 完了の定義の確認

`docs/harness/DEFINITION_OF_DONE.md` を読み、すべての項目を満たしているか確認する。
skill `quality-gate` と `team-review` をまだ実行していなければ、先に実行する。

## 2. ブランチとコミット

```sh
git branch --show-current
git log --oneline "$(git merge-base HEAD main)"..HEAD
```

- `main` / `master` 上にいる場合は、`<type>/<短い説明>` の作業ブランチを作る。
- 各コミットが `docs/harness/COMMIT_CONVENTION.md` に従っているか確認する。
- 振る舞いの変更とリファクタリングが同じコミットに混ざっていれば、分けることを提案する。
- 履歴の書き換え（rebase・squash・amend）が必要な場合は、**ユーザーに確認してから** 行う。

## 3. 最終確認

```sh
scripts/harness/check.sh --strict
```

## 4. PR タイトルと説明

- タイトル: コミット規約と同じ形式（`type(scope): subject`）。squash merge ではこれがコミットメッセージになる。
- 説明: `.github/pull_request_template.md` の全項目を埋める。
  - 「変更内容」には **なぜ** を書く。
  - 「検証方法」には、実行したコマンドと結果、手動で確認した手順を書く。
  - レビュアーに特に見てほしい箇所を明示する。
  - 抑制コメントを追加した場合は列挙する。

## 5. 作成

- `gh` CLI が使える場合は、ユーザーの確認を得てから `gh pr create` で作成する。
- 使えない場合は、タイトルと説明をユーザーに提示する。
- push は、ユーザーが明示的に依頼した場合のみ行う。`main` への直接 push と force push はしない。
