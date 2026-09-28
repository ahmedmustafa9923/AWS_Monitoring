#!/bin/bash
# -----------------------------------------------------------------------------
# user_data.sh.tpl  – runs ONCE when each EC2 server first boots.
# 1. installs Docker
# 2. starts a tiny service that writes every Docker event (container/image
#    create, start, stop, update, delete, pull...) as JSON to a log file
# 3. installs + starts the CloudWatch agent, which ships that log file and
#    memory/disk metrics to CloudWatch
# -----------------------------------------------------------------------------
set -euxo pipefail

# ---- 1. Docker ---------------------------------------------------------------
dnf update -y
dnf install -y docker amazon-cloudwatch-agent jq
systemctl enable --now docker
usermod -aG docker ec2-user

# ---- 2. Docker event logger -------------------------------------------------
touch /var/log/docker-events.log
cat > /etc/systemd/system/docker-events-logger.service <<'EOF'
[Unit]
Description=Stream Docker events (JSON) to /var/log/docker-events.log
After=docker.service
Requires=docker.service

[Service]
ExecStart=/bin/bash -c "/usr/bin/docker events --filter type=container --filter type=image --format '{{json .}}' >> /var/log/docker-events.log"
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now docker-events-logger

# ---- 3. CloudWatch agent (config pulled from SSM Parameter Store) -----------
/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
  -a fetch-config -m ec2 -s -c ssm:${cw_config_param}

# ---- 4. Optional: log in to ECR and run a sample container -----------------
aws ecr get-login-password --region ${region} \
  | docker login --username AWS --password-stdin ${account_id}.dkr.ecr.${region}.amazonaws.com || true

# Demo container so you immediately see events in CloudWatch. Remove in prod.
docker run -d --name hello --restart unless-stopped -p 80:80 public.ecr.aws/nginx/nginx:stable || true
