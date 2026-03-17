# Cost Optimization Guide

Strategies and procedures for optimizing AWS infrastructure costs while maintaining performance and reliability.

---

## Table of Contents

1. [Cost Overview](#cost-overview)
2. [Reserved Instance Strategy](#reserved-instance-strategy)
3. [Spot Instance Strategy](#spot-instance-strategy)
4. [Data Transfer Optimization](#data-transfer-optimization)
5. [Storage Optimization](#storage-optimization)
6. [Compute Rightsizing](#compute-rightsizing)
7. [Cost Alerts & Budgets](#cost-alerts--budgets)
8. [Monthly Cost Review Process](#monthly-cost-review-process)

---

## Cost Overview

### Typical Cost Breakdown

| Service          | Estimated % | Monthly Est. | Optimization Potential |
|------------------|-------------|--------------|------------------------|
| EC2 / ECS        | 40-50%      | $200-400     | High (Reserved/Spot)   |
| RDS              | 20-25%      | $100-200     | Medium (Reserved)      |
| CloudFront + S3  | 5-10%       | $25-80       | Low                    |
| ElastiCache      | 10-15%      | $50-120      | Medium (Reserved)      |
| Data Transfer    | 5-10%       | $25-80       | Medium (CDN)           |
| Other (NAT, EIP) | 5-10%       | $25-80       | Low                    |

*Estimates for small-to-medium production workload.*

### Cost Tags Strategy

All resources must be tagged for accurate cost allocation:

```hcl
# terraform/variables.tf
locals {
  common_tags = {
    Environment = var.environment
    Application = var.app_name
    Team        = var.team_name
    ManagedBy   = "terraform"
    CostCenter  = var.cost_center
  }
}
```

---

## Reserved Instance Strategy

### When to Purchase Reserved Instances

Purchase Reserved Instances (RIs) for resources that run **24/7 for 12+ months**:

| Resource              | RI Type          | Commitment | Savings vs On-Demand |
|-----------------------|------------------|------------|----------------------|
| ECS/EC2 production    | Compute Savings Plan | 1 year | ~30-40%           |
| RDS production DB     | Standard RI      | 1 year     | ~30-40%            |
| ElastiCache Redis     | Reserved Node    | 1 year     | ~30%               |

### Purchasing Process

```bash
# 1. Analyze current usage to determine RI size needed
aws ce get-reservation-purchase-recommendation \
  --service EC2 \
  --account-scope LINKED \
  --lookback-period-in-days SIXTY_DAYS \
  --term-in-years ONE_YEAR \
  --payment-option PARTIAL_UPFRONT

# 2. Purchase Compute Savings Plan (most flexible, covers EC2 + Fargate)
aws savingsplans purchase-savings-plan \
  --savings-plan-type ComputeSavingsPlans \
  --payment-option PartialUpfront \
  --duration-seconds 31536000 \
  --commitment 5.00  # $5/hour commitment

# 3. Purchase RDS Reserved Instance
aws rds purchase-reserved-db-instances-offering \
  --reserved-db-instances-offering-id <offering-id> \
  --reserved-db-instance-id production-db-ri-2024 \
  --db-instance-count 1
```

### RI Coverage Monitoring

```bash
# Check RI utilization (should be > 90%)
aws ce get-reservation-utilization \
  --time-period Start=2024-01-01,End=2024-01-31 \
  --granularity MONTHLY

# Check RI coverage (% of usage covered by RIs)
aws ce get-reservation-coverage \
  --time-period Start=2024-01-01,End=2024-01-31 \
  --granularity MONTHLY
```

---

## Spot Instance Strategy

### Eligible Workloads for Spot

| Workload                    | Spot Eligible? | Strategy              |
|-----------------------------|----------------|-----------------------|
| Production ECS services     | No             | On-demand/RI          |
| Development ECS services    | Yes            | Spot with fallback    |
| CI/CD build runners         | Yes            | Spot instances        |
| Batch processing jobs       | Yes            | Spot fleet            |
| Load testing                | Yes            | Spot instances        |
| Machine learning training   | Yes            | Spot instances        |

### Spot Configuration for Non-Critical Services

```hcl
# terraform/modules/ecs/spot.tf
resource "aws_ecs_capacity_provider" "spot" {
  name = "${var.app_name}-spot-provider"

  auto_scaling_group_provider {
    auto_scaling_group_arn = aws_autoscaling_group.spot.arn

    managed_scaling {
      maximum_scaling_step_size = 5
      minimum_scaling_step_size = 1
      status                    = "ENABLED"
      target_capacity           = 80
    }
  }
}

resource "aws_autoscaling_group" "spot" {
  name                = "${var.app_name}-spot-asg"
  vpc_zone_identifier = var.private_subnet_ids
  max_size            = 10
  min_size            = 0
  desired_capacity    = 2

  mixed_instances_policy {
    instances_distribution {
      on_demand_base_capacity                  = 0
      on_demand_percentage_above_base_capacity = 0
      spot_allocation_strategy                 = "capacity-optimized"
    }

    launch_template {
      launch_template_specification {
        launch_template_id = aws_launch_template.app.id
        version            = "$Latest"
      }

      # Multiple instance types for higher spot availability
      override {
        instance_type = "t3.medium"
      }
      override {
        instance_type = "t3a.medium"
      }
      override {
        instance_type = "t2.medium"
      }
    }
  }

  tag {
    key                 = "Environment"
    value               = "development"
    propagate_at_launch = true
  }
}
```

### Spot Interruption Handling

```typescript
// src/utils/spotHandler.ts
import axios from 'axios';
import { logger } from './logger';

// Poll EC2 instance metadata for spot interruption notice
async function checkSpotInterruption(): Promise<void> {
  try {
    const response = await axios.get(
      'http://169.254.169.254/latest/meta-data/spot/termination-time',
      { timeout: 1000 }
    );

    if (response.status === 200) {
      logger.warn('Spot interruption notice received, shutting down gracefully', {
        terminationTime: response.data,
      });

      // Deregister from load balancer, finish in-flight requests
      await gracefulShutdown();
    }
  } catch {
    // No interruption notice (404 = normal operation)
  }
}

// Check every 5 seconds
if (process.env.AWS_INSTANCE_TYPE?.startsWith('spot')) {
  setInterval(checkSpotInterruption, 5000);
}
```

---

## Data Transfer Optimization

### Reduce Inter-AZ Transfer Costs

```typescript
// Ensure services prefer same-AZ communication
// ECS task placement constraint
{
  "placementConstraints": [{
    "type": "memberOf",
    "expression": "attribute:ecs.availability-zone == us-east-1a"
  }]
}
```

### CloudFront Configuration for Reduced Origin Requests

```hcl
resource "aws_cloudfront_distribution" "app" {
  # Aggressive caching to reduce origin requests
  default_cache_behavior {
    cache_policy_id = aws_cloudfront_cache_policy.optimized.id

    # Compress responses
    compress = true
  }
}

resource "aws_cloudfront_cache_policy" "optimized" {
  name    = "optimized-caching-policy"

  default_ttl = 86400    # 1 day
  max_ttl     = 31536000 # 1 year
  min_ttl     = 0

  parameters_in_cache_key_and_forwarded_to_origin {
    cookies_config { cookie_behavior = "none" }
    headers_config  { header_behavior = "none" }
    query_strings_config { query_string_behavior = "none" }
    enable_accept_encoding_brotli = true
    enable_accept_encoding_gzip   = true
  }
}
```

### VPC Endpoints (Eliminate NAT Gateway Costs)

```hcl
# S3 Gateway endpoint (free - saves NAT gateway costs)
resource "aws_vpc_endpoint" "s3" {
  vpc_id       = aws_vpc.main.id
  service_name = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids = [aws_route_table.private.id]
}

# DynamoDB Gateway endpoint (free)
resource "aws_vpc_endpoint" "dynamodb" {
  vpc_id       = aws_vpc.main.id
  service_name = "com.amazonaws.${var.aws_region}.dynamodb"
  vpc_endpoint_type = "Gateway"
  route_table_ids = [aws_route_table.private.id]
}

# Secrets Manager Interface endpoint (avoid NAT gateway costs)
resource "aws_vpc_endpoint" "secretsmanager" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.secretsmanager"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true
}
```

---

## Storage Optimization

### S3 Intelligent-Tiering

```bash
# Enable Intelligent-Tiering for unknown access patterns
aws s3api put-bucket-intelligent-tiering-configuration \
  --bucket your-app-production-uploads \
  --id EntireBucket \
  --intelligent-tiering-configuration '{
    "Id": "EntireBucket",
    "Status": "Enabled",
    "OptionalTiers": [
      {"AccessTier": "ARCHIVE_ACCESS", "Days": 90},
      {"AccessTier": "DEEP_ARCHIVE_ACCESS", "Days": 180}
    ]
  }'
```

### EBS Volume Optimization

```bash
# Find and delete unattached EBS volumes
aws ec2 describe-volumes \
  --filters "Name=status,Values=available" \
  --query 'Volumes[*].[VolumeId,Size,CreateTime]' \
  --output table

# Convert gp2 volumes to gp3 (20% cheaper, better performance)
aws ec2 describe-volumes \
  --filters "Name=volume-type,Values=gp2" \
  --query 'Volumes[*].VolumeId' \
  --output text | \
  xargs -I{} aws ec2 modify-volume \
    --volume-id {} \
    --volume-type gp3
```

### RDS Storage Auto-Scaling

```hcl
resource "aws_db_instance" "production" {
  # Enable storage auto-scaling
  allocated_storage     = 100   # Initial size (GB)
  max_allocated_storage = 1000  # Maximum (scales automatically)

  # Use gp3 for 20% cost savings over gp2
  storage_type = "gp3"
}
```

---

## Compute Rightsizing

### Finding Oversized Instances

```bash
# Get EC2 rightsizing recommendations
aws ce get-rightsizing-recommendation \
  --service EC2 \
  --configuration '{"RecommendationTarget":"SAME_INSTANCE_FAMILY","BenefitsConsidered":true}'

# Check actual ECS CPU/Memory usage vs reservation
aws cloudwatch get-metric-statistics \
  --metric-name CPUUtilization \
  --namespace AWS/ECS \
  --dimensions Name=ServiceName,Value=your-app-service Name=ClusterName,Value=production-cluster \
  --start-time $(date -d '30 days ago' -u +%Y-%m-%dT%H:%M:%SZ) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) \
  --period 86400 \
  --statistics Average,Maximum
```

### ECS Task Rightsizing

Compare reserved resources vs actual usage:

```bash
# Check task CPU/memory reservation vs actual usage
aws cloudwatch get-metric-statistics \
  --metric-name MemoryUtilization \
  --namespace AWS/ECS \
  --dimensions Name=ServiceName,Value=your-app-service \
  --start-time $(date -d '7 days ago' -u +%Y-%m-%dT%H:%M:%SZ) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) \
  --period 3600 \
  --statistics Average,Maximum
```

If average CPU < 30% and max CPU < 60%, consider downsizing task definition:

```json
{
  "cpu": "256",    // Down from 512
  "memory": "512" // Down from 1024
}
```

### Auto-Scaling Schedule for Predictable Load

```bash
# Scale down development/staging during off-hours
aws application-autoscaling put-scheduled-action \
  --service-namespace ecs \
  --scalable-dimension ecs:service:DesiredCount \
  --resource-id service/staging-cluster/your-app-service \
  --scheduled-action-name scale-down-night \
  --schedule "cron(0 22 * * ? *)" \
  --scalable-target-action MinCapacity=0,MaxCapacity=0

# Scale back up in the morning
aws application-autoscaling put-scheduled-action \
  --service-namespace ecs \
  --scalable-dimension ecs:service:DesiredCount \
  --resource-id service/staging-cluster/your-app-service \
  --scheduled-action-name scale-up-morning \
  --schedule "cron(0 7 * * ? *)" \
  --scalable-target-action MinCapacity=1,MaxCapacity=5
```

---

## Cost Alerts & Budgets

### Budget Setup

```bash
# Monthly overall budget
aws budgets create-budget \
  --account-id 123456789 \
  --budget '{
    "BudgetName": "Total-Monthly-Budget",
    "BudgetLimit": {"Amount": "1000", "Unit": "USD"},
    "TimeUnit": "MONTHLY",
    "BudgetType": "COST"
  }' \
  --notifications-with-subscribers '[
    {
      "Notification": {
        "NotificationType": "ACTUAL",
        "ComparisonOperator": "GREATER_THAN",
        "Threshold": 75,
        "ThresholdType": "PERCENTAGE"
      },
      "Subscribers": [
        {"SubscriptionType": "EMAIL", "Address": "engineering@yourdomain.com"},
        {"SubscriptionType": "SNS", "Address": "arn:aws:sns:us-east-1:123456789:cost-alerts"}
      ]
    },
    {
      "Notification": {
        "NotificationType": "FORECASTED",
        "ComparisonOperator": "GREATER_THAN",
        "Threshold": 100,
        "ThresholdType": "PERCENTAGE"
      },
      "Subscribers": [
        {"SubscriptionType": "EMAIL", "Address": "engineering@yourdomain.com"}
      ]
    }
  ]'

# Per-service budget (e.g., EC2 only)
aws budgets create-budget \
  --account-id 123456789 \
  --budget '{
    "BudgetName": "EC2-Monthly-Budget",
    "BudgetLimit": {"Amount": "400", "Unit": "USD"},
    "TimeUnit": "MONTHLY",
    "BudgetType": "COST",
    "CostFilters": {
      "Service": ["Amazon Elastic Compute Cloud - Compute"]
    }
  }'
```

### AWS Cost Anomaly Detection

```bash
# Create anomaly monitor
aws ce create-anomaly-monitor \
  --anomaly-monitor '{
    "MonitorName": "AllServices",
    "MonitorType": "DIMENSIONAL",
    "MonitorDimension": "SERVICE"
  }'

# Create anomaly subscription (alert when cost anomaly detected)
aws ce create-anomaly-subscription \
  --anomaly-subscription '{
    "SubscriptionName": "cost-anomaly-alerts",
    "MonitorArnList": ["arn:aws:ce::123456789:anomalymonitor/xxx"],
    "Subscribers": [
      {
        "Address": "arn:aws:sns:us-east-1:123456789:cost-alerts",
        "Type": "SNS"
      }
    ],
    "Threshold": 20,
    "Frequency": "DAILY"
  }'
```

---

## Monthly Cost Review Process

### Review Checklist

Run on the first Monday of each month:

- [ ] Review AWS Cost Explorer for previous month totals
- [ ] Compare to budget and previous month
- [ ] Check RI utilization (should be > 90%)
- [ ] Check Savings Plan coverage (should be > 80%)
- [ ] Identify top 5 cost drivers
- [ ] Review untagged resources (cost leakage)
- [ ] Check for orphaned resources:
  ```bash
  # Unattached Elastic IPs (~$3.60/month each)
  aws ec2 describe-addresses \
    --query 'Addresses[?AssociationId==null].[PublicIp,AllocationId]' \
    --output table

  # Unused NAT Gateways
  aws ec2 describe-nat-gateways \
    --filter Name=state,Values=available \
    --query 'NatGateways[*].[NatGatewayId,State,CreateTime]' \
    --output table

  # Old snapshots
  aws ec2 describe-snapshots \
    --owner-ids self \
    --query 'Snapshots[?StartTime<`2024-01-01`].[SnapshotId,StartTime,VolumeSize]' \
    --output table
  ```
- [ ] Update cost report for stakeholders
- [ ] Plan optimization actions for next month

---

## Related Documentation

- [Deployment Guide](./DEPLOYMENT_GUIDE.md)
- [Scaling Strategy](./SCALING.md)
- [Operations Runbook](./OPERATIONS.md)
