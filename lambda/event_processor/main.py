"""
event_processor – the "glue" Lambda of the monitoring stack.

It is triggered by TWO kinds of input:

1. EventBridge events (JSON with "detail-type"):
     - ECR Image Action        -> Docker image PUSHED (create/update) or DELETED
     - ECR Image Scan          -> vulnerability scan finished
     - EC2 Instance State-change Notification -> server started/stopped/terminated
     - AWS API Call via CloudTrail (source aws.eks) -> cluster / node group changes

2. CloudWatch Logs subscription payloads (JSON with "awslogs"):
     - Docker event log lines from the EC2 hosts (container create/update/destroy,
       image delete)
     - EKS audit log lines (Deployment / Service / Pod create/update/delete)

For every change it:
   a) writes one JSON audit record to S3  (permanent history, searchable with Athena)
   b) publishes a custom CloudWatch metric  <PROJECT>/Events  ChangeEvents{Source,Action}
   c) sends an SNS email for "important" actions (deletes, critical CVEs, terminations)
"""

import base64
import gzip
import json
import os
import uuid
from collections import Counter
from datetime import datetime, timezone

import boto3

s3 = boto3.client("s3")
cloudwatch = boto3.client("cloudwatch")
sns = boto3.client("sns")

BUCKET = os.environ["AUDIT_BUCKET"]
TOPIC_ARN = os.environ["SNS_TOPIC_ARN"]
METRIC_NAMESPACE = os.environ.get("METRIC_NAMESPACE", "CRS/Events")
ENVIRONMENT = os.environ.get("ENVIRONMENT", "dev")
# Comma separated "source:action" pairs that trigger an email
NOTIFY_ON = {
    x.strip().lower()
    for x in os.environ.get(
        "NOTIFY_ON",
        "ecr:delete,eks-audit:delete,docker:destroy,ec2:terminated,ecr-scan:critical,eks-api:delete",
    ).split(",")
    if x.strip()
}


# --------------------------------------------------------------------------- #
# Parsers – each returns a list of normalised records
# {source, action, target, actor, details}
# --------------------------------------------------------------------------- #
def parse_eventbridge(event):
    dtype = event.get("detail-type", "")
    d = event.get("detail", {}) or {}

    if dtype == "ECR Image Action":
        if d.get("result") != "SUCCESS":
            return []
        repo = d.get("repository-name")
        tag = d.get("image-tag") or d.get("image-digest", "")[:19]
        return [{
            "source": "ecr",
            "action": d.get("action-type", "unknown").lower(),  # push | delete
            "target": f"{repo}:{tag}",
            "actor": "ecr",
            "details": d,
        }]

    if dtype == "ECR Image Scan":
        counts = d.get("finding-severity-counts", {}) or {}
        severity = "critical" if counts.get("CRITICAL") else ("high" if counts.get("HIGH") else "ok")
        return [{
            "source": "ecr-scan",
            "action": severity,
            "target": f"{d.get('repository-name')}:{','.join(d.get('image-tags', []) or [])}",
            "actor": "ecr",
            "details": d,
        }]

    if dtype == "EC2 Instance State-change Notification":
        return [{
            "source": "ec2",
            "action": d.get("state", "unknown"),
            "target": d.get("instance-id"),
            "actor": "aws",
            "details": d,
        }]

    if dtype == "AWS API Call via CloudTrail":
        name = d.get("eventName", "")
        verb = ("create" if name.startswith("Create") else
                "delete" if name.startswith("Delete") else
                "update" if name.startswith(("Update", "Tag", "Untag", "Associate")) else
                name.lower())
        return [{
            "source": "eks-api",
            "action": verb,
            "target": f"{name} {json.dumps(d.get('requestParameters') or {})[:300]}",
            "actor": (d.get("userIdentity") or {}).get("arn", "unknown"),
            "details": d,
        }]

    return [{
        "source": event.get("source", "unknown"),
        "action": dtype or "unknown",
        "target": "",
        "actor": "",
        "details": d,
    }]


def parse_awslogs(event):
    raw = gzip.decompress(base64.b64decode(event["awslogs"]["data"]))
    payload = json.loads(raw)
    if payload.get("messageType") != "DATA_MESSAGE":
        return []  # CloudWatch sends a CONTROL_MESSAGE when the subscription is created

    group = payload.get("logGroup", "")
    stream = payload.get("logStream", "")
    records = []

    for le in payload.get("logEvents", []):
        try:
            msg = json.loads(le["message"])
        except (ValueError, KeyError):
            continue

        if "docker-events" in group:
            attrs = (msg.get("Actor") or {}).get("Attributes") or {}
            records.append({
                "source": "docker",
                "action": msg.get("Action", "unknown"),
                "target": f"{msg.get('Type')}/{attrs.get('name') or msg.get('id', '')[:12]} ({attrs.get('image', '')})",
                "actor": f"host:{stream}",
                "details": msg,
            })
        else:  # EKS audit log
            ref = msg.get("objectRef") or {}
            records.append({
                "source": "eks-audit",
                "action": msg.get("verb", "unknown"),
                "target": f"{ref.get('resource')}/{ref.get('namespace', '-')}/{ref.get('name', '')}",
                "actor": (msg.get("user") or {}).get("username", "unknown"),
                "details": {
                    "requestURI": msg.get("requestURI"),
                    "sourceIPs": msg.get("sourceIPs"),
                    "userAgent": msg.get("userAgent"),
                    "responseCode": (msg.get("responseStatus") or {}).get("code"),
                    "auditID": msg.get("auditID"),
                },
            })
    return records


# --------------------------------------------------------------------------- #
# Outputs
# --------------------------------------------------------------------------- #
def write_to_s3(rec, now):
    key = (f"changes/source={rec['source']}/"
           f"year={now:%Y}/month={now:%m}/day={now:%d}/"
           f"{now:%H%M%S}-{uuid.uuid4().hex[:8]}.json")
    body = {"timestamp": now.isoformat(), "environment": ENVIRONMENT, **rec}
    s3.put_object(Bucket=BUCKET, Key=key, Body=json.dumps(body, default=str).encode(),
                  ContentType="application/json")
    return key


def publish_metrics(records):
    counts = Counter((r["source"], r["action"]) for r in records)
    data = [{
        "MetricName": "ChangeEvents",
        "Dimensions": [{"Name": "Source", "Value": src}, {"Name": "Action", "Value": act}],
        "Value": n,
        "Unit": "Count",
    } for (src, act), n in counts.items()]
    for i in range(0, len(data), 500):
        cloudwatch.put_metric_data(Namespace=METRIC_NAMESPACE, MetricData=data[i:i + 500])


def notify(rec, key):
    if f"{rec['source']}:{rec['action']}".lower() not in NOTIFY_ON:
        return
    subject = f"[{ENVIRONMENT}] {rec['source']} {rec['action']}: {rec['target']}"[:99]
    message = (f"Change detected\n\n"
               f"Source : {rec['source']}\nAction : {rec['action']}\n"
               f"Target : {rec['target']}\nBy     : {rec['actor']}\n\n"
               f"Full record: s3://{BUCKET}/{key}")
    sns.publish(TopicArn=TOPIC_ARN, Subject=subject, Message=message)


# --------------------------------------------------------------------------- #
def handler(event, context):
    records = parse_awslogs(event) if "awslogs" in event else parse_eventbridge(event)
    if not records:
        return {"processed": 0}

    now = datetime.now(timezone.utc)
    for rec in records:
        key = write_to_s3(rec, now)
        notify(rec, key)
        print(json.dumps({k: rec[k] for k in ("source", "action", "target", "actor")}))

    publish_metrics(records)
    return {"processed": len(records)}
