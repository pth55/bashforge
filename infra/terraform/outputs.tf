output "app_public_ip" {
  description = "App EC2 Elastic IP — use as EC2_APP_HOST GitHub secret"
  value       = aws_eip.app.public_ip
}

output "ecr_registry" {
  description = "ECR registry base URL"
  value       = local.ecr_registry
}

output "ecr_frontend_url" {
  value = aws_ecr_repository.repos["frontend"].repository_url
}

output "ecr_backend_url" {
  value = aws_ecr_repository.repos["backend"].repository_url
}

output "ecr_sandbox_url" {
  value = aws_ecr_repository.repos["sandbox"].repository_url
}

output "ecs_cluster" {
  value = aws_ecs_cluster.main.name
}

output "sandbox_sg_id" {
  value = aws_security_group.sandbox.id
}

output "public_subnets" {
  value = data.aws_subnets.public.ids
}

output "next_steps" {
  description = "What to do after terraform apply"
  value       = <<-EOT

    ── POST-APPLY CHECKLIST ────────────────────────────────────────

    1. Add GitHub Actions secrets:
       AWS_ACCESS_KEY_ID     = <bashforge-cicd IAM user key>
       AWS_SECRET_ACCESS_KEY = <bashforge-cicd IAM user secret>
       EC2_APP_HOST          = ${aws_eip.app.public_ip}
       EC2_APP_SSH_KEY       = <contents of bashforge-cicd.pem>

    2. Point your DNS A record for ${var.domain}
       to ${aws_eip.app.public_ip}

    3. SSH in and get SSL cert (wait ~2min for userdata to finish first):
       ssh -i bashforge-cicd.pem ubuntu@${aws_eip.app.public_ip}
       sudo certbot --nginx -d ${var.domain} --non-interactive --agree-tos -m you@email.com

    4. Push to main to trigger first image build + deploy:
       git push origin main

    ────────────────────────────────────────────────────────────────
  EOT
}
