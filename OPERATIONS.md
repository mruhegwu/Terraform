# Operations Runbook

Day-to-day operational procedures, incident response, and maintenance workflows for production infrastructure.

---

## Table of Contents

1. [Daily Operations Checklist](#daily-operations-checklist)
2. [Weekly Operations Checklist](#weekly-operations-checklist)
3. [Incident Response Procedures](#incident-response-procedures)
4. [On-Call Rotation Setup](#on-call-rotation-setup)
5. [Deployment Checklist](#deployment-checklist)
6. [Rollback Procedures](#rollback-procedures)
7. [Performance Optimization Tasks](#performance-optimization-tasks)
8. [Security Patching Schedule](#security-patching-schedule)
9. [Maintenance Windows](#maintenance-windows)

---

## Daily Operations Checklist

Run every morning at the start of the business day (or automated via Lambda):

```bash
#!/bin/bash
# scripts/daily-health-check.sh

echo "=== Daily Health Check $(date) ==="

# 1. Check all ECS services are running
echo "--- ECS Services ---"
aws ecs list-services --cluster production-cluster --output text | \
  xargs -I{} aws ecs describe-services \
    --cluster production-cluster \
    --services {} \
    --query 'services[*].[serviceName,desiredCount,runningCount,status]' \
    --output table

# 2. Check RDS status
echo "--- RDS Status ---"
aws rds describe-db-instances \
  --query 'DBInstances[*].[DBInstanceIdentifier,DBInstanceStatus,MultiAZ]' \
  --output table

# 3. Check ALB health
echo "--- ALB Target Health ---"
aws elbv2 describe-target-health \
  --target-group-arn $TARGET_GROUP_ARN \
  --query 'TargetHealthDescriptions[*].[Target.Id,TargetHealth.State,TargetHealth.Reason]' \
  --output table

# 4. Check for CloudWatch alarms in ALARM state
echo "--- Active Alarms ---"
aws cloudwatch describe-alarms \
  --state-value ALARM \
  --query 'MetricAlarms[*].[AlarmName,StateReason]' \
  --output table

# 5. Check SSL certificate expiry
echo "--- Certificate Status ---"
aws acm list-certificates \
  --certificate-statuses ISSUED \
  --query 'CertificateSummaryList[*].[DomainName,CertificateArn]' \
  --output table
```

### Manual Daily Checks

- [ ] Review CloudWatch dashboards for anomalies
- [ ] Check error rate trends in application logs
- [ ] Review any overnight alerts/incidents
- [ ] Check database free storage and connections
- [ ] Verify last night's backup completed successfully
- [ ] Review cost dashboard for unexpected spikes
- [ ] Check deployment pipeline status

---

## Weekly Operations Checklist

Run every Monday morning:

- [ ] **Security**
  - Review IAM access advisor for unused permissions
  - Check for publicly exposed S3 buckets
  - Review Security Hub findings
  - Rotate secrets nearing 90-day age

- [ ] **Performance**
  - Review slow query logs from the past week
  - Check auto-scaling activity and trends
  - Review CloudFront cache hit rates
  - Analyze top API endpoints by latency

- [ ] **Cost**
  - Review AWS Cost Explorer for the past week
  - Check for orphaned resources (unattached EBS volumes, unused Elastic IPs)
  - Verify reserved instance coverage

- [ ] **Infrastructure**
  - Review Terraform state for drift
  - Check if any EC2/RDS instances need OS patching
  - Verify backup restore test (quarterly)

```bash
# Check for drift between Terraform state and actual AWS resources
cd terraform/
terraform workspace select production
terraform plan -var-file="environments/production.tfvars" -detailed-exitcode

# Exit code 0 = no changes, 2 = changes detected
if [ $? -eq 2 ]; then
  echo "DRIFT DETECTED - review plan output above"
fi
```

---

## Incident Response Procedures

### Severity Levels

| Severity | Definition                           | Response Time | Escalation     |
|----------|--------------------------------------|---------------|----------------|
| P1 (Critical) | Production down, total outage   | Immediate     | Engineering Lead |
| P2 (High) | Major feature broken, >50% users affected | 15 min | On-call + Lead |
| P3 (Medium) | Partial degradation, workaround available | 1 hour | On-call |
| P4 (Low) | Minor issue, minimal user impact     | Next business day | Team |

### Incident Response Playbook

#### Step 1: Detect & Alert (0-5 minutes)
```bash
# Check the CloudWatch dashboard
# Review recent deployments
git --no-pager log --oneline origin/main -10

# Check ECS service events
aws ecs describe-services \
  --cluster production-cluster \
  --services your-app-service \
  --query 'services[0].events[:10]' \
  --output table
```

#### Step 2: Assess Impact (5-10 minutes)
```bash
# Check error rate in logs
aws logs start-query \
  --log-group-name "/app/your-app-name" \
  --start-time $(date -d '30 minutes ago' +%s) \
  --end-time $(date +%s) \
  --query-string 'stats count() as errors by bin(1m) | filter level = "error"'

# Check ALB metrics
aws cloudwatch get-metric-statistics \
  --metric-name HTTPCode_Target_5XX_Count \
  --namespace AWS/ApplicationELB \
  --dimensions Name=LoadBalancer,Value=app/your-alb/abc123 \
  --start-time $(date -d '30 minutes ago' -u +%Y-%m-%dT%H:%M:%SZ) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) \
  --period 60 \
  --statistics Sum
```

#### Step 3: Communicate (immediately upon P1/P2)
```
Slack #incidents message template:
🚨 INCIDENT: [Brief description]
Severity: P[1/2/3]
Detected: [time]
Impact: [what users are affected]
Status: Investigating
Incident Commander: @[your-name]
```

#### Step 4: Diagnose
```bash
# Get container logs
aws logs tail /app/your-app-name --since 30m --follow

# Get ECS task logs
TASK_ID=$(aws ecs list-tasks --cluster production-cluster \
  --service-name your-app-service \
  --query 'taskArns[0]' --output text | cut -d'/' -f3)

aws ecs execute-command \
  --cluster production-cluster \
  --task $TASK_ID \
  --container your-app \
  --interactive \
  --command "/bin/sh"
```

#### Step 5: Mitigate
```bash
# Option A: Rollback deployment
./scripts/rollback.sh production v1.2.2

# Option B: Scale up (if capacity issue)
aws ecs update-service \
  --cluster production-cluster \
  --service your-app-service \
  --desired-count 6

# Option C: Redirect traffic to maintenance page
aws elbv2 modify-rule \
  --rule-arn $DEFAULT_RULE_ARN \
  --actions Type=redirect,RedirectConfig='{Protocol=HTTPS,Port=443,StatusCode=HTTP_302,Host=status.yourdomain.com}'
```

#### Step 6: Resolve & Document
```
Slack #incidents update:
✅ RESOLVED: [Brief description]
Duration: [start time] - [end time]
Root Cause: [brief explanation]
Fix Applied: [what was done]
Follow-up: [post-mortem scheduled / ticket created]
```

### Post-Mortem Template

```markdown
# Incident Post-Mortem: [Incident Title]

**Date:** YYYY-MM-DD
**Severity:** P[1/2/3/4]
**Duration:** X hours Y minutes
**Incident Commander:** [Name]

## Summary
Brief description of what happened and its impact.

## Timeline
| Time (UTC) | Event |
|------------|-------|
| HH:MM | Incident started |
| HH:MM | Alert fired |
| HH:MM | On-call responded |
| HH:MM | Root cause identified |
| HH:MM | Fix deployed |
| HH:MM | Incident resolved |

## Root Cause
Detailed explanation of what caused the incident.

## Impact
- Users affected: X%
- Error rate during incident: X%
- Revenue impact: $X (if applicable)

## What Went Well
- Fast detection via CloudWatch alarms
- Clear communication in #incidents

## What Went Wrong
- [Specific issue]

## Action Items
| Action | Owner | Due Date |
|--------|-------|----------|
| Add more specific alerting | @engineer | YYYY-MM-DD |
| Fix root cause | @engineer | YYYY-MM-DD |
```

---

## On-Call Rotation Setup

### PagerDuty Configuration

```bash
# Create on-call schedule via PagerDuty API
curl -X POST https://api.pagerduty.com/schedules \
  -H "Authorization: Token token=YOUR_PAGERDUTY_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "schedule": {
      "name": "Engineering On-Call",
      "time_zone": "America/New_York",
      "schedule_layers": [{
        "start": "2024-01-01T00:00:00-05:00",
        "rotation_virtual_start": "2024-01-01T00:00:00-05:00",
        "rotation_turn_length_seconds": 604800,
        "users": [
          {"user": {"id": "USER_ID_1", "type": "user_reference"}},
          {"user": {"id": "USER_ID_2", "type": "user_reference"}}
        ]
      }]
    }
  }'
```

### On-Call Responsibilities

**During on-call week:**
1. Respond to P1/P2 alerts within 5 minutes
2. Respond to P3 alerts within 1 hour
3. Keep PagerDuty app installed and notifications enabled
4. Maintain laptop accessibility during non-business hours
5. Hand off any open incidents when rotation changes

**Handoff checklist:**
- [ ] Review any open incidents or known issues
- [ ] Brief incoming engineer on any ongoing investigations
- [ ] Confirm all alerts are acknowledged or resolved
- [ ] Verify monitoring dashboards look normal

---

## Deployment Checklist

### Pre-Deployment

- [ ] Code reviewed and approved (minimum 2 approvals for production)
- [ ] All CI checks passing (lint, tests, security scan)
- [ ] Staging deployment successful and tested
- [ ] Database migrations tested on staging data
- [ ] Release notes / changelog updated
- [ ] Team notified of deployment window
- [ ] Rollback plan documented
- [ ] Database backup taken (for major releases)
- [ ] On-call engineer standing by

### During Deployment

- [ ] Monitor ECS deployment events
- [ ] Watch error rate in CloudWatch
- [ ] Verify health checks pass on new containers
- [ ] Monitor ALB target group health
- [ ] Check application logs for errors

### Post-Deployment

- [ ] Smoke tests pass
- [ ] Key user flows tested manually
- [ ] Performance metrics look normal
- [ ] No increase in error rate
- [ ] Team notified of successful deployment
- [ ] Deployment tagged in monitoring tools (Datadog/Sentry release)

---

## Rollback Procedures

### Automatic Rollback Triggers

The deployment pipeline automatically rolls back if within 10 minutes of deployment:
- Health check failure rate > 20%
- HTTP 5XX error rate > 5%
- Application logs show critical error

### Manual Rollback

```bash
# 1. Identify current and previous task definition versions
aws ecs describe-services \
  --cluster production-cluster \
  --services your-app-service \
  --query 'services[0].taskDefinition' \
  --output text

# Output: arn:aws:ecs:us-east-1:123456789:task-definition/your-app:42

# 2. Roll back to previous version
aws ecs update-service \
  --cluster production-cluster \
  --service your-app-service \
  --task-definition your-app:41 \
  --force-new-deployment \
  --region us-east-1

# 3. Monitor rollback progress
aws ecs wait services-stable \
  --cluster production-cluster \
  --services your-app-service \
  --region us-east-1

echo "Rollback complete"
```

### Database Rollback

```bash
# Only roll back migrations if strictly necessary
# Migrations should be backwards-compatible

# List migration status
npm run db:migrate:status

# Rollback one migration
npm run db:migrate:rollback

# Rollback to specific migration
npm run db:migrate:rollback -- --to 20240101000000
```

---

## Performance Optimization Tasks

### Weekly Performance Review

```bash
# Identify top slow queries
aws logs start-query \
  --log-group-name "/aws/rds/cluster/production-db/slowquery" \
  --start-time $(date -d '7 days ago' +%s) \
  --end-time $(date +%s) \
  --query-string 'fields @timestamp, query_time, @message | filter query_time > 1 | sort query_time desc | limit 20'

# Check cache hit rates
aws cloudwatch get-metric-statistics \
  --metric-name CacheHits \
  --namespace AWS/ElastiCache \
  --dimensions Name=CacheClusterId,Value=production-redis \
  --start-time $(date -d '7 days ago' -u +%Y-%m-%dT%H:%M:%SZ) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) \
  --period 3600 \
  --statistics Average
```

### Auto-Scaling Policy Review

```bash
# Check scaling activity from past week
aws application-autoscaling describe-scaling-activities \
  --service-namespace ecs \
  --resource-id service/production-cluster/your-app-service \
  --max-results 100

# Adjust scaling thresholds if needed
aws application-autoscaling put-scaling-policy \
  --service-namespace ecs \
  --scalable-dimension ecs:service:DesiredCount \
  --resource-id service/production-cluster/your-app-service \
  --policy-name cpu-scale-out \
  --policy-type TargetTrackingScaling \
  --target-tracking-scaling-policy-configuration '{
    "TargetValue": 70.0,
    "PredefinedMetricSpecification": {
      "PredefinedMetricType": "ECSServiceAverageCPUUtilization"
    },
    "ScaleOutCooldown": 300,
    "ScaleInCooldown": 300
  }'
```

---

## Security Patching Schedule

### Patch Categories

| Category              | Frequency   | Process                              |
|-----------------------|-------------|--------------------------------------|
| Critical CVEs         | Immediate   | Emergency patch within 24-48 hours   |
| High CVEs             | Weekly      | Scheduled patch within 7 days        |
| Medium CVEs           | Monthly     | Include in monthly maintenance       |
| Low CVEs              | Quarterly   | Batch with quarterly updates         |
| OS/AMI updates        | Monthly     | Blue-green EC2 replacement           |
| Node.js runtime       | On release  | Test in staging first                |
| npm dependencies      | Weekly      | Automated via Dependabot             |

### Monthly Patching Procedure

```bash
# 1. Check for available OS patches
aws ssm describe-instance-patch-states \
  --instance-ids $(aws ec2 describe-instances \
    --filters "Name=tag:Environment,Values=production" \
    --query 'Reservations[*].Instances[*].InstanceId' \
    --output text)

# 2. Scan npm dependencies for vulnerabilities
npm audit --production

# 3. Auto-fix non-breaking vulnerabilities
npm audit fix

# 4. Check container base images
# Review Dockerfile FROM statements and update if needed
docker scout cves your-app:latest

# 5. Run patching via SSM Patch Manager
aws ssm send-command \
  --document-name "AWS-RunPatchBaseline" \
  --targets "Key=tag:Environment,Values=production" \
  --parameters 'Operation=Install' \
  --timeout-seconds 3600
```

---

## Maintenance Windows

### Scheduled Maintenance

| Window           | Day/Time (UTC) | Duration | Purpose                    |
|------------------|----------------|----------|----------------------------|
| Weekly           | Sunday 02:00   | 2 hours  | OS patches, minor updates  |
| Monthly          | 1st Sun 01:00  | 4 hours  | Major updates, DB maintenance |
| Quarterly        | As scheduled   | 8 hours  | DR testing, major upgrades |

### Maintenance Communication

```bash
# Update status page before maintenance
curl -X POST https://api.statuspage.io/v1/pages/PAGE_ID/incidents \
  -H "Authorization: OAuth TOKEN" \
  -d '{
    "incident": {
      "name": "Scheduled Maintenance",
      "status": "scheduled",
      "scheduled_for": "2024-02-04T02:00:00.000Z",
      "scheduled_until": "2024-02-04T04:00:00.000Z",
      "scheduled_remind_prior": true,
      "body": "We will be performing scheduled maintenance. Expect brief interruptions."
    }
  }'
```

---

## Related Documentation

- [Deployment Guide](./DEPLOYMENT_GUIDE.md)
- [Monitoring & Observability Guide](./MONITORING.md)
- [Disaster Recovery Procedures](./DR_PROCEDURES.md)
- [Troubleshooting Guide](./TROUBLESHOOTING.md)
- [Security Hardening Guide](./SECURITY.md)
