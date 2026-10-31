# Architecture Decision Records

アーキテクチャや技術選定に関する重要な決定を記録します。
「なぜこうなっているのか」を、決定に関わらなかったメンバーが後から理解できるようにするためのものです。

## 書くべきとき

- 技術・ライブラリ・フレームワークを選定したとき
- モジュール構成・データモデル・API 設計の方針を決めたとき
- 既存の方針を変更・廃止したとき
- 後から「なぜ？」と聞かれそうな判断をしたとき

## 運用

- `0000-template.md` をコピーし、連番で `NNNN-kebab-case-title.md` として作成する（Claude Code では skill `adr-new`）。
- 承認済みの ADR は書き換えない。方針を変える場合は新しい ADR を作り、古い ADR のステータスを「NNNN により置き換え」にする。
- ADR は、関連する実装と同じ PR、またはそれより前の PR で追加する。

## 一覧

| 番号 | タイトル | ステータス |
| --- | --- | --- |
| [0001](0001-store-azure-credentials-in-db.md) | Azure OpenAI の認証情報を管理 UI で登録し DB に暗号化して保存する | 承認済み |
| [0002](0002-self-signed-root-ca-with-constraints.md) | 用途と範囲を制限した自前のルート CA で HTTPS 化する | 承認済み |
| [0003](0003-use-bedrock-invoke-route-for-claude.md) | Bedrock の Claude には Invoke 経路を使う | 承認済み |
| [0004](0004-block-unused-litellm-features-in-nginx.md) | 無効化の設定がない LiteLLM の機能は nginx で遮断する | 提案中 |
