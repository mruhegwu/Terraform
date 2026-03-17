# Monitoring & Observability Guide

Comprehensive monitoring, alerting, and observability setup for TypeScript applications running on AWS infrastructure.

---

## Table of Contents

1. [Overview](#overview)
2. [CloudWatch Dashboards](#cloudwatch-dashboards)
3. [Log Aggregation](#log-aggregation)
4. [Alerting Configuration](#alerting-configuration)
5. [Application Performance Monitoring (APM)](#application-performance-monitoring-apm)
6. [Database Performance Tracking](#database-performance-tracking)
7. [Cost Monitoring](#cost-monitoring)
8. [Alert Thresholds & Escalation](#alert-thresholds--escalation)

---

## Overview

### Monitoring Stack

| Layer            | Tool                     | Purpose                            |
|------------------|--------------------------|------------------------------------|
| Infrastructure   | CloudWatch               | EC2/ECS/RDS metrics                |
| Application      | CloudWatch + Sentry      | App errors, performance            |
| Logs             | CloudWatch Logs          | Centralized log aggregation        |
| Tracing          | AWS X-Ray                | Distributed tracing                |
| Alerting         | CloudWatch Alarms + SNS  | Notifications                      |
| Cost             | AWS Cost Explorer + Budgets | Spend tracking                  |
| Uptime           | Route 53 Health Checks   | External availability monitoring   |

### Key Metrics

| Metric                | Target     | Alert Threshold |
|-----------------------|------------|-----------------|
| API Response Time P50 | < 200ms    | > 500ms         |
| API Response Time P99 | < 1000ms   | > 3000ms        |
| Error Rate            | < 0.1%     | > 1%            |
| CPU Utilization       | < 60%      | > 80%           |
| Memory Utilization    | < 70%      | > 85%           |
| Database Connections  | < 80% max  | > 90% max       |
| Cache Hit Rate        | > 80%      | < 60%           |

---

## CloudWatch Dashboards

### Creating the Main Dashboard

```bash
# Create application dashboard
aws cloudwatch put-dashboard \
  --dashboard-name "Production-Apps-Overview" \
  --dashboard-body file://monitoring/dashboards/main.json \
  --region us-east-1
```

### Dashboard Configuration (`monitoring/dashboards/main.json`)

```json
{
  "widgets": [
    {
      "type": "metric",
      "properties": {
        "title": "ECS CPU & Memory Utilization",
        "metrics": [
          ["AWS/ECS", "CPUUtilization", "ServiceName", "your-app-service", "ClusterName", "production-cluster"],
          ["AWS/ECS", "MemoryUtilization", "ServiceName", "your-app-service", "ClusterName", "production-cluster"]
        ],
        "period": 300,
        "stat": "Average",
        "view": "timeSeries",
        "yAxis": {"left": {"min": 0, "max": 100}},
        "annotations": {
          "horizontal": [{"value": 80, "label": "Alert threshold", "color": "#ff6961"}]
        }
      }
    },
    {
      "type": "metric",
      "properties": {
        "title": "ALB Request Count & Latency",
        "metrics": [
          ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", "app/your-alb/abc123"],
          ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", "app/your-alb/abc123", {"stat": "p99", "label": "P99 Latency"}]
        ],
        "period": 60,
        "view": "timeSeries"
      }
    },
    {
      "type": "metric",
      "properties": {
        "title": "HTTP Error Rates (4XX & 5XX)",
        "metrics": [
          ["AWS/ApplicationELB", "HTTPCode_Target_4XX_Count", "LoadBalancer", "app/your-alb/abc123"],
          ["AWS/ApplicationELB", "HTTPCode_Target_5XX_Count", "LoadBalancer", "app/your-alb/abc123"]
        ],
        "period": 60,
        "stat": "Sum",
        "view": "timeSeries"
      }
    },
    {
      "type": "metric",
      "properties": {
        "title": "RDS Database Performance",
        "metrics": [
          ["AWS/RDS", "DatabaseConnections", "DBInstanceIdentifier", "production-db"],
          ["AWS/RDS", "ReadLatency", "DBInstanceIdentifier", "production-db"],
          ["AWS/RDS", "WriteLatency", "DBInstanceIdentifier", "production-db"],
          ["AWS/RDS", "FreeStorageSpace", "DBInstanceIdentifier", "production-db"]
        ],
        "period": 300,
        "view": "timeSeries"
      }
    },
    {
      "type": "metric",
      "properties": {
        "title": "ElastiCache Redis",
        "metrics": [
          ["AWS/ElastiCache", "CacheHits", "CacheClusterId", "production-redis"],
          ["AWS/ElastiCache", "CacheMisses", "CacheClusterId", "production-redis"],
          ["AWS/ElastiCache", "CurrConnections", "CacheClusterId", "production-redis"]
        ],
        "period": 300,
        "view": "timeSeries"
      }
    }
  ]
}
```

### Application-Specific Dashboards

Create a dashboard per application:

```bash
# Create per-app dashboard
for APP in app1 app2 app3; do
  aws cloudwatch put-dashboard \
    --dashboard-name "Production-${APP}" \
    --dashboard-body "$(cat monitoring/dashboards/app-template.json | sed "s/APP_NAME/${APP}/g")" \
    --region us-east-1
done
```

---

## Log Aggregation

### CloudWatch Logs Setup

Each application should send structured JSON logs to CloudWatch Logs:

```typescript
// src/utils/logger.ts
import winston from 'winston';
import WinstonCloudWatch from 'winston-cloudwatch';

export const logger = winston.createLogger({
  level: process.env.LOG_LEVEL || 'info',
  format: winston.format.combine(
    winston.format.timestamp(),
    winston.format.errors({ stack: true }),
    winston.format.json()
  ),
  defaultMeta: {
    service: process.env.APP_NAME,
    environment: process.env.NODE_ENV,
    version: process.env.APP_VERSION,
  },
  transports: [
    new winston.transports.Console(),
    ...(process.env.NODE_ENV === 'production'
      ? [
          new WinstonCloudWatch({
            logGroupName: `/app/${process.env.APP_NAME}`,
            logStreamName: `${new Date().toISOString().slice(0, 10)}-${process.env.HOSTNAME}`,
            awsRegion: process.env.AWS_REGION,
            jsonValueFormatter: (value) => JSON.stringify(value),
          }),
        ]
      : []),
  ],
});

// Usage
logger.info('User logged in', { userId: user.id, ip: req.ip });
logger.error('Database query failed', { error: err.message, query: sql });
```

### Log Groups

| Log Group                    | Retention | Purpose                    |
|------------------------------|-----------|----------------------------|
| `/app/your-app-name`         | 30 days   | Application logs           |
| `/ecs/production-cluster`    | 14 days   | ECS container logs         |
| `/aws/rds/production-db`     | 7 days    | Database slow query logs   |
| `/aws/lambda/functions`      | 30 days   | Lambda function logs       |
| `/aws/alb/access-logs`       | 90 days   | Load balancer access logs  |

```bash
# Set log retention policy
aws logs put-retention-policy \
  --log-group-name "/app/your-app-name" \
  --retention-in-days 30

# Create metric filter for error counting
aws logs put-metric-filter \
  --log-group-name "/app/your-app-name" \
  --filter-name "ErrorCount" \
  --filter-pattern '{ $.level = "error" }' \
  --metric-transformations \
    metricName=ErrorCount,metricNamespace=YourApp,metricValue=1,defaultValue=0
```

### Log Insights Queries

```sql
-- Top error messages (last 24h)
fields @timestamp, @message, level, error.message
| filter level = "error"
| stats count() as errorCount by error.message
| sort errorCount desc
| limit 20

-- Slow API requests (> 1000ms)
fields @timestamp, method, url, responseTime, statusCode
| filter responseTime > 1000
| sort responseTime desc
| limit 50

-- Request volume by endpoint
fields @timestamp, method, url
| filter ispresent(url)
| stats count() as requests by url, method
| sort requests desc
| limit 20

-- Error rate over time
fields @timestamp, level
| stats count(level = "error") as errors, count(*) as total by bin(5m)
| eval errorRate = (errors / total) * 100
| sort @timestamp
```

---

## Alerting Configuration

### SNS Topics

```bash
# Create SNS topics for different severity levels
aws sns create-topic --name "production-critical-alerts"
aws sns create-topic --name "production-warning-alerts"
aws sns create-topic --name "production-info-alerts"

# Subscribe team email
aws sns subscribe \
  --topic-arn arn:aws:sns:us-east-1:123456789:production-critical-alerts \
  --protocol email \
  --notification-endpoint oncall-team@yourdomain.com

# Subscribe Slack via Lambda or SNS HTTP endpoint
aws sns subscribe \
  --topic-arn arn:aws:sns:us-east-1:123456789:production-critical-alerts \
  --protocol https \
  --notification-endpoint https://hooks.slack.com/services/YOUR/WEBHOOK/URL
```

### CloudWatch Alarms

```bash
# High CPU alarm (warning)
aws cloudwatch put-metric-alarm \
  --alarm-name "ECS-High-CPU-Warning" \
  --alarm-description "ECS CPU utilization above 70%" \
  --metric-name CPUUtilization \
  --namespace AWS/ECS \
  --dimensions Name=ServiceName,Value=your-app-service Name=ClusterName,Value=production-cluster \
  --period 300 \
  --evaluation-periods 2 \
  --threshold 70 \
  --comparison-operator GreaterThanThreshold \
  --alarm-actions arn:aws:sns:us-east-1:123456789:production-warning-alerts \
  --ok-actions arn:aws:sns:us-east-1:123456789:production-info-alerts

# Critical CPU alarm
aws cloudwatch put-metric-alarm \
  --alarm-name "ECS-High-CPU-Critical" \
  --alarm-description "ECS CPU utilization above 90%" \
  --metric-name CPUUtilization \
  --namespace AWS/ECS \
  --dimensions Name=ServiceName,Value=your-app-service Name=ClusterName,Value=production-cluster \
  --period 300 \
  --evaluation-periods 2 \
  --threshold 90 \
  --comparison-operator GreaterThanThreshold \
  --alarm-actions arn:aws:sns:us-east-1:123456789:production-critical-alerts

# Memory alarm
aws cloudwatch put-metric-alarm \
  --alarm-name "ECS-High-Memory-Warning" \
  --metric-name MemoryUtilization \
  --namespace AWS/ECS \
  --dimensions Name=ServiceName,Value=your-app-service Name=ClusterName,Value=production-cluster \
  --period 300 \
  --evaluation-periods 2 \
  --threshold 85 \
  --comparison-operator GreaterThanThreshold \
  --alarm-actions arn:aws:sns:us-east-1:123456789:production-warning-alerts

# ALB 5XX error rate
aws cloudwatch put-metric-alarm \
  --alarm-name "ALB-5XX-Rate-High" \
  --metric-name HTTPCode_Target_5XX_Count \
  --namespace AWS/ApplicationELB \
  --dimensions Name=LoadBalancer,Value=app/your-alb/abc123 \
  --period 60 \
  --evaluation-periods 3 \
  --threshold 10 \
  --comparison-operator GreaterThanThreshold \
  --alarm-actions arn:aws:sns:us-east-1:123456789:production-critical-alerts

# RDS storage alarm
aws cloudwatch put-metric-alarm \
  --alarm-name "RDS-Low-Storage" \
  --metric-name FreeStorageSpace \
  --namespace AWS/RDS \
  --dimensions Name=DBInstanceIdentifier,Value=production-db \
  --period 300 \
  --evaluation-periods 1 \
  --threshold 5368709120 \
  --comparison-operator LessThanThreshold \
  --alarm-actions arn:aws:sns:us-east-1:123456789:production-critical-alerts
```

---

## Application Performance Monitoring (APM)

### Sentry Integration

```typescript
// src/index.ts - Initialize Sentry before all other imports
import * as Sentry from '@sentry/node';
import { nodeProfilingIntegration } from '@sentry/profiling-node';

Sentry.init({
  dsn: process.env.SENTRY_DSN,
  environment: process.env.NODE_ENV,
  release: process.env.APP_VERSION,
  integrations: [
    nodeProfilingIntegration(),
    Sentry.httpIntegration(),
    Sentry.expressIntegration(),
  ],
  tracesSampleRate: process.env.NODE_ENV === 'production' ? 0.1 : 1.0,
  profilesSampleRate: 0.1,
  beforeSend(event) {
    // Filter out health check noise
    if (event.request?.url?.includes('/health')) {
      return null;
    }
    return event;
  },
});
```

### AWS X-Ray Tracing

```typescript
// src/tracing.ts
import AWSXRay from 'aws-xray-sdk-core';
import * as http from 'http';
import * as https from 'https';

// Enable X-Ray tracing in production
if (process.env.NODE_ENV === 'production') {
  AWSXRay.captureHTTPsGlobal(http, true);
  AWSXRay.captureHTTPsGlobal(https, true);

  // Capture PostgreSQL queries
  AWSXRay.capturePromise();
}

export { AWSXRay };
```

### Custom Metrics

```typescript
// src/utils/metrics.ts
import { CloudWatch } from '@aws-sdk/client-cloudwatch';

const cloudwatch = new CloudWatch({ region: process.env.AWS_REGION });

export async function recordMetric(
  name: string,
  value: number,
  unit: 'Count' | 'Milliseconds' | 'Percent' = 'Count',
  dimensions: Record<string, string> = {}
): Promise<void> {
  await cloudwatch.putMetricData({
    Namespace: `YourApp/${process.env.APP_NAME}`,
    MetricData: [
      {
        MetricName: name,
        Value: value,
        Unit: unit,
        Timestamp: new Date(),
        Dimensions: Object.entries(dimensions).map(([Name, Value]) => ({ Name, Value })),
      },
    ],
  });
}

// Usage examples
await recordMetric('UserRegistrations', 1, 'Count', { Environment: 'production' });
await recordMetric('PaymentProcessingTime', 450, 'Milliseconds');
await recordMetric('CacheHitRate', 85.3, 'Percent');
```

---

## Database Performance Tracking

### Enable RDS Performance Insights

```bash
# Enable Performance Insights via AWS CLI
aws rds modify-db-instance \
  --db-instance-identifier production-db \
  --enable-performance-insights \
  --performance-insights-retention-period 7 \
  --apply-immediately
```

### Slow Query Monitoring

```bash
# Enable slow query logging
aws rds modify-db-parameter-group \
  --db-parameter-group-name production-params \
  --parameters \
    "ParameterName=slow_query_log,ParameterValue=1,ApplyMethod=immediate" \
    "ParameterName=long_query_time,ParameterValue=1,ApplyMethod=immediate" \
    "ParameterName=log_queries_not_using_indexes,ParameterValue=1,ApplyMethod=immediate"
```

### Connection Pool Monitoring

```typescript
// src/database/pool.ts
import { Pool } from 'pg';
import { logger } from '../utils/logger';
import { recordMetric } from '../utils/metrics';

const pool = new Pool({
  connectionString: process.env.DATABASE_URL,
  min: parseInt(process.env.DATABASE_POOL_MIN || '2'),
  max: parseInt(process.env.DATABASE_POOL_MAX || '10'),
  idleTimeoutMillis: 30000,
  connectionTimeoutMillis: 5000,
});

// Monitor pool stats every 30 seconds
setInterval(() => {
  const stats = {
    total: pool.totalCount,
    idle: pool.idleCount,
    waiting: pool.waitingCount,
  };
  logger.info('Database pool stats', stats);
  recordMetric('DBPoolTotal', stats.total);
  recordMetric('DBPoolIdle', stats.idle);
  recordMetric('DBPoolWaiting', stats.waiting);
}, 30_000);

export { pool };
```

---

## Cost Monitoring

### AWS Budgets

```bash
# Create monthly budget alert
aws budgets create-budget \
  --account-id 123456789 \
  --budget '{
    "BudgetName": "Monthly-Production-Budget",
    "BudgetLimit": {"Amount": "500", "Unit": "USD"},
    "TimeUnit": "MONTHLY",
    "BudgetType": "COST"
  }' \
  --notifications-with-subscribers '[
    {
      "Notification": {
        "NotificationType": "ACTUAL",
        "ComparisonOperator": "GREATER_THAN",
        "Threshold": 80,
        "ThresholdType": "PERCENTAGE"
      },
      "Subscribers": [{"SubscriptionType": "EMAIL", "Address": "finance@yourdomain.com"}]
    },
    {
      "Notification": {
        "NotificationType": "FORECASTED",
        "ComparisonOperator": "GREATER_THAN",
        "Threshold": 100,
        "ThresholdType": "PERCENTAGE"
      },
      "Subscribers": [{"SubscriptionType": "EMAIL", "Address": "finance@yourdomain.com"}]
    }
  ]'
```

### Cost Allocation Tags

```bash
# Enable cost allocation tags
aws ce update-cost-allocation-tags-status \
  --cost-allocation-tags-status TagKey=Environment,Status=Active TagKey=Application,Status=Active TagKey=Team,Status=Active
```

---

## Alert Thresholds & Escalation

### Escalation Policy

```
Level 1 — Warning (automated)
  • Slack #monitoring channel
  • On-call engineer gets push notification
  • Response time: 30 minutes

Level 2 — Critical (automated)
  • PagerDuty page to on-call engineer
  • Slack #incidents channel
  • Response time: 5 minutes

Level 3 — P0 (manual escalation)
  • Engineering lead paged
  • All senior engineers notified
  • Response time: Immediate
```

### Alert Thresholds Reference

| Alert Name                   | Warning    | Critical   | P0         |
|------------------------------|------------|------------|------------|
| CPU Utilization              | 70%        | 90%        | 95%        |
| Memory Utilization           | 80%        | 90%        | 95%        |
| API Error Rate               | 1%         | 5%         | 10%        |
| API P99 Latency              | 1000ms     | 3000ms     | 10000ms    |
| DB Connection Usage          | 70%        | 85%        | 95%        |
| DB Free Storage              | < 20 GB    | < 10 GB    | < 5 GB     |
| ECS Task Count (min)         | < desired  | < minimum  | 0          |
| SSL Certificate Expiry       | 45 days    | 14 days    | 7 days     |
| Deployment Success Rate      | < 95%      | < 90%      | < 80%      |

---

## Related Documentation

- [Deployment Guide](./DEPLOYMENT_GUIDE.md)
- [Disaster Recovery Procedures](./DR_PROCEDURES.md)
- [Operations Runbook](./OPERATIONS.md)
- [Troubleshooting Guide](./TROUBLESHOOTING.md)
