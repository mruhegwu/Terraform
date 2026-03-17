# Security Hardening Guide

Security best practices, hardening procedures, and compliance guidelines for the AWS infrastructure and TypeScript applications.

---

## Table of Contents

1. [Network Security](#network-security)
2. [Application Security](#application-security)
3. [Dependency Vulnerability Scanning](#dependency-vulnerability-scanning)
4. [Secrets Management](#secrets-management)
5. [IAM Access Control](#iam-access-control)
6. [Encryption](#encryption)
7. [Compliance Checklist](#compliance-checklist)
8. [Security Incident Response](#security-incident-response)

---

## Network Security

### VPC Security Architecture

```hcl
# terraform/modules/vpc/security.tf

# Public subnet: Only ALB
resource "aws_subnet" "public" {
  count             = length(var.availability_zones)
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index)
  availability_zone = var.availability_zones[count.index]

  map_public_ip_on_launch = false  # Never auto-assign public IPs
}

# Private subnet: ECS tasks, RDS, ElastiCache
resource "aws_subnet" "private" {
  count             = length(var.availability_zones)
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index + 10)
  availability_zone = var.availability_zones[count.index]
}

# Database subnet: RDS only (no internet access, no NAT)
resource "aws_subnet" "database" {
  count             = length(var.availability_zones)
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index + 20)
  availability_zone = var.availability_zones[count.index]
}
```

### Security Groups

```hcl
# ALB Security Group: Only accept HTTPS from internet
resource "aws_security_group" "alb" {
  name   = "${var.app_name}-alb-sg"
  vpc_id = aws_vpc.main.id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTPS from internet"
  }

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTP (redirect to HTTPS)"
  }

  egress {
    from_port       = 3000
    to_port         = 3000
    protocol        = "tcp"
    security_groups = [aws_security_group.app.id]
    description     = "Forward to app"
  }
}

# App Security Group: Only accept traffic from ALB
resource "aws_security_group" "app" {
  name   = "${var.app_name}-app-sg"
  vpc_id = aws_vpc.main.id

  ingress {
    from_port       = 3000
    to_port         = 3000
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
    description     = "From ALB only"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound (restrict further if possible)"
  }
}

# RDS Security Group: Only accept from app layer
resource "aws_security_group" "database" {
  name   = "${var.app_name}-db-sg"
  vpc_id = aws_vpc.main.id

  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.app.id]
    description     = "PostgreSQL from app only"
  }
}
```

### AWS WAF Configuration

```hcl
resource "aws_wafv2_web_acl" "app" {
  name  = "${var.app_name}-waf"
  scope = "REGIONAL"

  default_action {
    allow {}
  }

  # AWS Managed Core Rule Set
  rule {
    name     = "AWSManagedRulesCommonRuleSet"
    priority = 1
    override_action { none {} }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "CommonRuleSetMetric"
      sampled_requests_enabled   = true
    }
  }

  # Rate limiting: 1000 requests per 5 minutes per IP
  rule {
    name     = "RateLimitRule"
    priority = 2
    action { block {} }

    statement {
      rate_based_statement {
        limit              = 1000
        aggregate_key_type = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "RateLimitMetric"
      sampled_requests_enabled   = true
    }
  }

  # SQL Injection protection
  rule {
    name     = "AWSManagedRulesSQLiRuleSet"
    priority = 3
    override_action { none {} }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesSQLiRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "SQLiMetric"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "WAFMetric"
    sampled_requests_enabled   = true
  }
}
```

---

## Application Security

### Security Headers

```typescript
// src/middleware/security.ts
import helmet from 'helmet';
import { Express } from 'express';

export function applySecurityMiddleware(app: Express): void {
  // Content Security Policy
  app.use(
    helmet({
      contentSecurityPolicy: {
        directives: {
          defaultSrc: ["'self'"],
          scriptSrc: ["'self'", "'unsafe-inline'"],  // Tighten after audit
          styleSrc: ["'self'", "'unsafe-inline'", 'https://fonts.googleapis.com'],
          fontSrc: ["'self'", 'https://fonts.gstatic.com'],
          imgSrc: ["'self'", 'data:', 'https:'],
          connectSrc: ["'self'", process.env.API_URL!],
          frameAncestors: ["'none'"],
          upgradeInsecureRequests: [],
        },
      },
      // Prevent clickjacking
      frameguard: { action: 'deny' },
      // Prevent MIME type sniffing
      noSniff: true,
      // Force HTTPS
      hsts: {
        maxAge: 31536000,
        includeSubDomains: true,
        preload: true,
      },
      // Hide X-Powered-By header
      hidePoweredBy: true,
      // XSS protection
      xssFilter: true,
    })
  );

  // CORS configuration
  app.use((req, res, next) => {
    const allowedOrigins = (process.env.ALLOWED_ORIGINS || '').split(',');
    const origin = req.headers.origin;

    if (origin && allowedOrigins.includes(origin)) {
      res.setHeader('Access-Control-Allow-Origin', origin);
      res.setHeader('Access-Control-Allow-Methods', 'GET, POST, PUT, DELETE, OPTIONS');
      res.setHeader('Access-Control-Allow-Headers', 'Content-Type, Authorization');
      res.setHeader('Access-Control-Max-Age', '86400');
    }

    if (req.method === 'OPTIONS') {
      res.sendStatus(204);
      return;
    }

    next();
  });
}
```

### Input Validation

```typescript
// src/middleware/validation.ts
import { z } from 'zod';
import { Request, Response, NextFunction } from 'express';

// User creation schema
export const createUserSchema = z.object({
  body: z.object({
    email: z.string().email().max(255),
    name: z.string().min(1).max(100).regex(/^[a-zA-Z\s'-]+$/),
    password: z
      .string()
      .min(12)
      .regex(/^(?=.*[a-z])(?=.*[A-Z])(?=.*\d)(?=.*[@$!%*?&])/,
        'Password must contain uppercase, lowercase, number, and special character'),
  }),
});

export function validate(schema: z.ZodObject<any>) {
  return (req: Request, res: Response, next: NextFunction): void => {
    const result = schema.safeParse({ body: req.body, query: req.query, params: req.params });

    if (!result.success) {
      res.status(400).json({
        error: 'Validation failed',
        details: result.error.issues.map(i => ({ field: i.path.join('.'), message: i.message })),
      });
      return;
    }

    next();
  };
}
```

### SQL Injection Prevention

```typescript
// Always use parameterized queries
// ✅ Safe - parameterized
const user = await db('users').where({ email: req.body.email }).first();

// ✅ Safe - raw with bindings
const results = await db.raw(
  'SELECT * FROM users WHERE email = ? AND active = ?',
  [req.body.email, true]
);

// ❌ NEVER DO THIS - vulnerable to SQL injection
const user = await db.raw(`SELECT * FROM users WHERE email = '${req.body.email}'`);
```

### Rate Limiting

```typescript
// src/middleware/rateLimiter.ts
import rateLimit from 'express-rate-limit';
import RedisStore from 'rate-limit-redis';
import { redis } from '../cache';

// General API rate limit: 100 req/min
export const apiRateLimit = rateLimit({
  windowMs: 60 * 1000,
  max: 100,
  standardHeaders: true,
  legacyHeaders: false,
  store: new RedisStore({
    client: redis,
    prefix: 'rl:api:',
  }),
  message: { error: 'Too many requests, please try again later' },
});

// Auth endpoints: 5 attempts per 15 minutes
export const authRateLimit = rateLimit({
  windowMs: 15 * 60 * 1000,
  max: 5,
  store: new RedisStore({
    client: redis,
    prefix: 'rl:auth:',
  }),
  message: { error: 'Too many authentication attempts' },
  skipSuccessfulRequests: true,
});
```

---

## Dependency Vulnerability Scanning

### GitHub Actions Security Scanning

```yaml
# .github/workflows/security.yml
name: Security Scanning

on:
  push:
    branches: [main, develop]
  pull_request:
  schedule:
    - cron: '0 6 * * 1'  # Weekly Monday 6 AM

jobs:
  dependency-audit:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Setup Node.js
        uses: actions/setup-node@v4
        with:
          node-version: '18'

      - name: Install dependencies
        run: npm ci

      - name: Run npm audit
        run: npm audit --audit-level=high

      - name: Run Snyk vulnerability scan
        uses: snyk/actions/node@master
        env:
          SNYK_TOKEN: ${{ secrets.SNYK_TOKEN }}
        with:
          args: --severity-threshold=high

  container-scan:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Build Docker image
        run: docker build -f docker/Dockerfile -t app:scan .

      - name: Run Trivy container scan
        uses: aquasecurity/trivy-action@master
        with:
          image-ref: 'app:scan'
          format: 'sarif'
          output: 'trivy-results.sarif'
          severity: 'CRITICAL,HIGH'
          exit-code: '1'

      - name: Upload Trivy results to GitHub Security
        uses: github/codeql-action/upload-sarif@v3
        with:
          sarif_file: trivy-results.sarif

  sast:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Initialize CodeQL
        uses: github/codeql-action/init@v3
        with:
          languages: typescript

      - name: Autobuild
        uses: github/codeql-action/autobuild@v3

      - name: Perform CodeQL Analysis
        uses: github/codeql-action/analyze@v3
```

### Dependabot Configuration

```yaml
# .github/dependabot.yml
version: 2
updates:
  - package-ecosystem: npm
    directory: "/"
    schedule:
      interval: weekly
      day: monday
      time: "06:00"
    assignees:
      - your-github-username
    open-pull-requests-limit: 10
    groups:
      dev-dependencies:
        dependency-type: development
      production-dependencies:
        dependency-type: production
    ignore:
      - dependency-name: "*"
        update-types: ["version-update:semver-major"]

  - package-ecosystem: github-actions
    directory: "/"
    schedule:
      interval: monthly
```

---

## Secrets Management

### AWS Secrets Manager

```bash
# Store application secret
aws secretsmanager create-secret \
  --name "production/app/database-url" \
  --secret-string "postgresql://user:password@host:5432/db" \
  --tags Key=Environment,Value=production Key=Application,Value=your-app

# Rotate secret (triggers Lambda rotation function)
aws secretsmanager rotate-secret \
  --secret-id "production/app/database-url" \
  --rotation-rules AutomaticallyAfterDays=90

# List all secrets
aws secretsmanager list-secrets \
  --query 'SecretList[*].[Name,LastRotatedDate]' \
  --output table
```

### Accessing Secrets in TypeScript

```typescript
// src/config/secrets.ts
import { SecretsManagerClient, GetSecretValueCommand } from '@aws-sdk/client-secrets-manager';

const client = new SecretsManagerClient({ region: process.env.AWS_REGION });

const secretCache = new Map<string, { value: string; expiry: number }>();

export async function getSecret(secretId: string): Promise<string> {
  // Cache secrets for 5 minutes
  const cached = secretCache.get(secretId);
  if (cached && cached.expiry > Date.now()) {
    return cached.value;
  }

  const response = await client.send(
    new GetSecretValueCommand({ SecretId: secretId })
  );

  const value = response.SecretString!;
  secretCache.set(secretId, { value, expiry: Date.now() + 5 * 60 * 1000 });

  return value;
}

// Usage
const dbUrl = await getSecret('production/app/database-url');
```

### Environment Variable Security

```bash
# Never commit .env files
echo ".env" >> .gitignore
echo ".env.local" >> .gitignore
echo ".env.production" >> .gitignore

# Use pre-commit hook to prevent secrets from being committed
cat > .git/hooks/pre-commit << 'EOF'
#!/bin/sh
# Detect potential secrets in staged files
if git diff --staged --name-only | xargs grep -E \
  "(AWS_SECRET|password=|api_key=|token=|secret=)" \
  --include="*.{ts,js,json,yaml,yml,env}" 2>/dev/null; then
  echo "ERROR: Potential secrets detected in staged files"
  exit 1
fi
EOF
chmod +x .git/hooks/pre-commit
```

---

## IAM Access Control

### Least Privilege Principles

```hcl
# ECS Task Role - only permissions the app needs
resource "aws_iam_role" "ecs_task" {
  name = "${var.app_name}-ecs-task-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "ecs_task" {
  name = "${var.app_name}-ecs-task-policy"
  role = aws_iam_role.ecs_task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # Secrets Manager - only specific secrets
      {
        Effect = "Allow"
        Action = ["secretsmanager:GetSecretValue"]
        Resource = [
          "arn:aws:secretsmanager:${var.aws_region}:${data.aws_caller_identity.current.account_id}:secret:${var.environment}/app/*"
        ]
      },
      # S3 - only specific bucket and operations
      {
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = ["${aws_s3_bucket.uploads.arn}/*"]
      },
      # CloudWatch Logs - write only
      {
        Effect = "Allow"
        Action = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = ["${aws_cloudwatch_log_group.app.arn}:*"]
      }
    ]
  })
}
```

### MFA Enforcement

```hcl
# IAM policy requiring MFA for sensitive operations
resource "aws_iam_policy" "require_mfa" {
  name = "RequireMFA"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "DenyWithoutMFA"
        Effect = "Deny"
        NotAction = [
          "iam:CreateVirtualMFADevice",
          "iam:EnableMFADevice",
          "iam:GetUser",
          "iam:ListMFADevices",
          "sts:GetSessionToken"
        ]
        Resource = "*"
        Condition = {
          BoolIfExists = {
            "aws:MultiFactorAuthPresent" = "false"
          }
        }
      }
    ]
  })
}
```

---

## Encryption

### Encryption at Rest

```hcl
# RDS encryption
resource "aws_db_instance" "production" {
  storage_encrypted = true
  kms_key_id        = aws_kms_key.rds.arn
}

# S3 encryption
resource "aws_s3_bucket_server_side_encryption_configuration" "assets" {
  bucket = aws_s3_bucket.assets.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.s3.arn
    }
    bucket_key_enabled = true  # Reduces KMS costs
  }
}

# EBS encryption (default for all new volumes)
resource "aws_ebs_encryption_by_default" "enabled" {
  enabled = true
}

# ElastiCache encryption
resource "aws_elasticache_replication_group" "redis" {
  at_rest_encryption_enabled = true
  transit_encryption_enabled = true
  auth_token                 = var.redis_auth_token
}
```

### Encryption in Transit

```typescript
// Enforce TLS for all external connections
const dbConfig = {
  connectionString: process.env.DATABASE_URL,
  ssl: {
    require: true,
    rejectUnauthorized: process.env.NODE_ENV === 'production',
  },
};

const redisConfig = {
  url: process.env.REDIS_URL,
  tls: process.env.NODE_ENV === 'production' ? {} : undefined,
};
```

---

## Compliance Checklist

### GDPR Compliance

- [ ] Privacy policy published and accessible
- [ ] Cookie consent banner implemented
- [ ] User data export endpoint (`GET /api/users/me/data`)
- [ ] User data deletion endpoint (`DELETE /api/users/me`)
- [ ] Data processing records maintained
- [ ] DPA agreements with all data processors (AWS, etc.)
- [ ] Breach notification procedure documented (72-hour rule)
- [ ] Data minimization: only collect what is necessary

### SOC 2 Type II Preparation

**Security (CC6)**
- [ ] All production access requires MFA
- [ ] Security group rules reviewed quarterly
- [ ] Penetration testing annually
- [ ] Vulnerability scanning automated

**Availability (A1)**
- [ ] SLA defined (99.9% uptime target)
- [ ] Incident response procedures documented
- [ ] DR procedures tested quarterly
- [ ] Monitoring and alerting operational

**Confidentiality (C1)**
- [ ] Data classification policy
- [ ] Encryption at rest and in transit
- [ ] Access control based on least privilege
- [ ] Secrets management via Secrets Manager

**Processing Integrity (PI1)**
- [ ] Input validation on all API endpoints
- [ ] Audit logging for all data modifications
- [ ] Error handling without data leakage

**Privacy (P1-P8)**
- [ ] Privacy notice published
- [ ] Data retention policies enforced
- [ ] Data subject rights procedures

---

## Security Incident Response

### Security Incident Playbook

```bash
# 1. Detect & Contain
# If suspected breach, immediately:

# Revoke all IAM credentials for compromised user/service
aws iam update-access-key \
  --access-key-id COMPROMISED_KEY \
  --status Inactive

# Rotate secrets
aws secretsmanager rotate-secret \
  --secret-id production/app/database-url

# Isolate compromised instance (remove from ALB)
aws elbv2 deregister-targets \
  --target-group-arn $TARGET_GROUP_ARN \
  --targets Id=$INSTANCE_ID

# 2. Investigate
# Review CloudTrail for unauthorized API calls
aws cloudtrail lookup-events \
  --lookup-attributes AttributeKey=AccessKeyId,AttributeValue=COMPROMISED_KEY \
  --start-time $(date -d '7 days ago' -u +%Y-%m-%dT%H:%M:%SZ) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ)

# Check VPC Flow Logs for suspicious traffic
aws logs start-query \
  --log-group-name "/aws/vpc/flowlogs" \
  --query-string 'fields srcAddr, dstAddr, action | filter action="REJECT" | stats count() by srcAddr | sort count desc'

# 3. Notify
# If data breach, notify according to GDPR/regulations within 72 hours
```

---

## Related Documentation

- [Deployment Guide](./DEPLOYMENT_GUIDE.md)
- [Operations Runbook](./OPERATIONS.md)
- [Disaster Recovery Procedures](./DR_PROCEDURES.md)
- [Monitoring & Observability Guide](./MONITORING.md)
