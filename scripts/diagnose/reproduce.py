"""推論のリクエストを、形と経路を変えて送り、どこで失敗するかを切り分ける（少額の利用料が発生する）。

scripts/diagnose/diagnose-server.sh --inference から、動いている LiteLLM のコンテナの中で実行する。
マスターキーはコンテナの環境変数から読み、コンテナの外に出さない。

経路:
  direct  LiteLLM に直接（http://localhost:4000）
  nginx   nginx を通す（https://nginx。compose のネットワーク内で接続する）。証明書は検証しない
          （ここで確かめたいのは nginx の転送とストリーミング。証明書は社内 PC 側で確かめる）
形:
  minimal   ストリーミングしない最小のリクエスト
  stream    ストリーミング（Claude Desktop / Cowork の推論はストリーミングで送られる）
  tools     ストリーミング + tools・cache_control・anthropic-beta ヘッダー（Claude Code に近い形）
  thinking  ストリーミング + 拡張思考（thinking）

結果は「RESULT<TAB>経路<TAB>形<TAB>モデル<TAB>HTTP ステータス<TAB>OK|NG<TAB>要約」の形で 1 行ずつ出力する。
"""

import json
import os
from concurrent.futures import ThreadPoolExecutor
import re
import ssl
import urllib.error
import urllib.request

import yaml

ROUTES = {"direct": "http://localhost:4000", "nginx": "https://nginx"}
# Auto モードの安全性分類器が既定で呼ぶモデル。nginx を通す確認はこのモデルだけで行う
REQUIRED_MODEL = "claude-sonnet-5"
BETA_HEADERS = "claude-code-20250219,interleaved-thinking-2025-05-14,fine-grained-tool-streaming-2025-05-14"
PROMPT = [{"role": "user", "content": "Reply with OK."}]


def body_of(pattern, model):
    if pattern == "minimal":
        return {"model": model, "max_tokens": 16, "messages": PROMPT}, {}
    if pattern == "stream":
        return {"model": model, "max_tokens": 16, "messages": PROMPT, "stream": True}, {}
    if pattern == "tools":
        return {
            "model": model,
            "max_tokens": 64,
            "stream": True,
            "system": [{"type": "text", "text": "You are a helpful assistant.", "cache_control": {"type": "ephemeral"}}],
            "tools": [
                {
                    "name": "get_time",
                    "description": "Get the current time.",
                    "input_schema": {"type": "object", "properties": {}},
                }
            ],
            "metadata": {"user_id": "diagnose"},
            "messages": PROMPT,
        }, {"anthropic-beta": BETA_HEADERS}
    return {
        "model": model,
        "max_tokens": 1100,
        "stream": True,
        "thinking": {"type": "enabled", "budget_tokens": 1024},
        "messages": PROMPT,
    }, {}


def summarize(text):
    text = re.sub(r"sk-[A-Za-z0-9_-]+", "sk-***", text)
    return " ".join(text.split())[:300]


def send(route, pattern, model):
    body, extra_headers = body_of(pattern, model)
    headers = {
        "content-type": "application/json",
        "anthropic-version": "2023-06-01",
        "authorization": "Bearer " + os.environ["LITELLM_MASTER_KEY"],
        **extra_headers,
    }
    request = urllib.request.Request(ROUTES[route] + "/v1/messages", data=json.dumps(body).encode(), headers=headers)
    context = ssl._create_unverified_context() if route == "nginx" else None
    try:
        with urllib.request.urlopen(request, timeout=120, context=context) as response:
            status = response.status
            if not body.get("stream"):
                return status, "OK", summarize(response.read().decode(errors="replace"))
            # 上流のエラーはストリームの途中で（HTTP 200 のまま）返ることがあるため、
            # エラーイベントがないことと、最後まで届いたことを確かめる
            events, error = [], ""
            for raw in response:
                line = raw.decode(errors="replace").strip()
                if line.startswith("event:"):
                    events.append(line[6:].strip())
                elif line.startswith("data:") and events and events[-1] == "error":
                    error = line[5:].strip()
            if error:
                return status, "NG", "ストリームの途中でエラー: " + summarize(error)
            if "message_stop" not in events:
                return status, "NG", f"ストリームが最後まで届きませんでした（受け取ったイベント: {', '.join(events[-5:]) or 'なし'}）"
            return status, "OK", f"ストリームを最後まで受け取りました（イベント {len(events)} 件）"
    except urllib.error.HTTPError as e:
        return e.code, "NG", summarize(e.read().decode(errors="replace"))
    except Exception as e:
        return 0, "NG", f"{type(e).__name__} {summarize(str(e))}"


def main():
    with open("/app/config.yaml") as f:
        models = [entry.get("model_name") for entry in (yaml.safe_load(f) or {}).get("model_list") or []]
    cases = [("direct", pattern, model) for model in models for pattern in ("minimal", "stream", "tools", "thinking")]
    cases += [("nginx", pattern, REQUIRED_MODEL) for pattern in ("stream", "tools")]
    # 失敗するとリトライで時間がかかるため、並べて送る（結果は送った順に出力する）
    with ThreadPoolExecutor(max_workers=6) as pool:
        results = pool.map(lambda case: send(*case), cases)
        for (route, pattern, model), (status, result, summary) in zip(cases, results):
            print("\t".join(["RESULT", route, pattern, model, str(status), result, summary]), flush=True)


main()
