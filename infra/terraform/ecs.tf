resource "aws_ecs_cluster" "main" {
  name = "bashforge"

  setting {
    name  = "containerInsights"
    value = "disabled"
  }

  tags = { Name = "bashforge" }
}

resource "aws_ecs_cluster_capacity_providers" "main" {
  cluster_name       = aws_ecs_cluster.main.name
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]
}

resource "aws_ecs_task_definition" "sandbox" {
  family                   = "bashforge-sandbox"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.ecs_execution.arn

  container_definitions = jsonencode([{
    name      = "bash-session"
    image     = "${aws_ecr_repository.repos["sandbox"].repository_url}:latest"
    essential = true

    portMappings = [{
      containerPort = 8765
      protocol      = "tcp"
    }]

    environment = [
      { name = "PORT", value = "8765" }
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.sandbox.name
        "awslogs-region"        = var.region
        "awslogs-stream-prefix" = "ecs"
      }
    }

    readonlyRootFilesystem = false

    linuxParameters = {
      capabilities       = { drop = ["ALL"] }
      initProcessEnabled = true
    }
  }])

  tags = { Name = "bashforge-sandbox" }
}
