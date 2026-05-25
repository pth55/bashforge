# setup-aws.ps1  —  One-time AWS resource creation for BashForge
# Run in PowerShell: .\infra\setup-aws.ps1
# Prereq: AWS CLI installed and configured (aws configure)

$ErrorActionPreference = "Stop"

if ($env:AWS_DEFAULT_REGION) { $REGION = $env:AWS_DEFAULT_REGION } else { $REGION = "ap-south-1" }
if ($env:AWS_ACCOUNT_ID) { $ACCOUNT = $env:AWS_ACCOUNT_ID } else { $ACCOUNT = (aws sts get-caller-identity --query Account --output text) }
$PREFIX = "bashforge"
$ECR_REGISTRY = "$ACCOUNT.dkr.ecr.$REGION.amazonaws.com"

Write-Host "============================================================"
Write-Host " BashForge AWS Setup"
Write-Host " Account : $ACCOUNT"
Write-Host " Region  : $REGION"
Write-Host "============================================================"

# 1. ECR Repositories
Write-Host ""
Write-Host "[1/9] Creating ECR repositories..."
foreach ($repo in @("frontend","backend","sandbox")) {
    $null = aws ecr describe-repositories --repository-names "$PREFIX-$repo" --region $REGION 2>&1
    if ($LASTEXITCODE -ne 0) {
        aws ecr create-repository --repository-name "$PREFIX-$repo" --image-scanning-configuration scanOnPush=true --region $REGION --query "repository.repositoryUri" --output text
    } else {
        Write-Host "  $PREFIX-$repo already exists"
    }
}
Write-Host "  ECR registry: $ECR_REGISTRY"

# 2. ECS Task Execution Role
Write-Host ""
Write-Host "[2/9] Creating ECS task execution role..."
$EXEC_ROLE = "bashforge-ecs-execution-role"
$null = aws iam get-role --role-name $EXEC_ROLE 2>&1
if ($LASTEXITCODE -ne 0) {
    '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ecs-tasks.amazonaws.com"},"Action":"sts:AssumeRole"}]}' | Out-File -FilePath "$env:TEMP\assume-ecs.json" -Encoding utf8
    $null = aws iam create-role --role-name $EXEC_ROLE --assume-role-policy-document "file://$env:TEMP\assume-ecs.json"
    aws iam attach-role-policy --role-name $EXEC_ROLE --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy
    Write-Host "  Created $EXEC_ROLE"
} else {
    Write-Host "  $EXEC_ROLE already exists"
}
$EXEC_ROLE_ARN = "arn:aws:iam::${ACCOUNT}:role/${EXEC_ROLE}"

# 3. EC2 Instance Role
Write-Host ""
Write-Host "[3/9] Creating EC2 instance role..."
$EC2_ROLE = "bashforge-ec2-role"
$null = aws iam get-role --role-name $EC2_ROLE 2>&1
if ($LASTEXITCODE -ne 0) {
    '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}' | Out-File -FilePath "$env:TEMP\assume-ec2.json" -Encoding utf8
    $null = aws iam create-role --role-name $EC2_ROLE --assume-role-policy-document "file://$env:TEMP\assume-ec2.json"
    $ec2Policy = '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["ecs:RunTask","ecs:StopTask","ecs:DescribeTasks","ecs:ListTasks","ecs:DescribeTaskDefinition"],"Resource":"*"},{"Effect":"Allow","Action":"iam:PassRole","Resource":"EXEC_ROLE_ARN_PLACEHOLDER"},{"Effect":"Allow","Action":["ecr:GetAuthorizationToken","ecr:BatchGetImage","ecr:GetDownloadUrlForLayer"],"Resource":"*"}]}'
    $ec2Policy = $ec2Policy.Replace("EXEC_ROLE_ARN_PLACEHOLDER", $EXEC_ROLE_ARN)
    $ec2Policy | Out-File -FilePath "$env:TEMP\ec2-policy.json" -Encoding utf8
    aws iam put-role-policy --role-name $EC2_ROLE --policy-name "bashforge-ecs-access" --policy-document "file://$env:TEMP\ec2-policy.json"
    Write-Host "  Created $EC2_ROLE"
} else {
    Write-Host "  $EC2_ROLE already exists"
}

# 4. EC2 Instance Profile
Write-Host ""
Write-Host "[4/9] Creating EC2 instance profile..."
$EC2_PROFILE = "bashforge-ec2-profile"
$null = aws iam get-instance-profile --instance-profile-name $EC2_PROFILE 2>&1
if ($LASTEXITCODE -ne 0) {
    $null = aws iam create-instance-profile --instance-profile-name $EC2_PROFILE
    aws iam add-role-to-instance-profile --instance-profile-name $EC2_PROFILE --role-name $EC2_ROLE
    Write-Host "  Created $EC2_PROFILE"
} else {
    Write-Host "  $EC2_PROFILE already exists"
}

# 5. ECS Cluster
Write-Host ""
Write-Host "[5/9] Creating ECS cluster..."
aws ecs create-cluster --cluster-name bashforge --capacity-providers FARGATE FARGATE_SPOT --region $REGION --query "cluster.clusterName" --output text

# 6. CloudWatch Log Group
Write-Host ""
Write-Host "[6/9] Creating CloudWatch log group..."
$null = aws logs create-log-group --log-group-name "/ecs/bashforge-sandbox" --region $REGION 2>&1
aws logs put-retention-policy --log-group-name "/ecs/bashforge-sandbox" --retention-in-days 7 --region $REGION
Write-Host "  Log group: /ecs/bashforge-sandbox (7-day retention)"

# 7. Default VPC public subnets
Write-Host ""
Write-Host "[7/9] Fetching default VPC public subnets..."
$DEFAULT_VPC = (aws ec2 describe-vpcs --filters "Name=isDefault,Values=true" --query "Vpcs[0].VpcId" --output text --region $REGION)
Write-Host "  Default VPC: $DEFAULT_VPC"
$SUBNETS_RAW = (aws ec2 describe-subnets --filters "Name=vpc-id,Values=$DEFAULT_VPC" "Name=map-public-ip-on-launch,Values=true" --query "Subnets[*].SubnetId" --output text --region $REGION)
$SUBNET_LIST = ($SUBNETS_RAW -split "\s+" | Where-Object { $_ } | ForEach-Object { "`"$_`"" }) -join ","
$SUBNET_ARRAY = "[$SUBNET_LIST]"
Write-Host "  Subnets: $SUBNET_ARRAY"

# 8. Security Group
Write-Host ""
Write-Host "[8/9] Creating sandbox security group..."
$SG_NAME = "bashforge-sandbox-sg"
$EXISTING_SG = (aws ec2 describe-security-groups --filters "Name=group-name,Values=$SG_NAME" "Name=vpc-id,Values=$DEFAULT_VPC" --query "SecurityGroups[0].GroupId" --output text --region $REGION 2>&1)
if ((-not $EXISTING_SG) -or ($EXISTING_SG -eq "None") -or ($EXISTING_SG -match "error")) {
    $SG_ID = (aws ec2 create-security-group --group-name $SG_NAME --description "BashForge sandbox WebSocket port" --vpc-id $DEFAULT_VPC --region $REGION --query "GroupId" --output text)
    $null = aws ec2 authorize-security-group-ingress --group-id $SG_ID --protocol tcp --port 8765 --cidr 0.0.0.0/0 --region $REGION
    Write-Host "  Created SG: $SG_ID"
} else {
    $SG_ID = $EXISTING_SG
    Write-Host "  SG already exists: $SG_ID"
}

# 9. ECS Task Definition
Write-Host ""
Write-Host "[9/9] Registering ECS task definition..."
$SANDBOX_IMAGE = "$ECR_REGISTRY/$PREFIX-sandbox:latest"
$taskDef = '{"family":"bashforge-sandbox","networkMode":"awsvpc","requiresCompatibilities":["FARGATE"],"cpu":"256","memory":"512","executionRoleArn":"EXEC_ARN","containerDefinitions":[{"name":"bash-session","image":"SANDBOX_IMG","essential":true,"portMappings":[{"containerPort":8765,"protocol":"tcp"}],"environment":[{"name":"PORT","value":"8765"}],"logConfiguration":{"logDriver":"awslogs","options":{"awslogs-group":"/ecs/bashforge-sandbox","awslogs-region":"AWS_REGION","awslogs-stream-prefix":"ecs"}},"readonlyRootFilesystem":false,"linuxParameters":{"capabilities":{"drop":["ALL"]},"initProcessEnabled":true}}]}'
$taskDef = $taskDef.Replace("EXEC_ARN", $EXEC_ROLE_ARN).Replace("SANDBOX_IMG", $SANDBOX_IMAGE).Replace("AWS_REGION", $REGION)
$taskDef | Out-File -FilePath "$env:TEMP\taskdef.json" -Encoding utf8
aws ecs register-task-definition --cli-input-json "file://$env:TEMP\taskdef.json" --region $REGION --query "taskDefinition.taskDefinitionArn" --output text

# Attach instance profile to EC2 with key pair bashforge-cicd
Write-Host ""
Write-Host "[+] Looking up EC2 instance with key pair 'bashforge-cicd'..."
$INSTANCE_ID = (aws ec2 describe-instances --filters "Name=key-name,Values=bashforge-cicd" "Name=instance-state-name,Values=running,stopped,pending" --query "Reservations[0].Instances[0].InstanceId" --output text --region $REGION)
if ($INSTANCE_ID -and ($INSTANCE_ID -ne "None")) {
    Write-Host "  Found instance: $INSTANCE_ID"
    $ASSOC_ID = (aws ec2 describe-iam-instance-profile-associations --filters "Name=instance-id,Values=$INSTANCE_ID" --query "IamInstanceProfileAssociations[0].AssociationId" --output text --region $REGION 2>&1)
    if ($ASSOC_ID -and ($ASSOC_ID -ne "None") -and ($ASSOC_ID -notmatch "error")) {
        Write-Host "  Instance profile already attached"
    } else {
        $null = aws ec2 associate-iam-instance-profile --instance-id $INSTANCE_ID --iam-instance-profile Name=$EC2_PROFILE --region $REGION
        Write-Host "  Attached $EC2_PROFILE to $INSTANCE_ID"
    }
    $EC2_PUBLIC_IP = (aws ec2 describe-instances --instance-ids $INSTANCE_ID --query "Reservations[0].Instances[0].PublicIpAddress" --output text --region $REGION)
    Write-Host "  EC2 public IP: $EC2_PUBLIC_IP"
} else {
    Write-Host "  No EC2 found with key pair 'bashforge-cicd' — attach the profile manually after launch"
    $EC2_PUBLIC_IP = "<YOUR_EC2_PUBLIC_IP>"
}

# Summary
Write-Host ""
Write-Host "============================================================"
Write-Host " DONE. Paste these into /opt/bashforge/.env on your EC2:"
Write-Host "============================================================"
Write-Host ""
Write-Host "AWS_DEFAULT_REGION=$REGION"
Write-Host "ECS_CLUSTER=bashforge"
Write-Host "ECS_TASK_DEFINITION=bashforge-sandbox"
Write-Host "ECS_SUBNETS=$SUBNET_ARRAY"
Write-Host "ECS_SECURITY_GROUPS=[`"$SG_ID`"]"
Write-Host "ASSIGN_PUBLIC_IP=true"
Write-Host ""
Write-Host " GitHub Actions secrets:"
Write-Host "   AWS_ACCESS_KEY_ID      : bashforge-cicd IAM user key"
Write-Host "   AWS_SECRET_ACCESS_KEY  : bashforge-cicd IAM user secret"
Write-Host "   EC2_APP_HOST           : $EC2_PUBLIC_IP"
Write-Host "   EC2_APP_SSH_KEY        : contents of your bashforge-cicd.pem file"
Write-Host "============================================================"
