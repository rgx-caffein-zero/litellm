# コミットメッセージ規約

[Conventional Commits](https://www.conventionalcommits.org/ja/v1.0.0/) に従います。
`.githooks/commit-msg` が形式を検査し、CI は PR タイトルを検査します。

## 形式

```
<type>(<scope>)!: <subject>

<body>

<footer>
```

- `<type>` と `<subject>` は必須。`(<scope>)`、`!`、`<body>`、`<footer>` は任意。
- 1 行目（ヘッダー）は 72 文字以内（`.harness/project.env` の `HARNESS_COMMIT_MAX_HEADER` で変更可能）。
- `<subject>` は命令形・現在形で、変更の内容を簡潔に書く。末尾にピリオドを付けない。
- `<body>` には **なぜ** 変更したかを書く。何を変えたかは差分を見れば分かる。
- 言語（日本語 / 英語）は `.harness/PROJECT.md` の指定に従う。

## type 一覧

| type | 用途 |
| --- | --- |
| `feat` | 新機能 |
| `fix` | バグ修正 |
| `docs` | ドキュメントのみの変更 |
| `style` | 振る舞いに影響しない見た目の変更（空白・フォーマット） |
| `refactor` | 振る舞いを変えないコードの改善 |
| `perf` | 性能改善 |
| `test` | テストの追加・修正 |
| `build` | ビルドシステム・依存関係の変更 |
| `ci` | CI 設定の変更 |
| `chore` | 上記に当てはまらない雑務 |
| `revert` | 以前のコミットの取り消し |

## 破壊的変更

ヘッダーの type の後に `!` を付け、フッターに `BREAKING CHANGE:` で内容と移行方法を書きます。

```
feat(api)!: remove deprecated v1 order endpoints

The v1 endpoints have been deprecated since 2.3.0.

BREAKING CHANGE: /v1/orders is removed. Use /v2/orders instead.
See docs/migration/v3.md for details.
```

## 例

```
fix(auth): prevent session fixation on login

The session ID was reused after authentication, allowing an attacker
who knew a pre-login session ID to hijack the session.

Refs: #482
```

```
refactor(order): extract price calculation into PriceCalculator
```

## 1 コミット 1 目的

- 振る舞いの変更とリファクタリングを同じコミットに混ぜない。
- 各コミットは単独でビルド・テストが通るようにする。
- 「WIP」「fix typo」のような作業途中のコミットは、PR 前に整理する（squash merge の場合は PR タイトルが正しければよい）。
