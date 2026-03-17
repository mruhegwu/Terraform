# Deployment Automation & Operations Guide

A comprehensive guide for deploying TypeScript applications on the AWS infrastructure defined in this Terraform repository. This document covers the complete pipeline from code to production, including CI/CD automation, monitoring, and operational procedures.

---

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [Environment Overview](#environment-overview)
3. [Local Development Setup](#local-development-setup)
4. [Infrastructure Provisioning](#infrastructure-provisioning)
5. [Application Deployment Pipeline](#application-deployment-pipeline)
6. [Environment-Specific Deployments](#environment-specific-deployments)
7. [Database Migrations & Seeding](#database-migrations--seeding)
8. [Static Asset Management](#static-asset-management)
9. [SSL/TLS Certificate Management](#ssltls-certificate-management)
10. [Domain DNS Configuration](#domain-dns-configuration)
11. [Health Checks & Monitoring Setup](#health-checks--monitoring-setup)
12. [Blue-Green Deployment Strategy](#blue-green-deployment-strategy)
13. [Rollback Procedures](#rollback-procedures)
14. [Post-Deployment Smoke Tests](#post-deployment-smoke-tests)

---

## Prerequisites

### Tools Required

```bash
# Install required CLI tools
brew install awscli terraform node@18 docker

# Verify versions
aws --version          # >= 2.13.0
terraform --version    # >= 1.5.0
node --version         # >= 18.0.0
docker --version       # >= 24.0.0
```

### AWS Configuration

```bash
# Configure AWS credentials
aws configure --profile production
# AWS Access Key ID: <your-access-key>
# AWS Secret Access Key: <your-secret-key>
# Default region: us-east-1
# Default output format: json

# Configure additional environments
aws configure --profile staging
aws configure --profile development
```

### Required Permissions

The deploying IAM user/role must have the following permissions:

- `ec2:*` — EC2 instance management
- `ecs:*` — ECS cluster and service management
- `ecr:*` — Container registry access
- `s3:*` — S3 bucket management
- `cloudfront:*` — CDN distribution management
- `elasticloadbalancing:*` — Load balancer management
- `rds:*` — Database management
- `secretsmanager:*` — Secrets access
- `route53:*` — DNS management
- `acm:*` — Certificate management
- `cloudwatch:*` — Monitoring and logging
- `iam:PassRole` — Role assignment to services

---

## Environment Overview

| Environment | Purpose              | Branch     | Auto-Deploy | URL Pattern                  |
|-------------|----------------------|------------|-------------|------------------------------|
| Development | Feature testing      | `develop`  | On push     | `dev.yourdomain.com`         |
| Staging     | Pre-production QA    | `main`     | On push     | `staging.yourdomain.com`     |
| Production  | Live environment     | Git tags   | On tag `v*` | `yourdomain.com`             |

### Infrastructure Architecture

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
    └──► Application Load Balancer
              │
              ├──► ECS Cluster (App Containers)
              │         ├── TypeScript App 1 (port 3000)
              │         ├── TypeScript App 2 (port 3001)
              │         └── TypeScript App N (port 300N)
              │
              └──► EC2 Auto Scaling Group (if not using ECS)

ECS / EC2 ──► RDS PostgreSQL (Multi-AZ)
          ──► ElastiCache Redis
          ──► S3 (File Uploads)
          ──► Secrets Manager
          ──► CloudWatch Logs
```

---

## Local Development Setup

### 1. Clone and Install Dependencies

```bash
git clone https://github.com/mruhegwu/Terraform.git
cd Terraform

# Install Node.js dependencies for each TypeScript app
cd apps/app-name
npm install
```

### 2. Environment Variables

Copy the environment template:

```bash
cp .env.example .env.local
```

Required environment variables:

```env
# Application
NODE_ENV=development
PORT=3000
APP_NAME=your-app-name

# Database
DATABASE_URL=postgresql://postgres:password@localhost:5432/mydb
DATABASE_POOL_MIN=2
DATABASE_POOL_MAX=10

# Redis
REDIS_URL=redis://localhost:6379
REDIS_TTL=3600

# AWS
AWS_REGION=us-east-1
AWS_S3_BUCKET=your-app-dev-uploads
AWS_CLOUDFRONT_DOMAIN=d1234567890.cloudfront.net

# Authentication
JWT_SECRET=your-local-dev-secret-min-32-chars
JWT_EXPIRES_IN=7d

# Monitoring
LOG_LEVEL=debug
SENTRY_DSN=https://example@o123.ingest.sentry.io/456
```

### 3. Start Local Infrastructure

```bash
# Start local services (PostgreSQL, Redis) using Docker Compose
docker-compose -f docker/docker-compose.yml up -d

# Run database migrations
npm run db:migrate

# Seed development data
npm run db:seed

# Start the application
npm run dev
```

### 4. Test Against Production-Like Infrastructure

```bash
# Run Terraform plan to preview infrastructure changes
cd terraform/
terraform init
terraform workspace select staging
terraform plan -var-file="environments/staging.tfvars"
```

---

## Infrastructure Provisioning

### Terraform Workspace Setup

```bash
cd terraform/

# Initialize Terraform
terraform init -backend-config="environments/backend.conf"

# Create workspaces for each environment
terraform workspace new development
terraform workspace new staging
terraform workspace new production

# List workspaces
terraform workspace list
```

### Deploy Infrastructure

```bash
# Development environment
terraform workspace select development
terraform plan -var-file="environments/development.tfvars" -out=dev.plan
terraform apply dev.plan

# Staging environment
terraform workspace select staging
terraform plan -var-file="environments/staging.tfvars" -out=staging.plan
terraform apply staging.plan

# Production environment (requires manual approval)
terraform workspace select production
terraform plan -var-file="environments/production.tfvars" -out=prod.plan
terraform apply prod.plan
```

### Key Terraform Variables

```hcl
# environments/production.tfvars
environment          = "production"
aws_region           = "us-east-1"
vpc_cidr             = "10.0.0.0/16"
app_instance_type    = "t3.medium"
db_instance_class    = "db.t3.medium"
db_multi_az          = true
db_backup_retention  = 30
min_capacity         = 2
max_capacity         = 10
desired_capacity     = 2
domain_name          = "yourdomain.com"
certificate_arn      = "arn:aws:acm:us-east-1:123456789:certificate/abc-123"
```

---

## Application Deployment Pipeline

### Pipeline Stages

```
Code Push / Tag
     │
     ▼
1. Lint & Type Check
     │
     ▼
2. Unit Tests
     │
     ▼
3. Integration Tests
     │
     ▼
4. Build Docker Image
     │
     ▼
5. Push to ECR
     │
     ▼
6. Run DB Migrations
     │
     ▼
7. Deploy to ECS (Blue-Green)
     │
     ▼
8. Health Check Validation
     │
     ▼
9. Smoke Tests
     │
     ▼
10. CDN Cache Invalidation
     │
     ▼
11. Notify Team
```

### Building the Application

```bash
# Build TypeScript application
npm run build

# Build Docker image
docker build \
  --file docker/Dockerfile \
  --target production \
  --tag your-app:$(git rev-parse --short HEAD) \
  .

# Multi-platform build for AWS (amd64)
docker buildx build \
  --platform linux/amd64 \
  --file docker/Dockerfile \
  --target production \
  --tag your-app:$(git rev-parse --short HEAD) \
  --push \
  .
```

### Pushing to ECR

```bash
# Authenticate Docker to ECR
aws ecr get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin \
  123456789.dkr.ecr.us-east-1.amazonaws.com

# Tag image
docker tag your-app:abc1234 \
  123456789.dkr.ecr.us-east-1.amazonaws.com/your-app:abc1234

# Push to ECR
docker push 123456789.dkr.ecr.us-east-1.amazonaws.com/your-app:abc1234

# Also tag as latest
docker tag your-app:abc1234 \
  123456789.dkr.ecr.us-east-1.amazonaws.com/your-app:latest
docker push 123456789.dkr.ecr.us-east-1.amazonaws.com/your-app:latest
```

### Deploying to ECS

```bash
# Update ECS task definition with new image
aws ecs register-task-definition \
  --cli-input-json file://ecs/task-definition.json

# Deploy to ECS service (blue-green via CodeDeploy)
aws ecs update-service \
  --cluster production-cluster \
  --service your-app-service \
  --task-definition your-app:42 \
  --force-new-deployment \
  --region us-east-1
```

---

## Environment-Specific Deployments

### Development Deployment

Triggered automatically on every push to `develop` branch.

```bash
# Manual development deployment
./scripts/deploy.sh development latest
```

Configuration:
- Single ECS task (no redundancy)
- Smaller instance types (`t3.small`)
- Debug logging enabled
- No CloudFront caching
- Shared RDS instance

### Staging Deployment

Triggered automatically on every push to `main` branch.

```bash
# Manual staging deployment
./scripts/deploy.sh staging v1.2.3
```

Configuration:
- Two ECS tasks (basic redundancy)
- Medium instance types (`t3.medium`)
- Info logging
- CloudFront with short TTL (5 minutes)
- Dedicated RDS instance (single-AZ)

### Production Deployment

Triggered only on Git tag push (`v*`).

```bash
# Create and push a release tag
git tag -a v1.2.3 -m "Release v1.2.3: Feature X and bug fixes"
git push origin v1.2.3
```

Configuration:
- Minimum 2 ECS tasks, auto-scaled to 10
- Medium/large instance types (`t3.medium`/`t3.large`)
- Warning+ logging only
- CloudFront with optimized TTL
- Multi-AZ RDS with read replica
- ElastiCache Redis cluster

---

## Database Migrations & Seeding

### Running Migrations

```bash
# Run pending migrations (development)
npm run db:migrate

# Run migrations on production (via ECS task)
aws ecs run-task \
  --cluster production-cluster \
  --task-definition your-app-migrations \
  --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[subnet-xxx],securityGroups=[sg-xxx],assignPublicIp=DISABLED}" \
  --overrides '{"containerOverrides":[{"name":"app","command":["npm","run","db:migrate"]}]}'
```

### Migration Best Practices

1. **Always backwards-compatible**: New columns nullable, features flag-gated
2. **Test migrations on staging first**: Same data volume, schema, constraints
3. **Backup before migrating**: Automated snapshot taken before migration task
4. **Rollback capability**: Every `up` migration has a corresponding `down`

```typescript
// Example migration: add-user-preferences.ts
import { Knex } from 'knex';

export async function up(knex: Knex): Promise<void> {
  await knex.schema.table('users', (table) => {
    table.jsonb('preferences').nullable().defaultTo('{}');
    table.index(['id', 'preferences'], 'idx_users_preferences');
  });
}

export async function down(knex: Knex): Promise<void> {
  await knex.schema.table('users', (table) => {
    table.dropIndex(['id', 'preferences'], 'idx_users_preferences');
    table.dropColumn('preferences');
  });
}
```

### Database Seeding

```bash
# Seed development data
npm run db:seed

# Seed specific seeder
npm run db:seed -- --specific users_seeder

# Reset and re-seed (development only!)
npm run db:reset
```

---

## Static Asset Management

### S3 Bucket Setup

```bash
# Create S3 bucket for static assets
aws s3 mb s3://your-app-production-assets --region us-east-1

# Enable versioning
aws s3api put-bucket-versioning \
  --bucket your-app-production-assets \
  --versioning-configuration Status=Enabled

# Apply lifecycle policy
aws s3api put-bucket-lifecycle-configuration \
  --bucket your-app-production-assets \
  --lifecycle-configuration file://s3/lifecycle-policy.json
```

### Uploading Static Assets

```bash
# Build and upload static assets
npm run build

# Upload to S3 with cache headers
aws s3 sync dist/static/ s3://your-app-production-assets/ \
  --cache-control "public, max-age=31536000, immutable" \
  --exclude "*.html" \
  --delete

# Upload HTML files with shorter cache
aws s3 sync dist/ s3://your-app-production-assets/ \
  --cache-control "public, max-age=300" \
  --include "*.html"
```

### CloudFront Cache Invalidation

```bash
# Invalidate specific paths
aws cloudfront create-invalidation \
  --distribution-id E1234567890 \
  --paths "/index.html" "/app.js" "/app.css"

# Invalidate all (use sparingly - costs money)
aws cloudfront create-invalidation \
  --distribution-id E1234567890 \
  --paths "/*"

# Wait for invalidation to complete
aws cloudfront wait invalidation-completed \
  --distribution-id E1234567890 \
  --id INVALIDATION_ID
```

---

## SSL/TLS Certificate Management

### Requesting a Certificate via ACM

```bash
# Request certificate (must be in us-east-1 for CloudFront)
aws acm request-certificate \
  --domain-name yourdomain.com \
  --subject-alternative-names "*.yourdomain.com" \
  --validation-method DNS \
  --region us-east-1

# Get certificate ARN and DNS validation records
aws acm describe-certificate \
  --certificate-arn arn:aws:acm:us-east-1:123456789:certificate/abc-123 \
  --region us-east-1 \
  --query 'Certificate.DomainValidationOptions'
```

### Certificate Renewal

ACM certificates auto-renew 60 days before expiration. Monitor certificate status:

```bash
# Check certificate expiration
aws acm list-certificates \
  --certificate-statuses ISSUED \
  --query 'CertificateSummaryList[*].[DomainName,CertificateArn]' \
  --output table

# Set up expiration monitoring (CloudWatch alarm at 45 days)
aws cloudwatch put-metric-alarm \
  --alarm-name "SSL-Certificate-Expiry-yourdomain" \
  --alarm-description "SSL certificate expiring soon" \
  --metric-name DaysToExpiry \
  --namespace AWS/CertificateManager \
  --dimensions Name=CertificateArn,Value=arn:aws:acm:... \
  --period 86400 \
  --evaluation-periods 1 \
  --threshold 45 \
  --comparison-operator LessThanThreshold \
  --alarm-actions arn:aws:sns:us-east-1:123456789:alerts
```

---

## Domain DNS Configuration

### Route 53 Setup

```bash
# Create hosted zone (if not exists)
aws route53 create-hosted-zone \
  --name yourdomain.com \
  --caller-reference $(date +%s)

# Get hosted zone ID
HOSTED_ZONE_ID=$(aws route53 list-hosted-zones-by-name \
  --dns-name yourdomain.com \
  --query 'HostedZones[0].Id' \
  --output text | cut -d'/' -f3)

# Create A record pointing to CloudFront (alias)
aws route53 change-resource-record-sets \
  --hosted-zone-id $HOSTED_ZONE_ID \
  --change-batch file://dns/production-records.json
```

### DNS Records Template (`dns/production-records.json`)

```json
{
  "Changes": [
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "yourdomain.com",
        "Type": "A",
        "AliasTarget": {
          "HostedZoneId": "Z2FDTNDATAQYW2",
          "DNSName": "d1234567890.cloudfront.net",
          "EvaluateTargetHealth": false
        }
      }
    },
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "www.yourdomain.com",
        "Type": "CNAME",
        "TTL": 300,
        "ResourceRecords": [{"Value": "yourdomain.com"}]
      }
    },
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "api.yourdomain.com",
        "Type": "A",
        "AliasTarget": {
          "HostedZoneId": "Z35SXDOTRQ7X7K",
          "DNSName": "your-alb-123456.us-east-1.elb.amazonaws.com",
          "EvaluateTargetHealth": true
        }
      }
    }
  ]
}
```

---

## Health Checks & Monitoring Setup

### Application Health Check Endpoint

Each TypeScript application must implement a `/health` endpoint:

```typescript
// src/routes/health.ts
import { Router, Request, Response } from 'express';
import { db } from '../database';
import { redis } from '../cache';

const router = Router();

router.get('/health', async (req: Request, res: Response) => {
  const checks: Record<string, string> = {};
  let healthy = true;

  // Database check
  try {
    await db.raw('SELECT 1');
    checks.database = 'ok';
  } catch (err) {
    checks.database = 'error';
    healthy = false;
  }

  // Redis check
  try {
    await redis.ping();
    checks.redis = 'ok';
  } catch (err) {
    checks.redis = 'error';
    healthy = false;
  }

  res.status(healthy ? 200 : 503).json({
    status: healthy ? 'healthy' : 'unhealthy',
    timestamp: new Date().toISOString(),
    version: process.env.APP_VERSION,
    checks,
  });
});

export default router;
```

### ALB Health Check Configuration

```hcl
# Terraform: ALB target group health check
resource "aws_lb_target_group" "app" {
  name     = "${var.app_name}-tg"
  port     = 3000
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  health_check {
    enabled             = true
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 10
    interval            = 30
    path                = "/health"
    matcher             = "200"
  }
}
```

### CloudWatch Alarms

```bash
# CPU utilization alarm
aws cloudwatch put-metric-alarm \
  --alarm-name "ECS-High-CPU-your-app" \
  --metric-name CPUUtilization \
  --namespace AWS/ECS \
  --dimensions Name=ServiceName,Value=your-app-service Name=ClusterName,Value=production-cluster \
  --period 300 \
  --evaluation-periods 2 \
  --threshold 80 \
  --comparison-operator GreaterThanThreshold \
  --alarm-actions arn:aws:sns:us-east-1:123456789:alerts

# ALB 5XX error rate alarm
aws cloudwatch put-metric-alarm \
  --alarm-name "ALB-5XX-Rate-your-app" \
  --metric-name HTTPCode_Target_5XX_Count \
  --namespace AWS/ApplicationELB \
  --dimensions Name=LoadBalancer,Value=app/your-alb/abc123 \
  --period 60 \
  --evaluation-periods 3 \
  --threshold 10 \
  --comparison-operator GreaterThanThreshold \
  --alarm-actions arn:aws:sns:us-east-1:123456789:alerts
```

---

## Blue-Green Deployment Strategy

### Overview

Blue-green deployment eliminates downtime by maintaining two identical production environments.

```
Traffic (100% → Blue)
        │
        ▼
  Load Balancer
        │
        ├──► Blue (Current Production) ✅
        │
        └──► Green (New Version) ⏳ (being deployed)

After validation:

Traffic (100% → Green)
        │
        ▼
  Load Balancer
        │
        ├──► Blue (Previous Version) 🔵 (on standby for rollback)
        │
        └──► Green (New Production) ✅
```

### Deployment Steps

```bash
# 1. Deploy new version to Green environment
./scripts/deploy-green.sh v1.2.3

# 2. Run health checks on Green
./scripts/health-check.sh green

# 3. Run smoke tests against Green
npm run test:smoke -- --env green

# 4. Shift 10% traffic to Green (canary)
./scripts/shift-traffic.sh 10 green

# 5. Monitor for 5 minutes
sleep 300

# 6. If healthy, shift 100% traffic to Green
./scripts/shift-traffic.sh 100 green

# 7. Keep Blue running for 30 minutes (rollback window)
sleep 1800

# 8. Decommission Blue
./scripts/decommission-blue.sh
```

### Traffic Shifting Script

```bash
#!/bin/bash
# scripts/shift-traffic.sh
PERCENTAGE=$1
TARGET=$2

aws elbv2 modify-listener \
  --listener-arn $ALB_LISTENER_ARN \
  --default-actions \
  "Type=forward,ForwardConfig={TargetGroups=[{TargetGroupArn=$BLUE_TG_ARN,Weight=$((100-PERCENTAGE))},{TargetGroupArn=$GREEN_TG_ARN,Weight=$PERCENTAGE}]}"
```

---

## Rollback Procedures

### Automated Rollback

The CI/CD pipeline automatically rolls back if:
- Health checks fail after deployment
- Smoke tests fail
- Error rate exceeds 5% within 10 minutes
- Response time exceeds 3 seconds P99

### Manual Rollback

```bash
# Quick rollback to previous ECS task definition
aws ecs update-service \
  --cluster production-cluster \
  --service your-app-service \
  --task-definition your-app:41 \  # previous revision
  --force-new-deployment

# Rollback via deployment script
./scripts/rollback.sh production v1.2.2

# Database rollback (if migration was run)
npm run db:migrate:rollback -- --to 20240101000000
```

### Rollback Decision Checklist

- [ ] Identify the problematic deployment (tag/commit)
- [ ] Confirm rollback target (previous stable tag)
- [ ] Check if database migrations need rollback
- [ ] Notify team in incident channel
- [ ] Execute rollback
- [ ] Verify rollback health checks pass
- [ ] Update status page
- [ ] Conduct post-mortem

---

## Post-Deployment Smoke Tests

```bash
# Run smoke test suite
npm run test:smoke -- --env production

# Individual smoke test checks
curl -f https://yourdomain.com/health
curl -f https://api.yourdomain.com/health
curl -f https://yourdomain.com/ | grep -q "Expected Content"
```

### Smoke Test Example

```typescript
// tests/smoke/production.smoke.test.ts
import axios from 'axios';

const BASE_URL = process.env.SMOKE_TEST_URL || 'https://yourdomain.com';

describe('Production Smoke Tests', () => {
  test('Health endpoint returns 200', async () => {
    const response = await axios.get(`${BASE_URL}/health`);
    expect(response.status).toBe(200);
    expect(response.data.status).toBe('healthy');
  });

  test('Homepage loads within 2 seconds', async () => {
    const start = Date.now();
    await axios.get(BASE_URL);
    expect(Date.now() - start).toBeLessThan(2000);
  });

  test('API authentication endpoint responds', async () => {
    const response = await axios.post(`${BASE_URL}/api/auth/ping`);
    expect(response.status).toBeLessThan(500);
  });
});
```

---

## Related Documentation

- [Monitoring & Observability Guide](./MONITORING.md)
- [Disaster Recovery Procedures](./DR_PROCEDURES.md)
- [Operations Runbook](./OPERATIONS.md)
- [Cost Optimization Guide](./COST_OPTIMIZATION.md)
- [Security Hardening Guide](./SECURITY.md)
- [Troubleshooting Guide](./TROUBLESHOOTING.md)
- [Scaling Strategy](./SCALING.md)
