#!/bin/bash
set -euo pipefail
exec > /home/ubuntu/setup.log 2>&1
echo "=== BashForge bootstrap start: $(date) ==="

# System packages
apt-get update -qq
apt-get install -y --no-install-recommends apt-transport-https ca-certificates curl gnupg lsb-release git unzip jq nginx ufw certbot python3-certbot-nginx

# Docker
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
apt-get update -qq
apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
systemctl enable --now docker
usermod -aG docker ubuntu

# AWS CLI v2
curl -fsSL https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip -o /tmp/awscliv2.zip
unzip -q /tmp/awscliv2.zip -d /tmp/awscli
/tmp/awscli/aws/install
rm -rf /tmp/awscliv2.zip /tmp/awscli

# App directory
mkdir -p /opt/bashforge
chown ubuntu:ubuntu /opt/bashforge

# .env — Terraform bakes in real values at apply time
cat > /opt/bashforge/.env <<'ENVEOF'
REDIS_URL=redis://redis:6379/0
SESSION_TTL_SECONDS=${session_ttl}
MAX_CONCURRENT_SESSIONS=${max_sessions}
SECURE_COOKIES=true
CORS_ORIGINS=["https://${domain}"]
DEBUG=false
MOCK_ECS=false
AWS_DEFAULT_REGION=${region}
AWS_REGION=${region}
ECS_CLUSTER=bashforge
ECS_TASK_DEFINITION=bashforge-sandbox
ECS_SUBNETS=${ecs_subnets}
ECS_SECURITY_GROUPS=["${sandbox_sg}"]
ASSIGN_PUBLIC_IP=true
ENVEOF
chown ubuntu:ubuntu /opt/bashforge/.env
chmod 600 /opt/bashforge/.env

# docker-compose.prod.yml — Terraform bakes in real ECR registry
cat > /opt/bashforge/docker-compose.prod.yml <<'COMPOSEEOF'
services:
  redis:
    image: redis:7-alpine
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 5s
      timeout: 3s
      retries: 5
    logging:
      driver: json-file
      options: {max-size: "20m", max-file: "3"}

  backend:
    image: ${ecr_registry}/bashforge-backend:latest
    restart: unless-stopped
    env_file: /opt/bashforge/.env
    ports:
      - "127.0.0.1:8000:8000"
    depends_on:
      redis:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8000/api/health"]
      interval: 15s
      timeout: 5s
      retries: 3
      start_period: 10s
    logging:
      driver: json-file
      options: {max-size: "50m", max-file: "5"}

  frontend:
    image: ${ecr_registry}/bashforge-frontend:latest
    restart: unless-stopped
    ports:
      - "127.0.0.1:8080:80"
    depends_on:
      - backend
    logging:
      driver: json-file
      options: {max-size: "20m", max-file: "3"}

networks:
  default:
    name: bashforge-prod
COMPOSEEOF
chown ubuntu:ubuntu /opt/bashforge/docker-compose.prod.yml

# Nginx — HTTP only; certbot adds SSL after DNS is pointed
tee /etc/nginx/sites-available/bashforge > /dev/null <<'NGINXEOF'
server {
    listen 80;
    server_name ${domain};

    gzip on; gzip_vary on; gzip_comp_level 6;
    gzip_types text/plain text/css application/json application/javascript font/woff2;

    add_header X-Frame-Options DENY;
    add_header X-Content-Type-Options nosniff;

    location /api/ {
        proxy_pass         http://127.0.0.1:8000/api/;
        proxy_http_version 1.1;
        proxy_set_header   Host              $host;
        proxy_set_header   X-Real-IP         $remote_addr;
        proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto $scheme;
        proxy_read_timeout 130s;
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

ln -sf /etc/nginx/sites-available/bashforge /etc/nginx/sites-enabled/bashforge
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl enable --now nginx

# UFW
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable

echo "=== Bootstrap complete: $(date) ==="
