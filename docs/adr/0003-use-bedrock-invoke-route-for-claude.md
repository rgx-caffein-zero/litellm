# 0003. Bedrock の Claude には Invoke 経路を使う

- ステータス: 承認済み
- 日付: 2026-10-31
- 決定者: LiteLLM 導入担当
- 関連: [requirements.md](../requirements.md)（C5）、`litellm/config.yaml`

## 背景

Claude Desktop / Cowork は Anthropic Messages API（`/v1/messages`）で LiteLLM に接続する。LiteLLM は、Bedrock の Claude を 2 つの経路で呼び出せる。

- Converse 経路（`bedrock/<モデル ID>`）: Bedrock 共通の Converse API に変換する。
- Invoke 経路（`bedrock/invoke/<モデル ID>`）: Anthropic Messages 形式のまま InvokeModel API に渡す。

Cowork は毎ターン `cache_control` を付けてプロンプトキャッシュを使う。キャッシュが効かないと、会話全体が毎回フル料金で課金され、案件の予算の消費が大きく増える。

## 検討した選択肢

### 選択肢 A: Converse 経路

- 概要: LiteLLM の Bedrock の既定の経路。
- 利点: Claude 以外の Bedrock モデルと同じ設定方法で扱える。
- 欠点: Converse API はシステムプロンプトを先頭にまとめる必要がある。会話の途中にシステムメッセージが入ると、キャッシュしたプレフィックスが無効になる。LiteLLM の公式ブログ（[Bedrock invoke prompt caching incident](https://docs.litellm.ai/blog/bedrock-invoke-prompt-caching-incident)）は、Claude Code を Bedrock で使う場合に Invoke 経路を推奨している。

### 選択肢 B: Invoke 経路

- 概要: `bedrock/invoke/us.anthropic.<モデル>` を使う。
- 利点: Anthropic の形式をそのまま渡すため、`cache_control`・ツール・ストリーミングの挙動が Claude Desktop の想定に近い。
- 欠点: Claude 以外のモデルとは設定方法が異なる。

## 決定

Claude Desktop 用の Claude モデル（`litellm/config.yaml`）は、選択肢 B の Invoke 経路で定義する。
`model_name` には Claude API のモデル ID（例: `claude-sonnet-5-5`）を使う。Claude Desktop がモデル名から世代と機能を判定するためである。

## 影響

- 良い影響: プロンプトキャッシュが効き、予算の消費を抑えられる。
- 悪い影響・受け入れるトレードオフ: 管理 UI で Claude モデルを追加する場合も、`bedrock/invoke/` を付ける必要がある。
- 必要になる作業: PoC（P3）で、`cache_read_input_tokens` が 0 より大きくなることを確認する。LiteLLM の更新時にも確認する（[operations.md](../operations.md)）。

## 見直しの条件

- LiteLLM の Converse 経路で、Claude Desktop のプロンプトキャッシュが Invoke 経路と同等に効くようになったとき。
- Bedrock の Anthropic Messages API 互換エンドポイント（Bedrock Mantle）に移行するとき。
