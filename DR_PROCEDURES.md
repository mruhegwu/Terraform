# Disaster Recovery Procedures

Backup strategy, recovery procedures, and business continuity planning for all production services.

---

## Table of Contents

1. [Overview](#overview)
2. [Recovery Objectives](#recovery-objectives)
3. [Database Backup Strategy](#database-backup-strategy)
4. [Cross-Region Backup Replication](#cross-region-backup-replication)
5. [Application State Backup](#application-state-backup)
6. [Disaster Recovery Testing](#disaster-recovery-testing)
7. [Recovery Procedures](#recovery-procedures)
8. [Data Retention Policies](#data-retention-policies)
9. [Compliance & Audit Logging](#compliance--audit-logging)

---

## Overview

### Disaster Scenarios

| Scenario                      | Probability | Impact | Priority |
|-------------------------------|-------------|--------|----------|
| Application container failure | High        | Low    | Auto-heal via ECS |
| Single AZ outage              | Medium      | Medium | Multi-AZ failover |
| Database corruption           | Low         | High   | Point-in-time restore |
| AWS Region outage             | Very Low    | Critical | Cross-region DR |
| Accidental data deletion      | Medium      | High   | Backup restore |
| Ransomware / security breach  | Low         | Critical | Isolate and restore |

### Architecture: Multi-AZ with Cross-Region DR

```
Primary Region (us-east-1)
├── VPC (Multi-AZ)
│   ├── AZ-1a: ECS Tasks + RDS Primary
│   └── AZ-1b: ECS Tasks + RDS Standby
├── S3 Buckets (with replication)
└── Route 53 Health Checks

DR Region (us-west-2) — Warm Standby
├── S3 Buckets (replicated)
├── RDS Read Replica (promoted on DR)
└── ECS Cluster (minimal capacity, scales on DR)
```

---

## Recovery Objectives

| Service               | RTO (Recovery Time) | RPO (Data Loss)   |
|-----------------------|---------------------|-------------------|
| Application (ECS)     | 5 minutes           | 0 (stateless)     |
| Database (RDS)        | 30 minutes          | 5 minutes (Multi-AZ) |
| File Storage (S3)     | 15 minutes          | 0 (replication)   |
| Cache (Redis)         | 10 minutes          | 1 hour (acceptable) |
| Full Regional DR      | 2 hours             | 1 hour            |

---

## Database Backup Strategy

### Automated RDS Backups

```bash
# Configure automated backups (via Terraform)
resource "aws_db_instance" "production" {
  identifier              = "production-db"
  backup_retention_period = 30        # 30 days retention
  backup_window           = "03:00-04:00"  # UTC (low traffic window)
  maintenance_window      = "Mon:04:00-Mon:05:00"
  deletion_protection     = true
  skip_final_snapshot     = false
  final_snapshot_identifier = "production-db-final-snapshot"

  # Multi-AZ for automatic failover
  multi_az = true
}
```

### Manual Snapshots

```bash
# Create manual snapshot before major changes
aws rds create-db-snapshot \
  --db-instance-identifier production-db \
  --db-snapshot-identifier "pre-migration-$(date +%Y%m%d-%H%M%S)" \
  --tags Key=Environment,Value=production Key=Reason,Value=pre-migration

# List available snapshots
aws rds describe-db-snapshots \
  --db-instance-identifier production-db \
  --query 'DBSnapshots[*].[DBSnapshotIdentifier,SnapshotCreateTime,Status]' \
  --output table

# Copy snapshot to DR region
aws rds copy-db-snapshot \
  --source-db-snapshot-identifier arn:aws:rds:us-east-1:123456789:snapshot:production-db-snapshot \
  --target-db-snapshot-identifier production-db-snapshot-dr \
  --source-region us-east-1 \
  --region us-west-2
```

### Daily Backup Automation

```yaml
# .github/workflows/db-backup.yml
name: Daily Database Backup

on:
  schedule:
    - cron: '0 2 * * *'  # 2 AM UTC daily

jobs:
  backup:
    runs-on: ubuntu-latest
    steps:
      - name: Configure AWS credentials
        uses: aws-actions/configure-aws-credentials@v4
        with:
          aws-access-key-id: ${{ secrets.AWS_ACCESS_KEY_ID }}
          aws-secret-access-key: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
          aws-region: us-east-1

      - name: Create RDS snapshot
        run: |
          SNAPSHOT_ID="automated-$(date +%Y%m%d)-$$"
          aws rds create-db-snapshot \
            --db-instance-identifier production-db \
            --db-snapshot-identifier "$SNAPSHOT_ID"

          echo "Snapshot $SNAPSHOT_ID created"

      - name: Copy to DR region
        run: |
          SOURCE_SNAPSHOT_ARN=$(aws rds describe-db-snapshots \
            --db-snapshot-identifier "$SNAPSHOT_ID" \
            --query 'DBSnapshots[0].DBSnapshotArn' --output text)

          aws rds copy-db-snapshot \
            --source-db-snapshot-identifier "$SOURCE_SNAPSHOT_ARN" \
            --target-db-snapshot-identifier "${SNAPSHOT_ID}-dr" \
            --source-region us-east-1 \
            --region us-west-2

      - name: Cleanup snapshots older than 30 days
        run: |
          CUTOFF_DATE=$(date -d '30 days ago' +%Y-%m-%d)
          aws rds describe-db-snapshots \
            --db-instance-identifier production-db \
            --snapshot-type manual \
            --query "DBSnapshots[?SnapshotCreateTime<='${CUTOFF_DATE}'].DBSnapshotIdentifier" \
            --output text | xargs -I{} aws rds delete-db-snapshot --db-snapshot-identifier {}
```

---

## Cross-Region Backup Replication

### S3 Cross-Region Replication

```bash
# Enable versioning on source bucket (required for replication)
aws s3api put-bucket-versioning \
  --bucket your-app-production-assets \
  --versioning-configuration Status=Enabled

# Enable versioning on destination bucket
aws s3api put-bucket-versioning \
  --bucket your-app-dr-assets-us-west-2 \
  --versioning-configuration Status=Enabled

# Configure replication
aws s3api put-bucket-replication \
  --bucket your-app-production-assets \
  --replication-configuration file://dr/s3-replication-config.json
```

### S3 Replication Config (`dr/s3-replication-config.json`)

```json
{
  "Role": "arn:aws:iam::123456789:role/S3ReplicationRole",
  "Rules": [
    {
      "ID": "ReplicateAllObjects",
      "Status": "Enabled",
      "Filter": {"Prefix": ""},
      "Destination": {
        "Bucket": "arn:aws:s3:::your-app-dr-assets-us-west-2",
        "StorageClass": "STANDARD_IA",
        "ReplicationTime": {
          "Status": "Enabled",
          "Time": {"Minutes": 15}
        },
        "Metrics": {
          "Status": "Enabled",
          "EventThreshold": {"Minutes": 15}
        }
      },
      "DeleteMarkerReplication": {"Status": "Enabled"}
    }
  ]
}
```

### RDS Read Replica in DR Region

```hcl
# terraform/modules/rds/dr.tf
resource "aws_db_instance" "dr_replica" {
  provider               = aws.dr_region  # us-west-2
  identifier             = "production-db-dr-replica"
  replicate_source_db    = aws_db_instance.production.arn
  instance_class         = "db.t3.medium"
  publicly_accessible    = false
  skip_final_snapshot    = false
  deletion_protection    = true

  tags = {
    Environment = "dr"
    Role        = "read-replica"
  }
}
```

---

## Application State Backup

### ECS Task Definition Backup

```bash
# Export all current task definitions
aws ecs list-task-definition-families \
  --query 'families[]' \
  --output text | \
  xargs -I{} aws ecs describe-task-definition \
    --task-definition {} \
    --query 'taskDefinition' > backup/task-definitions-$(date +%Y%m%d).json
```

### Secrets Backup

```bash
# Backup Secrets Manager secrets (metadata only, not values)
aws secretsmanager list-secrets \
  --query 'SecretList[*].[Name,ARN]' \
  --output json > backup/secrets-list-$(date +%Y%m%d).json

# Rotate secrets before backup
aws secretsmanager rotate-secret \
  --secret-id production/app/database-url
```

---

## Disaster Recovery Testing

### Quarterly DR Drills

**Schedule:** First Saturday of each quarter at 2:00 AM UTC.

```bash
# DR Test Script
#!/bin/bash
# scripts/dr-test.sh

echo "=== Starting DR Test $(date) ==="

# 1. Promote RDS Read Replica to standalone
aws rds promote-read-replica \
  --db-instance-identifier production-db-dr-replica \
  --region us-west-2

# 2. Update DNS to point to DR region
./scripts/dns-failover.sh us-west-2

# 3. Scale up DR ECS cluster
aws ecs update-service \
  --cluster dr-cluster \
  --service your-app-service \
  --desired-count 2 \
  --region us-west-2

# 4. Run smoke tests against DR environment
SMOKE_TEST_URL=https://dr.yourdomain.com npm run test:smoke

# 5. Measure actual RTO
echo "DR environment ready at $(date)"
echo "RTO: $SECONDS seconds"

# 6. Restore to primary (after validation)
read -p "DR validated. Restore to primary? [y/N] " confirm
if [[ $confirm == "y" ]]; then
  ./scripts/restore-primary.sh
fi
```

### DR Test Checklist

- [ ] Notify team of planned DR test (1 week before)
- [ ] Verify latest backup is available in DR region
- [ ] Snapshot current production state
- [ ] Execute DR failover script
- [ ] Validate application functionality in DR region
- [ ] Run full smoke test suite
- [ ] Measure actual RTO (target: < 2 hours)
- [ ] Document findings
- [ ] Restore to primary region
- [ ] Update DR procedures based on findings

---

## Recovery Procedures

### Scenario 1: Database Corruption

```bash
# 1. Identify corruption time
aws rds describe-events \
  --source-identifier production-db \
  --source-type db-instance \
  --duration 60

# 2. Restore to point-in-time (5 minutes before corruption)
aws rds restore-db-instance-to-point-in-time \
  --source-db-instance-identifier production-db \
  --target-db-instance-identifier production-db-restored \
  --restore-time "2024-01-15T03:50:00Z"

# 3. Update application to use restored instance
aws secretsmanager update-secret \
  --secret-id production/app/database-url \
  --secret-string "postgresql://user:pass@production-db-restored.xxx.us-east-1.rds.amazonaws.com:5432/mydb"

# 4. Restart ECS services to pick up new connection string
aws ecs update-service \
  --cluster production-cluster \
  --service your-app-service \
  --force-new-deployment
```

### Scenario 2: Region Outage

```bash
# AUTOMATED: Route 53 health check triggers DNS failover automatically

# MANUAL: Execute full DR failover
./scripts/dr-failover.sh us-west-2

# Steps executed by script:
# 1. Promote RDS read replica in us-west-2
# 2. Update Route 53 to point to us-west-2 ALB
# 3. Scale up ECS cluster in us-west-2
# 4. Verify S3 data availability
# 5. Run smoke tests
# 6. Notify team via SNS
```

### Scenario 3: Accidental Data Deletion

```bash
# 1. Immediately stop write traffic (emergency)
aws elbv2 modify-rule \
  --rule-arn $LISTENER_RULE_ARN \
  --actions Type=fixed-response,FixedResponseConfig='{StatusCode=503,MessageBody="Maintenance"}'

# 2. Identify deletion time from application logs
aws logs start-query \
  --log-group-name "/app/your-app-name" \
  --start-time $(date -d '2 hours ago' +%s) \
  --end-time $(date +%s) \
  --query-string 'fields @timestamp, @message | filter @message like /DELETE/ | sort @timestamp desc'

# 3. Restore from point-in-time backup
aws rds restore-db-instance-to-point-in-time \
  --source-db-instance-identifier production-db \
  --target-db-instance-identifier production-db-recovery \
  --restore-time "2024-01-15T03:45:00Z"

# 4. Export specific tables from recovery instance
pg_dump -h production-db-recovery.xxx.rds.amazonaws.com \
  -U postgres -t deleted_table mydb > /tmp/recovery-data.sql

# 5. Import to production
psql -h production-db.xxx.rds.amazonaws.com \
  -U postgres mydb < /tmp/recovery-data.sql
```

---

## Data Retention Policies

| Data Type              | Retention | Storage Class          | Compliance Requirement |
|------------------------|-----------|------------------------|------------------------|
| RDS Automated Backups  | 30 days   | AWS Managed            | SOC 2                  |
| RDS Manual Snapshots   | 90 days   | AWS Managed            | GDPR (right to erasure)|
| Application Logs       | 90 days   | CloudWatch → S3 IA     | Security audit         |
| Access Logs (ALB)      | 1 year    | S3 → S3 Glacier        | Compliance             |
| S3 Objects             | Per type  | S3 lifecycle policies  | Business requirement   |
| User Data              | Account lifetime + 30 days | RDS | GDPR               |
| Audit Logs             | 7 years   | S3 Glacier Deep Archive | SOC 2, GDPR          |

### S3 Lifecycle Policy

```json
{
  "Rules": [
    {
      "ID": "TransitionOldLogs",
      "Status": "Enabled",
      "Filter": {"Prefix": "logs/"},
      "Transitions": [
        {"Days": 30, "StorageClass": "STANDARD_IA"},
        {"Days": 90, "StorageClass": "GLACIER"},
        {"Days": 365, "StorageClass": "DEEP_ARCHIVE"}
      ],
      "Expiration": {"Days": 2555}
    }
  ]
}
```

---

## Compliance & Audit Logging

### CloudTrail Setup

```bash
# Enable CloudTrail (tracks all AWS API calls)
aws cloudtrail create-trail \
  --name production-audit-trail \
  --s3-bucket-name your-audit-logs-bucket \
  --include-global-service-events \
  --is-multi-region-trail \
  --enable-log-file-validation

aws cloudtrail start-logging --name production-audit-trail
```

### Application Audit Logging

```typescript
// src/middleware/audit.ts
import { Request, Response, NextFunction } from 'express';
import { logger } from '../utils/logger';

export function auditLog(req: Request, res: Response, next: NextFunction): void {
  const start = Date.now();

  res.on('finish', () => {
    // Log all mutating operations
    if (['POST', 'PUT', 'PATCH', 'DELETE'].includes(req.method)) {
      logger.info('audit', {
        type: 'api_call',
        method: req.method,
        path: req.path,
        userId: (req as any).user?.id,
        statusCode: res.statusCode,
        duration: Date.now() - start,
        ip: req.ip,
        userAgent: req.headers['user-agent'],
        requestId: req.headers['x-request-id'],
      });
    }
  });

  next();
}
```

### GDPR Compliance

```typescript
// src/services/gdpr.ts
export async function deleteUserData(userId: string): Promise<void> {
  await db.transaction(async (trx) => {
    // Anonymize instead of hard delete for audit trail preservation
    await trx('users').where({ id: userId }).update({
      email: `deleted-${userId}@deleted.invalid`,
      name: 'DELETED USER',
      phone: null,
      address: null,
      deleted_at: new Date(),
    });

    // Hard delete non-essential personal data
    await trx('user_sessions').where({ user_id: userId }).delete();
    await trx('user_notifications').where({ user_id: userId }).delete();
  });

  logger.info('audit', { type: 'gdpr_deletion', userId });
}
```

---

## Related Documentation

- [Deployment Guide](./DEPLOYMENT_GUIDE.md)
- [Monitoring & Observability Guide](./MONITORING.md)
- [Operations Runbook](./OPERATIONS.md)
- [Security Hardening Guide](./SECURITY.md)
