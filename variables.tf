# ── General ─────────────────────────────────────────────────────────────────

variable "project_name" {
  description = "Name of the project, used as a prefix for all resources."
  type        = string
  default     = "myapp"
}

variable "environment" {
  description = "Deployment environment (e.g. dev, staging, prod)."
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "Environment must be one of: dev, staging, prod."
  }
}

variable "aws_region" {
  description = "AWS region where resources will be created."
  type        = string
  default     = "us-east-1"
}

# ── Networking ───────────────────────────────────────────────────────────────

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "List of CIDR blocks for public subnets (one per AZ)."
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "private_subnet_cidrs" {
  description = "List of CIDR blocks for private subnets (one per AZ)."
  type        = list(string)
  default     = ["10.0.11.0/24", "10.0.12.0/24"]
}

variable "availability_zones" {
  description = "List of Availability Zones to use. Must match the number of public/private subnet CIDRs."
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]
}

# ── Compute ──────────────────────────────────────────────────────────────────

variable "instance_type" {
  description = "EC2 instance type for the Auto Scaling Group."
  type        = string
  default     = "t3.micro"
}

variable "ami_id" {
  description = "AMI ID to use for EC2 instances. Defaults to the latest Amazon Linux 2023 AMI."
  type        = string
  default     = ""
}

variable "min_size" {
  description = "Minimum number of EC2 instances in the Auto Scaling Group."
  type        = number
  default     = 1
}

variable "max_size" {
  description = "Maximum number of EC2 instances in the Auto Scaling Group."
  type        = number
  default     = 4
}

variable "desired_capacity" {
  description = "Desired number of EC2 instances in the Auto Scaling Group."
  type        = number
  default     = 2
}

variable "key_name" {
  description = "Name of an existing EC2 key pair to associate with instances. Leave empty to create instances without a key pair."
  type        = string
  default     = ""
}
