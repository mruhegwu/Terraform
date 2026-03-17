# Terraform Infrastructure & Deployment Automation

AWS infrastructure as code (Terraform) with complete deployment automation, monitoring, and operational guides for TypeScript applications.

---

## 📚 Documentation Index

| Document | Description |
|----------|-------------|
| [DEPLOYMENT_GUIDE.md](./DEPLOYMENT_GUIDE.md) | End-to-end deployment pipeline: CI/CD, blue-green deployments, database migrations, SSL/DNS setup |
| [MONITORING.md](./MONITORING.md) | CloudWatch dashboards, log aggregation, alerting, APM, cost monitoring |
| [DR_PROCEDURES.md](./DR_PROCEDURES.md) | Backup strategy, cross-region replication, RTO/RPO, disaster recovery testing |
| [OPERATIONS.md](./OPERATIONS.md) | Daily operations checklist, incident response, on-call, security patching |
| [COST_OPTIMIZATION.md](./COST_OPTIMIZATION.md) | Reserved instances, Spot instances, storage optimization, cost alerts |
| [SECURITY.md](./SECURITY.md) | Network hardening, WAF, secrets management, IAM, encryption, compliance |
| [TROUBLESHOOTING.md](./TROUBLESHOOTING.md) | Common issues and solutions: deployments, database, performance, memory leaks |
| [SCALING.md](./SCALING.md) | Auto-scaling, database read replicas, caching, CDN, rate limiting, load balancing |

---

## 🏗️ Infrastructure Architecture

```
Internet
    │
    ▼
Route 53 (DNS)
    │
    ▼
CloudFront (CDN + SSL Termination)
    │
    ├──► S3 (Static Assets)
    │
    └──► Application Load Balancer (ALB)
              │
              └──► ECS Fargate (TypeScript Apps, Auto-scaled 2-20 tasks)
                        │
                        ├──► RDS PostgreSQL (Multi-AZ)
                        ├──► ElastiCache Redis
                        ├──► S3 (File Uploads)
                        └──► Secrets Manager
```

---

## 🚀 Quick Start

### Prerequisites

```bash
# Install required tools
brew install awscli terraform node@18 docker

# Configure AWS
aws configure --profile production
```

### Local Development

```bash
# Clone the repository
git clone https://github.com/mruhegwu/Terraform.git
cd Terraform

# Copy environment variables
cp .env.example .env.local

# Start local infrastructure (PostgreSQL, Redis, LocalStack)
docker-compose -f docker/docker-compose.yml up -d

# Run database migrations
npm run db:migrate

# Start the application
npm run dev
```

### Deploy Infrastructure

```bash
cd terraform/

# Initialize
terraform init

# Select environment
terraform workspace select production

# Preview changes
terraform plan -var-file="environments/production.tfvars"

# Apply
terraform apply -var-file="environments/production.tfvars"
```

---

## 🔄 CI/CD Pipelines

| Workflow | Trigger | Target |
|----------|---------|--------|
| [ci.yml](.github/workflows/ci.yml) | PR / push to any branch | Lint, test, security scan |
| [staging.yml](.github/workflows/staging.yml) | Push to `main` | Auto-deploy to staging |
| [deploy.yml](.github/workflows/deploy.yml) | Push tag `v*` | Blue-green deploy to production |

### Release Process

```bash
# Create and push a release tag
git tag -a v1.2.3 -m "Release v1.2.3: Description of changes"
git push origin v1.2.3

# This automatically:
# 1. Runs full test suite
# 2. Builds Docker image and pushes to ECR
# 3. Creates RDS snapshot (safety backup)
# 4. Runs database migrations
# 5. Blue-green deploys to production
# 6. Runs smoke tests
# 7. Invalidates CloudFront cache
# 8. Notifies team via Slack
# 9. Auto-rolls back if smoke tests fail
```

---

## 🐳 Docker

```bash
# Build production image
docker build -f docker/Dockerfile --target production -t your-app:latest .

# Build development image with hot-reload
docker build -f docker/Dockerfile --target development -t your-app:dev .

# Run locally
docker-compose -f docker/docker-compose.yml up
```

---

## 📊 Environments

| Environment | Branch | Trigger | URL |
|-------------|--------|---------|-----|
| Development | `develop` | Push | `dev.yourdomain.com` |
| Staging | `main` | Push | `staging.yourdomain.com` |
| Production | Git tag `v*` | Tag push | `yourdomain.com` |

---

## 🛡️ Security

- All infrastructure in private subnets (no public IP on ECS tasks/RDS)
- WAF with SQL injection protection and rate limiting
- Secrets stored in AWS Secrets Manager (never in code or env files)
- Container runs as non-root user
- Encryption at rest (RDS, S3, EBS) and in transit (TLS everywhere)
- MFA required for all IAM users with production access
- Automated vulnerability scanning (Trivy, npm audit) in CI

See [SECURITY.md](./SECURITY.md) for complete security guide.

---

## 📈 Monitoring

- CloudWatch dashboards for CPU, memory, error rates, latency
- Structured JSON logging to CloudWatch Logs
- Sentry for error tracking and performance monitoring
- AWS X-Ray for distributed tracing
- PagerDuty integration for on-call alerting
- Cost budgets with anomaly detection

See [MONITORING.md](./MONITORING.md) for complete monitoring guide.

---

## 💰 Cost Optimization

- Reserved Instances for predictable production workloads
- Spot Instances for CI/CD and non-critical services
- VPC Endpoints to eliminate NAT Gateway costs for S3/DynamoDB
- S3 Intelligent-Tiering for unknown access patterns
- Scheduled scaling to reduce off-hours capacity
- Monthly cost review process

See [COST_OPTIMIZATION.md](./COST_OPTIMIZATION.md) for complete guide.

---

## Required GitHub Actions Secrets

| Secret | Description |
|--------|-------------|
| `AWS_ACCESS_KEY_ID` | AWS IAM access key for deployments |
| `AWS_SECRET_ACCESS_KEY` | AWS IAM secret key for deployments |
| `PRODUCTION_URL` | Production application URL for smoke tests |
| `STAGING_URL` | Staging application URL for smoke tests |
| `CLOUDFRONT_DISTRIBUTION_ID` | CloudFront distribution for cache invalidation |
| `PRIVATE_SUBNET_IDS` | Comma-separated private subnet IDs |
| `APP_SECURITY_GROUP_ID` | Security group ID for ECS tasks |
| `SLACK_WEBHOOK_URL` | Slack webhook for deployment notifications |