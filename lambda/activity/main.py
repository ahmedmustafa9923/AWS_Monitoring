"""
activity – public, read-only feed for the website.

Called by CloudFront at https://<your-domain>/api/activity (never directly: the
function URL only accepts signed requests from your CloudFront distribution).
Reads the latest change records the event_processor wrote to S3 and returns a
SANITISED list: no AWS account IDs, no usernames/ARNs, no instance IDs.
"""
import json
import os
import re
import time
from datetime import datetime, timedelta, timezone

import boto3

s3 = boto3.client("s3")
BUCKET = os.environ["AUDIT_BUCKET"]
HOSTS = json.loads(os.environ.get("HOSTS", "{}"))  # {"i-0abc...": "app-1"}
MAX_EVENTS = int(os.environ.get("MAX_EVENTS", "25"))
DAYS_BACK = int(os.environ.get("DAYS_BACK", "7"))
CACHE_SECONDS = 30

SOURCES = {
    "docker": "Docker",
    "ecr": "Image registry",
    "ecr-scan": "Security scan",
    "ec2": "Server",
    "eks-audit": "Kubernetes",
    "eks-api": "EKS cluster",
}
ACCOUNT_RE = re.compile(r"\b\d{12}\b")
ECR_HOST_RE = re.compile(r"\b\d{12}\.dkr\.ecr\.[a-z0-9-]+\.amazonaws\.com/?")
INSTANCE_RE = re.compile(r"\bi-[0-9a-f]{8,17}\b")

_cache = {"at": 0.0, "body": None}


def host_name(instance_id):
    return HOSTS.get(instance_id, "server")


def clean(text):
    text = ECR_HOST_RE.sub("", text or "")
    text = INSTANCE_RE.sub(lambda m: host_name(m.group(0)), text)
    return ACCOUNT_RE.sub("•••", text)[:160]


def sanitise(rec):
    src = rec.get("source", "")
    target = rec.get("target", "")
    where = ""
    if src == "docker":
        where = host_name(rec.get("actor", "").replace("host:", ""))
    elif src == "eks-api":
        target = target.split(" ", 1)[0]  # keep only the API action name
    return {
        "time": rec.get("timestamp"),
        "source": SOURCES.get(src, src),
        "action": rec.get("action", ""),
        "target": clean(target),
        "where": where,
    }


def latest_keys():
    """Keys look like changes/source=X/year=YYYY/month=MM/day=DD/HHMMSS-id.json"""
    today = datetime.now(timezone.utc).date()
    keys = []
    for src in SOURCES:
        for d in range(DAYS_BACK):
            day = today - timedelta(days=d)
            prefix = f"changes/source={src}/year={day:%Y}/month={day:%m}/day={day:%d}/"
            for page in s3.get_paginator("list_objects_v2").paginate(Bucket=BUCKET, Prefix=prefix):
                for obj in page.get("Contents", []):
                    keys.append((f"{day:%Y%m%d}{obj['Key'].rsplit('/', 1)[-1]}", obj["Key"]))
    keys.sort(reverse=True)
    return [k for _, k in keys[:MAX_EVENTS]]


def build_body():
    events = []
    for key in latest_keys():
        try:
            rec = json.loads(s3.get_object(Bucket=BUCKET, Key=key)["Body"].read())
            events.append(sanitise(rec))
        except Exception as exc:  # one bad object must not break the feed
            print(f"skip {key}: {exc}")
    return json.dumps({"updated": datetime.now(timezone.utc).isoformat(), "events": events})


def handler(event, context):
    now = time.time()
    if _cache["body"] is None or now - _cache["at"] > CACHE_SECONDS:
        _cache["body"], _cache["at"] = build_body(), now
    return {
        "statusCode": 200,
        "headers": {
            "Content-Type": "application/json",
            "Cache-Control": f"public, max-age={CACHE_SECONDS}",
        },
        "body": _cache["body"],
    }
