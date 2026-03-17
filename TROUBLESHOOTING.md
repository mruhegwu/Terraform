# Troubleshooting Guide

Solutions for common deployment, application, and infrastructure issues.

---

## Table of Contents

1. [Deployment Issues](#deployment-issues)
2. [Application Startup Failures](#application-startup-failures)
3. [Database Connection Issues](#database-connection-issues)
4. [Performance Degradation](#performance-degradation)
5. [Memory Leaks Detection](#memory-leaks-detection)
6. [Network Connectivity Issues](#network-connectivity-issues)
7. [Recovery Procedures](#recovery-procedures)
8. [Diagnostic Commands Reference](#diagnostic-commands-reference)

---

## Deployment Issues

### Issue: ECS Deployment Stuck in "Pending" State

**Symptoms:** New ECS task stays in PENDING, old tasks not replaced.

**Diagnosis:**
```bash
# Check ECS service events for error messages
aws ecs describe-services \
  --cluster production-cluster \
  --services your-app-service \
  --query 'services[0].events[:10]' \
  --output table

# Check failed task reasons
aws ecs describe-tasks \
  --cluster production-cluster \
  --tasks $(aws ecs list-tasks --cluster production-cluster \
    --service-name your-app-service \
    --desired-status STOPPED \
    --query 'taskArns[0]' --output text) \
  --query 'tasks[0].stoppedReason'
```

**Common Causes & Solutions:**

| Cause | Solution |
|-------|----------|
| Insufficient CPU/memory capacity | Scale up ASG or use Fargate |
| ECR image pull failure | Check ECR permissions and image tag |
| Health check failing too fast | Increase health check grace period |
| Container can't start | Check CloudWatch Logs for startup errors |

```bash
# Fix: Increase health check grace period
aws ecs update-service \
  --cluster production-cluster \
  --service your-app-service \
  --health-check-grace-period-seconds 120
```

---

### Issue: GitHub Actions Deployment Fails

**Symptoms:** CI/CD pipeline fails with authentication or permission errors.

**Diagnosis:**
```bash
# Check GitHub Actions secrets are set
# Go to: Repository → Settings → Secrets and variables → Actions

# Verify AWS credentials have correct permissions
aws sts get-caller-identity

# Test ECR login
aws ecr get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin \
  123456789.dkr.ecr.us-east-1.amazonaws.com
```

**Common Causes & Solutions:**

```yaml
# Fix: Ensure correct IAM permissions in GitHub Actions
- name: Configure AWS credentials
  uses: aws-actions/configure-aws-credentials@v4
  with:
    aws-access-key-id: ${{ secrets.AWS_ACCESS_KEY_ID }}
    aws-secret-access-key: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
    aws-region: us-east-1
    # Add role-to-assume for better security
    role-to-assume: arn:aws:iam::123456789:role/github-actions-deploy
    role-duration-seconds: 3600
```

---

### Issue: Docker Build Fails

**Symptoms:** `docker build` fails with dependency or compilation errors.

```bash
# Debug build with verbose output
docker build \
  --no-cache \
  --progress=plain \
  --file docker/Dockerfile \
  --target production \
  . 2>&1 | tee /tmp/build-output.txt

# Check if base image is accessible
docker pull node:18-alpine

# Verify multi-platform build tools installed
docker buildx inspect default
```

---

### Issue: CloudFront Not Serving Latest Assets

**Symptoms:** Users see stale cached files after deployment.

```bash
# Force cache invalidation
aws cloudfront create-invalidation \
  --distribution-id E1234567890 \
  --paths "/*"

# Wait for invalidation to complete
INVALIDATION_ID=$(aws cloudfront list-invalidations \
  --distribution-id E1234567890 \
  --query 'InvalidationList.Items[0].Id' \
  --output text)

aws cloudfront wait invalidation-completed \
  --distribution-id E1234567890 \
  --id $INVALIDATION_ID

echo "Invalidation complete"

# Verify with cache-busting header
curl -I -H "Cache-Control: no-cache" https://yourdomain.com/app.js
```

---

## Application Startup Failures

### Issue: Container Exits Immediately with Code 1

**Symptoms:** ECS task starts then immediately stops.

**Diagnosis:**
```bash
# Get stopped task ID
TASK_ARN=$(aws ecs list-tasks \
  --cluster production-cluster \
  --desired-status STOPPED \
  --family your-app \
  --query 'taskArns[0]' \
  --output text)

# Get stop reason
aws ecs describe-tasks \
  --cluster production-cluster \
  --tasks $TASK_ARN \
  --query 'tasks[0].{StopCode:stopCode,StopReason:stoppedReason,Containers:containers[*].{Name:name,Reason:reason,ExitCode:exitCode}}'

# Get container logs
aws logs tail /ecs/your-app-task --since 10m
```

**Common Causes:**

1. **Missing environment variables:**
```bash
# Check task definition has all required env vars
aws ecs describe-task-definition \
  --task-definition your-app \
  --query 'taskDefinition.containerDefinitions[0].environment'

# Check secrets are accessible
aws secretsmanager get-secret-value \
  --secret-id production/app/database-url
```

2. **Port binding failure:**
```bash
# Ensure PORT environment variable matches Dockerfile EXPOSE
# Dockerfile: EXPOSE 3000
# Task definition: port mapping 3000:3000
# App code: app.listen(process.env.PORT || 3000)
```

3. **Application code error:**
```typescript
// Add proper error handling for startup
async function main(): Promise<void> {
  try {
    await db.connect();
    await redis.connect();
    app.listen(process.env.PORT || 3000, () => {
      console.log('Server started successfully');
    });
  } catch (error) {
    console.error('Fatal startup error:', error);
    process.exit(1);  // ECS will restart the task
  }
}

main();
```

---

### Issue: Application Crashes After Deployment

**Symptoms:** App starts successfully but crashes after a few minutes.

```bash
# Check for OOM kills
aws ecs describe-tasks \
  --cluster production-cluster \
  --tasks $TASK_ARN \
  --query 'tasks[0].containers[0].{Reason:reason,ExitCode:exitCode}'

# If exitCode is 137, it's an OOM kill
# Solution: Increase task memory
aws ecs register-task-definition \
  --cli-input-json file://ecs/task-definition.json
  # Update "memory": 2048 (was 1024)
```

---

## Database Connection Issues

### Issue: "Connection refused" to RDS

**Symptoms:** App logs show `ECONNREFUSED` connecting to database.

```bash
# 1. Verify RDS instance is running
aws rds describe-db-instances \
  --db-instance-identifier production-db \
  --query 'DBInstances[0].{Status:DBInstanceStatus,Endpoint:Endpoint}'

# 2. Check security group allows connection from ECS
aws ec2 describe-security-groups \
  --group-ids sg-app sg-database \
  --query 'SecurityGroups[*].{ID:GroupId,Rules:IpPermissions}'

# 3. Test connectivity from within VPC (using ECS exec)
aws ecs execute-command \
  --cluster production-cluster \
  --task $TASK_ID \
  --container your-app \
  --interactive \
  --command "nc -zv production-db.xxx.us-east-1.rds.amazonaws.com 5432"
```

---

### Issue: "Too many connections" Error

**Symptoms:** App logs show `remaining connection slots are reserved` or pool exhaustion.

```bash
# Check current connection count
aws cloudwatch get-metric-statistics \
  --metric-name DatabaseConnections \
  --namespace AWS/RDS \
  --dimensions Name=DBInstanceIdentifier,Value=production-db \
  --start-time $(date -d '1 hour ago' -u +%Y-%m-%dT%H:%M:%SZ) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) \
  --period 60 \
  --statistics Maximum
```

**Solutions:**

```typescript
// 1. Reduce connection pool size
const pool = new Pool({
  connectionString: process.env.DATABASE_URL,
  min: 1,    // Reduce from 2
  max: 5,    // Reduce from 10
  idleTimeoutMillis: 10000,
  connectionTimeoutMillis: 5000,
});

// 2. Use PgBouncer for connection pooling (add to infrastructure)
// Or use RDS Proxy (AWS managed connection pooler)
```

```bash
# Enable RDS Proxy (reduces connection overhead)
aws rds create-db-proxy \
  --db-proxy-name production-db-proxy \
  --engine-family POSTGRESQL \
  --auth '[{"AuthScheme":"SECRETS","SecretArn":"arn:aws:secretsmanager:...","IAMAuth":"DISABLED"}]' \
  --role-arn arn:aws:iam::123456789:role/rds-proxy-role \
  --vpc-subnet-ids subnet-xxx subnet-yyy \
  --vpc-security-group-ids sg-database
```

---

### Issue: Slow Database Queries

**Symptoms:** High response times, `statement timeout` errors.

```bash
# Find slow queries in RDS logs
aws logs start-query \
  --log-group-name "/aws/rds/instance/production-db/slowquery" \
  --start-time $(date -d '1 hour ago' +%s) \
  --end-time $(date +%s) \
  --query-string 'fields @timestamp, @message | filter query_time > 1 | sort query_time desc | limit 20'

# Get query ID
QUERY_ID=$(aws logs get-query-results --query-id $QUERY_ID | jq -r '.queryId')
aws logs get-query-results --query-id $QUERY_ID
```

**Solutions:**

```sql
-- Add missing indexes (example)
CREATE INDEX CONCURRENTLY idx_orders_user_id_created_at
  ON orders(user_id, created_at DESC);

-- Analyze query plan
EXPLAIN ANALYZE
SELECT * FROM orders WHERE user_id = 123 ORDER BY created_at DESC LIMIT 10;
```

---

## Performance Degradation

### Issue: High CPU Utilization

**Symptoms:** ECS CPU alarm firing, slow response times.

```bash
# Check which endpoints are slow
aws logs start-query \
  --log-group-name "/app/your-app-name" \
  --start-time $(date -d '1 hour ago' +%s) \
  --end-time $(date +%s) \
  --query-string 'fields url, method, responseTime | filter responseTime > 500 | stats avg(responseTime) as avgTime, count() by url, method | sort avgTime desc | limit 20'

# Scale out immediately if needed
aws ecs update-service \
  --cluster production-cluster \
  --service your-app-service \
  --desired-count 6

# Profile the application (add temporary profiling)
# Use clinic.js or 0x for Node.js profiling
npx clinic doctor -- node dist/index.js
```

---

### Issue: High Memory Utilization

```bash
# Check memory metrics
aws cloudwatch get-metric-statistics \
  --metric-name MemoryUtilization \
  --namespace AWS/ECS \
  --dimensions Name=ServiceName,Value=your-app-service Name=ClusterName,Value=production-cluster \
  --start-time $(date -d '6 hours ago' -u +%Y-%m-%dT%H:%M:%SZ) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) \
  --period 300 \
  --statistics Maximum,Average
```

---

## Memory Leaks Detection

### Identifying Memory Leaks

```typescript
// src/utils/memoryMonitor.ts
import { logger } from './logger';

let previousHeapUsed = 0;

export function startMemoryMonitoring(intervalMs = 60000): NodeJS.Timer {
  return setInterval(() => {
    const memUsage = process.memoryUsage();
    const heapUsedMB = Math.round(memUsage.heapUsed / 1024 / 1024);
    const heapTotalMB = Math.round(memUsage.heapTotal / 1024 / 1024);
    const rssMB = Math.round(memUsage.rss / 1024 / 1024);

    const heapGrowth = heapUsedMB - previousHeapUsed;
    previousHeapUsed = heapUsedMB;

    logger.info('Memory stats', {
      heapUsedMB,
      heapTotalMB,
      rssMB,
      heapGrowthMB: heapGrowth,
    });

    // Alert if heap grows by more than 50MB in one interval
    if (heapGrowth > 50) {
      logger.warn('Rapid memory growth detected', {
        heapGrowthMB: heapGrowth,
        heapUsedMB,
      });
    }

    // Force GC if memory is critically high (requires --expose-gc flag)
    if (heapUsedMB > 1500 && global.gc) {
      logger.info('Triggering manual GC due to high memory');
      global.gc();
    }
  }, intervalMs);
}
```

### Common Memory Leak Patterns

```typescript
// ❌ LEAK: Event listeners not removed
class DataService {
  constructor() {
    // This grows unbounded if DataService is instantiated multiple times
    eventEmitter.on('data', this.handleData.bind(this));
  }
}

// ✅ FIX: Remove listeners on cleanup
class DataService {
  private boundHandler: (data: any) => void;

  constructor() {
    this.boundHandler = this.handleData.bind(this);
    eventEmitter.on('data', this.boundHandler);
  }

  destroy(): void {
    eventEmitter.off('data', this.boundHandler);
  }
}

// ❌ LEAK: Caching without expiry
const cache = new Map<string, any>();
cache.set(key, value);  // Never cleaned up

// ✅ FIX: Use TTL-based cache
import { LRUCache } from 'lru-cache';
const cache = new LRUCache<string, any>({
  max: 1000,
  ttl: 5 * 60 * 1000,  // 5 minutes
});
```

---

## Network Connectivity Issues

### Issue: Services Can't Reach Each Other

```bash
# Test connectivity between services within VPC
aws ecs execute-command \
  --cluster production-cluster \
  --task $TASK_ID \
  --container your-app \
  --interactive \
  --command "/bin/sh"

# Inside container:
# Test Redis
nc -zv production-redis.xxx.cache.amazonaws.com 6379

# Test RDS
nc -zv production-db.xxx.us-east-1.rds.amazonaws.com 5432

# Test external API
curl -v https://api.external-service.com/health

# Check DNS resolution
nslookup production-db.xxx.us-east-1.rds.amazonaws.com
```

### Issue: NAT Gateway High Cost / Connectivity

```bash
# Check NAT Gateway data processed
aws cloudwatch get-metric-statistics \
  --metric-name BytesOutToDestination \
  --namespace AWS/NatGateway \
  --dimensions Name=NatGatewayId,Value=nat-xxxxx \
  --start-time $(date -d '7 days ago' -u +%Y-%m-%dT%H:%M:%SZ) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) \
  --period 86400 \
  --statistics Sum

# Identify top destinations using VPC Flow Logs
aws logs start-query \
  --log-group-name "/aws/vpc/flowlogs" \
  --query-string 'fields dstAddr, bytes | filter interfaceId like /nat/ | stats sum(bytes) as totalBytes by dstAddr | sort totalBytes desc | limit 20'
```

---

## Recovery Procedures

### Emergency: Take App Offline for Maintenance

```bash
# Return 503 maintenance page
aws elbv2 modify-listener \
  --listener-arn $HTTPS_LISTENER_ARN \
  --default-actions '[{
    "Type": "fixed-response",
    "FixedResponseConfig": {
      "StatusCode": "503",
      "ContentType": "text/html",
      "MessageBody": "<h1>Maintenance in progress. Back soon!</h1>"
    }
  }]'

# When done - restore normal routing
aws elbv2 modify-listener \
  --listener-arn $HTTPS_LISTENER_ARN \
  --default-actions '[{
    "Type": "forward",
    "TargetGroupArn": "'$TARGET_GROUP_ARN'"
  }]'
```

### Emergency: Force ECS Service Restart

```bash
# Stop all running tasks (ECS will restart them)
aws ecs list-tasks \
  --cluster production-cluster \
  --service-name your-app-service \
  --query 'taskArns[]' \
  --output text | \
  xargs -I{} aws ecs stop-task \
    --cluster production-cluster \
    --task {}

# Force new deployment (rolling restart)
aws ecs update-service \
  --cluster production-cluster \
  --service your-app-service \
  --force-new-deployment

# Wait for stable
aws ecs wait services-stable \
  --cluster production-cluster \
  --services your-app-service
```

---

## Diagnostic Commands Reference

### Quick Diagnostics Cheatsheet

```bash
# === ECS ===
# List running tasks
aws ecs list-tasks --cluster production-cluster --service-name your-app-service

# Get task details
aws ecs describe-tasks --cluster production-cluster --tasks $TASK_ARN

# Tail container logs
aws logs tail /ecs/your-app --since 30m --follow

# SSH into container
aws ecs execute-command --cluster production-cluster --task $TASK_ID \
  --container your-app --interactive --command "/bin/sh"

# === RDS ===
# Check DB status
aws rds describe-db-instances --db-instance-identifier production-db \
  --query 'DBInstances[0].{Status:DBInstanceStatus,Connections:PendingModifiedValues}'

# Get connection count
aws cloudwatch get-metric-statistics --metric-name DatabaseConnections \
  --namespace AWS/RDS --dimensions Name=DBInstanceIdentifier,Value=production-db \
  --start-time $(date -d '1 hour ago' -u +%Y-%m-%dT%H:%M:%SZ) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) --period 60 --statistics Maximum

# === ALB ===
# Check target health
aws elbv2 describe-target-health --target-group-arn $TARGET_GROUP_ARN

# Get recent 5XX errors
aws cloudwatch get-metric-statistics --metric-name HTTPCode_Target_5XX_Count \
  --namespace AWS/ApplicationELB \
  --dimensions Name=LoadBalancer,Value=app/your-alb/abc123 \
  --start-time $(date -d '1 hour ago' -u +%Y-%m-%dT%H:%M:%SZ) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) --period 60 --statistics Sum

# === General ===
# Check all CloudWatch alarms in ALARM state
aws cloudwatch describe-alarms --state-value ALARM

# List recent CloudTrail events
aws cloudtrail lookup-events --max-results 20

# Check EC2 instance status
aws ec2 describe-instance-status --include-all-instances
```

---

## Related Documentation

- [Deployment Guide](./DEPLOYMENT_GUIDE.md)
- [Monitoring & Observability Guide](./MONITORING.md)
- [Operations Runbook](./OPERATIONS.md)
- [Disaster Recovery Procedures](./DR_PROCEDURES.md)
