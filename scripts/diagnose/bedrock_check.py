"""Bedrock への接続、AWS の認証情報、config.yaml の各モデルを呼ぶ権限を確かめる（課金なし）。

scripts/diagnose/diagnose-server.sh から、動いている LiteLLM のコンテナの中で実行する。
LiteLLM と同じ環境変数（AWS_*、HTTPS_PROXY など）と /app/config.yaml を使う。

モデルには本文が空の InvokeModel と InvokeModelWithResponseStream を送る。AWS は本文の検証より前に
認証と IAM の権限を確かめるため、ValidationException が返れば、認証と権限は通っている
（推論はしないので課金されない）。ストリーミングの推論は InvokeModelWithResponseStream という
別の権限を使うため、両方を確かめる。

結果は「<項目> <OK|NG> <内容>」の形で 1 行ずつ出力する。
"""

import os
import re
import urllib.error
import urllib.request

import yaml


def clean(text):
    text = re.sub(r"://[^/@\s]*@", "://***@", str(text))
    return " ".join(text.split())[:200]


def main():
    region = os.environ.get("AWS_REGION_NAME") or "us-east-1"
    print("REGION OK", region)
    print("PROXY OK", "あり" if os.environ.get("HTTPS_PROXY") else "なし（直接接続）")

    host = f"bedrock-runtime.{region}.amazonaws.com"
    try:
        urllib.request.urlopen(f"https://{host}/", timeout=15)
        print("REACH OK", host)
    except urllib.error.HTTPError:
        # HTTP の応答が返れば、ネットワークと TLS は通っている
        print("REACH OK", host)
    except Exception as e:
        reason = getattr(e, "reason", e)
        print("REACH NG", f"{host}: {type(e).__name__} {clean(reason)}")

    if not (os.environ.get("AWS_ACCESS_KEY_ID") and os.environ.get("AWS_SECRET_ACCESS_KEY")):
        print("CREDS NG AWS_ACCESS_KEY_ID・AWS_SECRET_ACCESS_KEY がコンテナにありません")
        return

    import boto3
    import botocore.config
    import botocore.exceptions

    config = botocore.config.Config(connect_timeout=10, read_timeout=20, retries={"max_attempts": 1})
    try:
        sts = boto3.client("sts", region_name=region, endpoint_url=f"https://sts.{region}.amazonaws.com", config=config)
        print("CREDS OK", sts.get_caller_identity()["Arn"])
    except botocore.exceptions.ClientError as e:
        print("CREDS NG", e.response["Error"]["Code"])
    except Exception as e:
        print("CREDS NG", type(e).__name__, clean(e))

    with open("/app/config.yaml") as f:
        models = (yaml.safe_load(f) or {}).get("model_list") or []
    runtime = boto3.client("bedrock-runtime", region_name=region, config=config)
    calls = (
        ("InvokeModel", runtime.invoke_model),
        ("InvokeModelWithResponseStream", runtime.invoke_model_with_response_stream),
    )
    for entry in models:
        model = (entry.get("litellm_params") or {}).get("model", "")
        if not model.startswith("bedrock/"):
            continue
        model_id = re.sub(r"^bedrock/(invoke/|converse/)?", "", model)
        name = entry.get("model_name", model_id)
        for action, call in calls:
            try:
                call(modelId=model_id, body=b"{}", contentType="application/json")
                print("MODEL OK", f"{name} {action}")
            except botocore.exceptions.ClientError as e:
                code = e.response["Error"]["Code"]
                message = e.response["Error"].get("Message", "")
                kind = "OK" if code == "ValidationException" else "NG"
                print("MODEL", kind, f"{name} {action}: {code} {clean(message)}")
            except Exception as e:
                print("MODEL NG", f"{name} {action}: {type(e).__name__} {clean(e)}")


main()
