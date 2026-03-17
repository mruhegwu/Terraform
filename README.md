# Terraform — AWS Infrastructure as Code

This repository contains a production-ready Terraform configuration that provisions a highly-available, auto-scaling web application environment on AWS.

## Architecture

```
Internet
   │
   ▼
Application Load Balancer  (public subnets, multi-AZ)
   │
   ▼
Auto Scaling Group          (private subnets, multi-AZ)
├── EC2 instance (AZ-a)
└── EC2 instance (AZ-b)
   │
   ▼
NAT Gateways               (public subnets, one per AZ)
```

### Resources created

| Resource | Description |
|---|---|
| VPC | Isolated network with public & private subnets across 2 AZs |
| Internet Gateway | Allows public subnets to reach the internet |
| NAT Gateways | Allow private-subnet instances to reach the internet (one per AZ for HA) |
| Route Tables | Public and per-AZ private routing |
| Security Groups | ALB → EC2 traffic, HTTPS/HTTP ingress |
| Application Load Balancer | Internet-facing ALB with HTTP listener |
| Launch Template | Versioned instance configuration (Amazon Linux 2023, Apache) |
| Auto Scaling Group | CPU-based target-tracking scaling policy |
| IAM Role / Instance Profile | Grants SSM Session Manager access to instances |

## Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/install) ≥ 1.3.0
- AWS credentials configured (e.g. `aws configure`, environment variables, or an IAM role)
- An AWS account with sufficient permissions to create the resources listed above

## Quick Start

```bash
# 1. Clone the repository
git clone https://github.com/mruhegwu/Terraform.git
cd Terraform

# 2. Create your variable file
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your preferred values

# 3. Initialise Terraform
terraform init

# 4. Review the execution plan
terraform plan

# 5. Apply the configuration
terraform apply
```

After `apply` completes, the ALB DNS name is printed as an output:

```
alb_dns_name = "myapp-dev-alb-XXXXXXXXXXXX.us-east-1.elb.amazonaws.com"
```

Open that URL in a browser to reach the application.

## Variables

| Name | Description | Default |
|---|---|---|
| `project_name` | Prefix used for all resource names | `"myapp"` |
| `environment` | Deployment environment (`dev`, `staging`, `prod`) | `"dev"` |
| `aws_region` | AWS region | `"us-east-1"` |
| `vpc_cidr` | VPC CIDR block | `"10.0.0.0/16"` |
| `public_subnet_cidrs` | CIDR blocks for public subnets | `["10.0.1.0/24", "10.0.2.0/24"]` |
| `private_subnet_cidrs` | CIDR blocks for private subnets | `["10.0.11.0/24", "10.0.12.0/24"]` |
| `availability_zones` | AZs to deploy into | `["us-east-1a", "us-east-1b"]` |
| `instance_type` | EC2 instance type | `"t3.micro"` |
| `ami_id` | AMI ID (leave empty for latest Amazon Linux 2023) | `""` |
| `min_size` | ASG minimum instance count | `1` |
| `max_size` | ASG maximum instance count | `4` |
| `desired_capacity` | ASG desired instance count | `2` |
| `key_name` | EC2 key pair name for SSH (leave empty to skip) | `""` |

## Outputs

| Name | Description |
|---|---|
| `vpc_id` | ID of the created VPC |
| `public_subnet_ids` | IDs of the public subnets |
| `private_subnet_ids` | IDs of the private subnets |
| `alb_dns_name` | DNS name of the Application Load Balancer |
| `alb_arn` | ARN of the Application Load Balancer |
| `asg_name` | Name of the Auto Scaling Group |
| `ec2_iam_role_arn` | ARN of the EC2 IAM role |

## Remote State (optional)

Uncomment the `backend "s3"` block in `provider.tf` and replace the placeholder values with your S3 bucket and DynamoDB table names to store Terraform state remotely.

## Teardown

```bash
terraform destroy
```

## File Structure

```
.
├── provider.tf              # AWS provider & optional S3 backend
├── variables.tf             # Input variable declarations
├── main.tf                  # VPC, subnets, IGW, NAT GWs, route tables
├── security_groups.tf       # Security groups for ALB and EC2
├── ec2.tf                   # IAM role, launch template, ASG, scaling policy
├── load_balancer.tf         # ALB, target group, listener
├── outputs.tf               # Output values
├── terraform.tfvars.example # Example variable values (copy to terraform.tfvars)
└── .gitignore               # Excludes state files, secrets, and lock files
```
