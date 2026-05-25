variable "region" {
  description = "AWS region for all resources"
  type        = string
  default     = "ap-south-1"
}

variable "key_name" {
  description = "EC2 key pair name"
  type        = string
  default     = "bashforge-cicd"
}

variable "instance_type" {
  description = "App EC2 instance type"
  type        = string
  default     = "t3.small"
}

variable "domain" {
  description = "Production domain (e.g. bashforge.yourdomain.com)"
  type        = string
}

variable "session_ttl_seconds" {
  description = "Session TTL in seconds"
  type        = number
  default     = 3600
}

variable "max_concurrent_sessions" {
  description = "Max concurrent ECS sandbox sessions"
  type        = number
  default     = 20
}
