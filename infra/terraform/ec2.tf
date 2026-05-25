data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_instance" "app" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  key_name               = var.key_name
  iam_instance_profile   = aws_iam_instance_profile.ec2.name
  subnet_id              = data.aws_subnets.public.ids[0]
  vpc_security_group_ids = [aws_security_group.app.id]

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
  }

  user_data_replace_on_change = true

  user_data = templatefile("${path.module}/templates/userdata.sh.tpl", {
    domain       = var.domain
    region       = var.region
    ecr_registry = local.ecr_registry
    ecs_subnets  = jsonencode(data.aws_subnets.public.ids)
    sandbox_sg   = aws_security_group.sandbox.id
    session_ttl  = tostring(var.session_ttl_seconds)
    max_sessions = tostring(var.max_concurrent_sessions)
  })

  tags = { Name = "bashforge-app" }
}

resource "aws_eip" "app" {
  instance = aws_instance.app.id
  domain   = "vpc"

  tags = { Name = "bashforge-app-eip" }
}
