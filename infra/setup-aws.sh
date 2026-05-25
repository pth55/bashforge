#!/usr/bin/env bash
# =============================================================================
# setup-aws.sh  —  One-time AWS resource creation for BashForge
# Run from your local machine (needs AWS CLI configured with admin credentials)
# Usage: AWS_ACCOUNT_ID=123456789012 bash infra/setup-aws.sh
# =============================================================================
set -euo pipefail

REGION="${AWS_DEFAULT_REGION:-ap-south-1}"
ACCOUNT="${AWS_ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text)}"
PREFIX="bashforge"

echo "============================================================"
echo " BashForge AWS Setup"
echo " Account : $ACCOUNT"
echo " Region  : $REGION"
echo "============================================================"

# ── 1. ECR Repositories ───────────────────────────────────────────
echo ""
echo "[1/9] Creating ECR repositories..."
for repo in frontend backend sandbox; do
    if aws ecr describe-repositories --repository-names "${PREFIX}-${repo}" \
        --region "$REGION" &>/dev/null; then
        echo "  ${PREFIX}-${repo} already exists"
    else
        aws ecr create-repository \
            --repository-name "${PREFIX}-${repo}" \
            --image-scanning-configuration scanOnPush=true \
            --region "$REGION" \
            --query 'repository.repositoryUri' --output text
    fi
done
ECR_REGISTRY="${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com"
echo "  ECR registry: $ECR_REGISTRY"

# ── 2. ECS Task Execution Role ────────────────────────────────────
echo ""
echo "[2/9] Creating ECS task execution role..."
EXEC_ROLE="bashforge-ecs-execution-role"
if ! aws iam get-role --role-name "$EXEC_ROLE" &>/dev/null; then
    aws iam create-role \
        --role-name "$EXEC_ROLE" \
        --assume-role-policy-document '{
          "Version":"2012-10-17",
          "Statement":[{
            "Effect":"Allow",
            "Principal":{"Service":"ecs-tasks.amazonaws.com"},
            "Action":"sts:AssumeRole"
          }]
        }' > /dev/null
    aws iam attach-role-policy \
        --role-name "$EXEC_ROLE" \
        --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy
    echo "  Created $EXEC_ROLE"
else
    echo "  $EXEC_ROLE already exists"
fi
EXEC_ROLE_ARN="arn:aws:iam::${ACCOUNT}:role/${EXEC_ROLE}"

# ── 3. EC2 Instance Role (for App EC2 to call ECS) ────────────────
echo ""
echo "[3/9] Creating EC2 instance role..."
EC2_ROLE="bashforge-ec2-role"
if ! aws iam get-role --role-name "$EC2_ROLE" &>/dev/null; then
    aws iam create-role \
        --role-name "$EC2_ROLE" \
        --assume-role-policy-document '{
          "Version":"2012-10-17",
          "Statement":[{
            "Effect":"Allow",
            "Principal":{"Service":"ec2.amazonaws.com"},
            "Action":"sts:AssumeRole"
          }]
        }' > /dev/null

    # Inline policy: run/stop/describe ECS tasks + ECR login
    aws iam put-role-policy \
        --role-name "$EC2_ROLE" \
        --policy-name "bashforge-ecs-access" \
        --policy-document "{
          \"Version\":\"2012-10-17\",
          \"Statement\":[
            {
              \"Effect\":\"Allow\",
              \"Action\":[
                \"ecs:RunTask\",\"ecs:StopTask\",\"ecs:DescribeTasks\",
                \"ecs:ListTasks\",\"ecs:DescribeTaskDefinition\"
              ],
              \"Resource\":\"*\"
            },
            {
              \"Effect\":\"Allow\",
              \"Action\":\"iam:PassRole\",
              \"Resource\":\"${EXEC_ROLE_ARN}\"
            },
            {
              \"Effect\":\"Allow\",
              \"Action\":[
                \"ecr:GetAuthorizationToken\",
                \"ecr:BatchGetImage\",
                \"ecr:GetDownloadUrlForLayer\"
              ],
              \"Resource\":\"*\"
            }
          ]
        }"
    echo "  Created $EC2_ROLE"
else
    echo "  $EC2_ROLE already exists"
fi

# ── 4. EC2 Instance Profile ───────────────────────────────────────
echo ""
echo "[4/9] Creating EC2 instance profile..."
EC2_PROFILE="bashforge-ec2-profile"
if ! aws iam get-instance-profile --instance-profile-name "$EC2_PROFILE" &>/dev/null; then
    aws iam create-instance-profile --instance-profile-name "$EC2_PROFILE" > /dev/null
    aws iam add-role-to-instance-profile \
        --instance-profile-name "$EC2_PROFILE" \
        --role-name "$EC2_ROLE"
    echo "  Created $EC2_PROFILE"
else
    echo "  $EC2_PROFILE already exists"
fi

# ── 5. ECS Cluster ────────────────────────────────────────────────
echo ""
echo "[5/9] Creating ECS cluster..."
aws ecs create-cluster \
    --cluster-name bashforge \
    --capacity-providers FARGATE FARGATE_SPOT \
    --region "$REGION" \
    --query 'cluster.clusterName' --output text
echo "  Cluster: bashforge"

# ── 6. CloudWatch Log Group ───────────────────────────────────────
echo ""
echo "[6/9] Creating CloudWatch log group..."
aws logs create-log-group \
    --log-group-name "/ecs/bashforge-sandbox" \
    --region "$REGION" 2>/dev/null || echo "  Log group already exists"
aws logs put-retention-policy \
    --log-group-name "/ecs/bashforge-sandbox" \
    --retention-in-days 7 \
    --region "$REGION"
echo "  Log group: /ecs/bashforge-sandbox (7-day retention)"

# ── 7. Default VPC public subnets ────────────────────────────────
echo ""
echo "[7/9] Fetching default VPC public subnets..."
DEFAULT_VPC=$(aws ec2 describe-vpcs \
    --filters "Name=isDefault,Values=true" \
    --query 'Vpcs[0].VpcId' --output text --region "$REGION")
echo "  Default VPC: $DEFAULT_VPC"

SUBNETS=$(aws ec2 describe-subnets \
    --filters "Name=vpc-id,Values=${DEFAULT_VPC}" \
              "Name=map-public-ip-on-launch,Values=true" \
    --query 'Subnets[*].SubnetId' --output text --region "$REGION")
SUBNET_ARRAY=$(echo "$SUBNETS" | tr '\t' '\n' | jq -R . | jq -sc .)
echo "  Public subnets: $SUBNET_ARRAY"

# ── 8. Security Group for sandbox containers ──────────────────────
echo ""
echo "[8/9] Creating sandbox security group..."
SG_NAME="bashforge-sandbox-sg"
EXISTING_SG=$(aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=${SG_NAME}" \
              "Name=vpc-id,Values=${DEFAULT_VPC}" \
    --query 'SecurityGroups[0].GroupId' --output text --region "$REGION" 2>/dev/null || true)

if [[ -z "$EXISTING_SG" || "$EXISTING_SG" == "None" ]]; then
    SG_ID=$(aws ec2 create-security-group \
        --group-name "$SG_NAME" \
        --description "BashForge sandbox WebSocket port" \
        --vpc-id "$DEFAULT_VPC" \
        --region "$REGION" \
        --query 'GroupId' --output text)
    # Allow backend EC2 to reach sandbox on 8765
    # For tighter security, replace 0.0.0.0/0 with your App EC2's Elastic IP
    aws ec2 authorize-security-group-ingress \
        --group-id "$SG_ID" \
        --protocol tcp \
        --port 8765 \
        --cidr 0.0.0.0/0 \
        --region "$REGION"
    echo "  Created SG: $SG_ID"
else
    SG_ID="$EXISTING_SG"
    echo "  SG already exists: $SG_ID"
fi

# ── 9. Register ECS Task Definition ──────────────────────────────
echo ""
echo "[9/9] Registering ECS task definition..."
SANDBOX_IMAGE="${ECR_REGISTRY}/${PREFIX}-sandbox:latest"

aws ecs register-task-definition \
    --family "bashforge-sandbox" \
    --network-mode awsvpc \
    --requires-compatibilities FARGATE \
    --cpu "256" \
    --memory "512" \
    --execution-role-arn "$EXEC_ROLE_ARN" \
    --region "$REGION" \
    --container-definitions "[
      {
        \"name\": \"bash-session\",
        \"image\": \"${SANDBOX_IMAGE}\",
        \"essential\": true,
        \"portMappings\": [{\"containerPort\": 8765, \"protocol\": \"tcp\"}],
        \"environment\": [
          {\"name\": \"PORT\", \"value\": \"8765\"}
        ],
        \"logConfiguration\": {
          \"logDriver\": \"awslogs\",
          \"options\": {
            \"awslogs-group\": \"/ecs/bashforge-sandbox\",
            \"awslogs-region\": \"${REGION}\",
            \"awslogs-stream-prefix\": \"ecs\"
          }
        },
        \"readonlyRootFilesystem\": false,
        \"linuxParameters\": {
          \"capabilities\": {\"drop\": [\"ALL\"]},
          \"initProcessEnabled\": true
        }
      }
    ]" \
    --query 'taskDefinition.taskDefinitionArn' --output text
echo "  Task definition registered: bashforge-sandbox"

# ── Summary ───────────────────────────────────────────────────────
echo ""
echo "============================================================"
echo " All AWS resources created. Add these to /opt/bashforge/.env"
echo " on your App EC2:"
echo "============================================================"
echo ""
echo "AWS_DEFAULT_REGION=${REGION}"
echo "ECS_CLUSTER=bashforge"
echo "ECS_TASK_DEFINITION=bashforge-sandbox"
echo "ECS_SUBNETS=${SUBNET_ARRAY}"
echo "ECS_SECURITY_GROUPS=[\"${SG_ID}\"]"
echo "ASSIGN_PUBLIC_IP=true"
echo ""
echo " Attach the EC2 instance profile to your App EC2:"
echo "   aws ec2 associate-iam-instance-profile \\"
echo "       --instance-id <YOUR_APP_EC2_INSTANCE_ID> \\"
echo "       --iam-instance-profile Name=${EC2_PROFILE} \\"
echo "       --region ${REGION}"
echo ""
echo " Add these GitHub Actions secrets:"
echo "   AWS_ACCESS_KEY_ID      — IAM user with ECR push + ECS permissions"
echo "   AWS_SECRET_ACCESS_KEY  — same IAM user"
echo "   EC2_APP_HOST           — App EC2 public IP or hostname"
echo "   EC2_APP_SSH_KEY        — private SSH key for ubuntu@EC2_APP_HOST"
echo ""
echo "============================================================"
echo " Done: $(date)"
echo "============================================================"
