#!/usr/bin/env bash
# =============================================================================
# ec2-app-setup.sh  —  Bootstrap App EC2 (Frontend + Backend + Redis)
# Run as ubuntu user: bash ec2-app-setup.sh
# Prereq: EC2 must have an IAM instance profile with ECS + ECR permissions
#         (created by infra/setup-aws.sh)
# =============================================================================
set -euo pipefail
LOGFILE="/home/ubuntu/setup-app.log"
exec > >(tee -a "$LOGFILE") 2>&1

echo "============================================================"
echo " BashForge App EC2 Setup  —  $(date)"
echo "============================================================"

# ── 1. System packages ────────────────────────────────────────────
echo "[1/8] Installing system packages..."
sudo apt-get update -qq
sudo apt-get install -y --no-install-recommends \
    apt-transport-https ca-certificates curl gnupg lsb-release \
    git unzip jq htop ncdu ufw certbot python3-certbot-nginx nginx

# ── 2. Docker ─────────────────────────────────────────────────────
echo "[2/8] Installing Docker..."
if ! command -v docker &>/dev/null; then
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
        sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) \
        signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] \
        https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | \
        sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    sudo apt-get update -qq
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
    sudo systemctl enable --now docker
    sudo usermod -aG docker ubuntu
    echo "  Docker installed: $(docker --version)"
else
    echo "  Docker already installed"
fi

# ── 3. AWS CLI v2 ─────────────────────────────────────────────────
echo "[3/8] Installing AWS CLI v2..."
if ! command -v aws &>/dev/null; then
    curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
    unzip -q /tmp/awscliv2.zip -d /tmp/awscli
    sudo /tmp/awscli/aws/install
    rm -rf /tmp/awscliv2.zip /tmp/awscli
    echo "  AWS CLI: $(aws --version)"
else
    echo "  AWS CLI already installed"
fi

# ── 4. App directory ──────────────────────────────────────────────
echo "[4/8] Creating app directory..."
sudo mkdir -p /opt/bashforge
sudo chown ubuntu:ubuntu /opt/bashforge

# ── 5. .env template ─────────────────────────────────────────────
echo "[5/8] Writing .env template..."
if [[ ! -f /opt/bashforge/.env ]]; then
cat > /opt/bashforge/.env <<'ENVEOF'
# ================================================================
# BashForge Production Environment  — EDIT BEFORE FIRST DEPLOY
# ================================================================

# Redis (local on this EC2)
REDIS_URL=redis://redis:6379/0

# Session
SESSION_TTL_SECONDS=3600
MAX_CONCURRENT_SESSIONS=20

# Security
SECURE_COOKIES=true

# CORS — your domain
CORS_ORIGINS=["https://yourdomain.com"]

# App
DEBUG=false
MOCK_ECS=false

# AWS — credentials come from EC2 instance role, no keys needed here
AWS_DEFAULT_REGION=ap-south-1

# ECS — fill from infra/setup-aws.sh output
ECS_CLUSTER=bashforge
ECS_TASK_DEFINITION=bashforge-sandbox
ECS_SUBNETS=["subnet-REPLACE","subnet-REPLACE"]
ECS_SECURITY_GROUPS=["sg-REPLACE"]
ASSIGN_PUBLIC_IP=true
ENVEOF
echo "  Created /opt/bashforge/.env — edit with real subnet/SG values"
else
    echo "  /opt/bashforge/.env already exists — skipping"
fi

# ── 6. Nginx ──────────────────────────────────────────────────────
echo "[6/8] Configuring Nginx..."
sudo tee /etc/nginx/sites-available/bashforge > /dev/null <<'NGINXEOF'
server {
    listen 80;
    server_name _;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl http2;
    server_name yourdomain.com;  # !! Replace with your domain !!

    ssl_certificate     /etc/letsencrypt/live/yourdomain.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/yourdomain.com/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;
    ssl_session_cache   shared:SSL:10m;

    add_header X-Frame-Options        DENY;
    add_header X-Content-Type-Options nosniff;
    add_header Referrer-Policy        strict-origin-when-cross-origin;

    gzip on; gzip_vary on; gzip_comp_level 6;
    gzip_types text/plain text/css application/json application/javascript
               text/xml application/xml font/woff2;

    location /api/ {
        proxy_pass         http://127.0.0.1:8000/api/;
        proxy_http_version 1.1;
        proxy_set_header   Host              $host;
        proxy_set_header   X-Real-IP         $remote_addr;
        proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto $scheme;
        proxy_read_timeout 30s;
    }

    location /ws/ {
        proxy_pass         http://127.0.0.1:8000/ws/;
        proxy_http_version 1.1;
        proxy_set_header   Upgrade    $http_upgrade;
        proxy_set_header   Connection "upgrade";
        proxy_set_header   Host              $host;
        proxy_set_header   X-Real-IP         $remote_addr;
        proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto $scheme;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }

    location / {
        proxy_pass         http://127.0.0.1:8080/;
        proxy_http_version 1.1;
        proxy_set_header   Host      $host;
        proxy_set_header   X-Real-IP $remote_addr;
        proxy_read_timeout 15s;
    }
}
NGINXEOF

sudo ln -sf /etc/nginx/sites-available/bashforge /etc/nginx/sites-enabled/bashforge
sudo rm -f /etc/nginx/sites-enabled/default
sudo nginx -t && sudo systemctl enable --now nginx
echo "  Nginx configured"

# ── 7. Firewall ───────────────────────────────────────────────────
echo "[7/8] Configuring UFW firewall..."
sudo ufw --force reset
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 22/tcp   comment "SSH"
sudo ufw allow 80/tcp   comment "HTTP"
sudo ufw allow 443/tcp  comment "HTTPS"
sudo ufw --force enable
sudo ufw status verbose

# ── 8. Done ───────────────────────────────────────────────────────
echo "[8/8] Setup complete"
echo ""
echo "============================================================"
echo " NEXT STEPS:"
echo "============================================================"
echo ""
echo " 1. Run infra/setup-aws.sh from your local machine to create"
echo "    ECR repos, ECS cluster, IAM roles, and task definition."
echo "    It will print subnet IDs and SG ID to put in .env."
echo ""
echo " 2. Edit /opt/bashforge/.env — fill ECS_SUBNETS, ECS_SECURITY_GROUPS,"
echo "    CORS_ORIGINS with your domain."
echo ""
echo " 3. Update /etc/nginx/sites-available/bashforge — replace"
echo "    'yourdomain.com' with your actual domain."
echo ""
echo " 4. Get SSL cert:"
echo "    sudo certbot --nginx -d yourdomain.com --non-interactive \\"
echo "        --agree-tos -m your@email.com"
echo ""
echo " 5. First deploy — pull and run:"
echo "    cd /opt/bashforge"
echo "    REGISTRY=\$(aws ecr describe-repositories \\"
echo "        --repository-names bashforge-frontend \\"
echo "        --query 'repositories[0].repositoryUri' --output text | cut -d/ -f1)"
echo "    aws ecr get-login-password --region ap-south-1 | \\"
echo "        docker login --username AWS --password-stdin \"\$REGISTRY\""
echo "    # (deploy.yml will handle subsequent deploys automatically)"
echo ""
echo " 6. Attach IAM instance profile to this EC2:"
echo "    aws ec2 associate-iam-instance-profile \\"
echo "        --instance-id <THIS_EC2_ID> \\"
echo "        --iam-instance-profile Name=bashforge-ec2-profile"
echo ""
echo "============================================================"
echo " Setup finished: $(date)"
echo "============================================================"
