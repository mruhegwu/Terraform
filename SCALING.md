# Scaling Strategy

Comprehensive guide for horizontal and vertical scaling of TypeScript applications and AWS infrastructure.

---

## Table of Contents

1. [Overview](#overview)
2. [Horizontal Scaling](#horizontal-scaling)
3. [Vertical Scaling](#vertical-scaling)
4. [Database Scaling](#database-scaling)
5. [Caching Strategies](#caching-strategies)
6. [CDN Optimization](#cdn-optimization)
7. [API Rate Limiting](#api-rate-limiting)
8. [Load Balancing Strategies](#load-balancing-strategies)

---

## Overview

### Scaling Architecture

```
Traffic Load
     │
     ▼
CloudFront (CDN) ──► S3 (Static Content, ~∞ scale)
     │
     ▼
Route 53 (DNS-level load balancing)
     │
     ▼
Application Load Balancer
     │
     ▼
ECS Service (Auto-scaled, 2-20 tasks)
     │
     ├──► ElastiCache Redis (Cluster mode, 1-6 shards)
     │
     └──► RDS PostgreSQL (Multi-AZ + Read Replicas)
```

### Scaling Decision Matrix

| Traffic Level    | Users/Day | Tasks | DB Instance  | Cache Nodes | CDN Cache Hit |
|------------------|-----------|-------|--------------|-------------|---------------|
| Small            | <1K       | 2     | db.t3.medium | 1x cache.t3 | N/A           |
| Medium           | 1K-10K    | 4     | db.t3.large  | 2x cache.t3 | 70%+          |
| Large            | 10K-100K  | 8-12  | db.r6g.large | 3x cache.r6 | 85%+          |
| Very Large       | 100K+     | 20+   | db.r6g.2xlarge + replicas | Cluster mode | 95%+ |

---

## Horizontal Scaling

### ECS Auto-Scaling Configuration

```hcl
# terraform/modules/ecs/autoscaling.tf

# Register scalable target
resource "aws_appautoscaling_target" "ecs_service" {
  max_capacity       = 20
  min_capacity       = 2
  resource_id        = "service/${aws_ecs_cluster.main.name}/${aws_ecs_service.app.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

# CPU-based scaling (scale out at 70%, scale in at 40%)
resource "aws_appautoscaling_policy" "cpu" {
  name               = "${var.app_name}-cpu-scaling"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.ecs_service.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs_service.scalable_dimension
  service_namespace  = aws_appautoscaling_target.ecs_service.service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
    target_value       = 70.0
    scale_in_cooldown  = 300  # 5 minutes before scaling in
    scale_out_cooldown = 60   # 1 minute before scaling out
  }
}

# Memory-based scaling
resource "aws_appautoscaling_policy" "memory" {
  name               = "${var.app_name}-memory-scaling"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.ecs_service.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs_service.scalable_dimension
  service_namespace  = aws_appautoscaling_target.ecs_service.service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageMemoryUtilization"
    }
    target_value       = 80.0
    scale_in_cooldown  = 300
    scale_out_cooldown = 60
  }
}

# Request-count-based scaling (ALB requests per target)
resource "aws_appautoscaling_policy" "requests" {
  name               = "${var.app_name}-request-scaling"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.ecs_service.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs_service.scalable_dimension
  service_namespace  = aws_appautoscaling_target.ecs_service.service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ALBRequestCountPerTarget"
      resource_label         = "${aws_lb.main.arn_suffix}/${aws_lb_target_group.app.arn_suffix}"
    }
    target_value       = 500  # 500 requests per task per minute
    scale_in_cooldown  = 300
    scale_out_cooldown = 60
  }
}
```

### Scheduled Scaling for Predictable Patterns

```hcl
# Scale up before expected traffic spike (e.g., business hours)
resource "aws_appautoscaling_scheduled_action" "scale_up" {
  name               = "${var.app_name}-scale-up-morning"
  service_namespace  = "ecs"
  resource_id        = "service/${aws_ecs_cluster.main.name}/${aws_ecs_service.app.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  schedule           = "cron(0 8 * * ? *)"  # 8 AM UTC

  scalable_target_action {
    min_capacity = 4
    max_capacity = 20
  }
}

# Scale down overnight
resource "aws_appautoscaling_scheduled_action" "scale_down" {
  name               = "${var.app_name}-scale-down-night"
  service_namespace  = "ecs"
  resource_id        = "service/${aws_ecs_cluster.main.name}/${aws_ecs_service.app.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  schedule           = "cron(0 22 * * ? *)"  # 10 PM UTC

  scalable_target_action {
    min_capacity = 2
    max_capacity = 10
  }
}
```

### Manual Scaling Procedures

```bash
# Immediate scale out (emergency)
aws ecs update-service \
  --cluster production-cluster \
  --service your-app-service \
  --desired-count 10

# Check scaling activity
aws application-autoscaling describe-scaling-activities \
  --service-namespace ecs \
  --resource-id service/production-cluster/your-app-service \
  --max-results 20 \
  --output table
```

---

## Vertical Scaling

### ECS Task Resource Adjustment

Modify task definition to change CPU/memory allocation:

```bash
# Current task definition
aws ecs describe-task-definition \
  --task-definition your-app:latest \
  --query 'taskDefinition.{CPU:cpu,Memory:memory}'

# Register new task definition with more resources
aws ecs register-task-definition \
  --cli-input-json '{
    "family": "your-app",
    "cpu": "1024",
    "memory": "2048",
    "containerDefinitions": [...]
  }'

# Deploy new task definition
aws ecs update-service \
  --cluster production-cluster \
  --service your-app-service \
  --task-definition your-app:LATEST_REVISION
```

### ECS Task Size Reference

| vCPU | Memory | Use Case                           |
|------|--------|------------------------------------|
| 256  | 512 MB | Simple APIs, low traffic           |
| 512  | 1 GB   | Standard web applications          |
| 1024 | 2 GB   | Medium traffic, some computation   |
| 2048 | 4 GB   | High traffic, image processing     |
| 4096 | 8 GB   | Heavy computation, ML inference    |

### RDS Vertical Scaling

```bash
# Scale RDS instance type (requires restart or Multi-AZ failover)
aws rds modify-db-instance \
  --db-instance-identifier production-db \
  --db-instance-class db.r6g.xlarge \
  --apply-immediately  # or --no-apply-immediately for next maintenance window

# Monitor modification progress
aws rds describe-db-instances \
  --db-instance-identifier production-db \
  --query 'DBInstances[0].PendingModifiedValues'
```

---

## Database Scaling

### Read Replicas

```hcl
# terraform/modules/rds/replicas.tf
resource "aws_db_instance" "read_replica" {
  count = var.replica_count  # Start with 1, scale to 3+

  identifier             = "production-db-replica-${count.index + 1}"
  replicate_source_db    = aws_db_instance.primary.identifier
  instance_class         = var.replica_instance_class
  publicly_accessible    = false
  deletion_protection    = true
  skip_final_snapshot    = false

  # Performance Insights for replica monitoring
  performance_insights_enabled = true

  tags = {
    Name        = "production-db-replica-${count.index + 1}"
    Environment = var.environment
    Role        = "read-replica"
  }
}
```

### Application-Level Read/Write Splitting

```typescript
// src/database/connection.ts
import { Pool } from 'pg';

// Write pool: always uses primary
const writePool = new Pool({
  connectionString: process.env.DATABASE_URL,
  max: 10,
});

// Read pool: uses read replicas (load balanced via DNS)
const readPool = new Pool({
  connectionString: process.env.DATABASE_READ_URL,
  max: 20,  // More connections for reads
});

export const db = {
  // Use for INSERT, UPDATE, DELETE, and reads that need latest data
  write: (sql: string, values?: any[]) => writePool.query(sql, values),

  // Use for SELECT queries that can tolerate slight replication lag
  read: (sql: string, values?: any[]) => readPool.query(sql, values),
};

// Usage in service layer
class UserService {
  async getUser(id: string) {
    // Read from replica (acceptable 1-2 second lag)
    return db.read('SELECT * FROM users WHERE id = $1', [id]);
  }

  async createUser(data: CreateUserDTO) {
    // Write to primary
    const result = await db.write(
      'INSERT INTO users (email, name) VALUES ($1, $2) RETURNING *',
      [data.email, data.name]
    );
    return result.rows[0];
  }
}
```

### Database Connection Pooling at Scale

```bash
# Deploy RDS Proxy for connection pooling (handles 10,000+ connections)
aws rds create-db-proxy \
  --db-proxy-name production-db-proxy \
  --engine-family POSTGRESQL \
  --auth '[{
    "AuthScheme": "SECRETS",
    "SecretArn": "arn:aws:secretsmanager:us-east-1:123456789:secret:production/db",
    "IAMAuth": "DISABLED"
  }]' \
  --role-arn arn:aws:iam::123456789:role/rds-proxy-role \
  --vpc-subnet-ids subnet-xxx subnet-yyy \
  --vpc-security-group-ids sg-database \
  --require-tls

# Get proxy endpoint
aws rds describe-db-proxies \
  --db-proxy-name production-db-proxy \
  --query 'DBProxies[0].Endpoint'
```

---

## Caching Strategies

### Redis Caching Patterns

```typescript
// src/utils/cache.ts
import { Redis } from 'ioredis';

const redis = new Redis(process.env.REDIS_URL);

// Cache-aside pattern (most common)
export async function cachedQuery<T>(
  key: string,
  fetchFn: () => Promise<T>,
  ttlSeconds = 300
): Promise<T> {
  // Try cache first
  const cached = await redis.get(key);
  if (cached) {
    return JSON.parse(cached) as T;
  }

  // Cache miss: fetch from DB
  const data = await fetchFn();

  // Store in cache
  await redis.setex(key, ttlSeconds, JSON.stringify(data));

  return data;
}

// Usage
const user = await cachedQuery(
  `user:${userId}`,
  () => db.read('SELECT * FROM users WHERE id = $1', [userId]),
  600  // 10 minute TTL
);

// Cache invalidation on update
async function updateUser(userId: string, data: UpdateUserDTO) {
  await db.write('UPDATE users SET name = $1 WHERE id = $2', [data.name, userId]);

  // Invalidate cache
  await redis.del(`user:${userId}`);
}
```

### ElastiCache Redis Cluster Mode

```hcl
# terraform/modules/elasticache/cluster.tf
resource "aws_elasticache_replication_group" "redis" {
  replication_group_id       = "${var.environment}-redis-cluster"
  description                = "Redis cluster for ${var.app_name}"

  # Cluster mode enabled: allows horizontal sharding
  num_node_groups            = var.redis_shard_count  # Start with 1, scale to 6
  replicas_per_node_group    = 1  # 1 replica per shard for HA

  node_type                  = var.redis_node_type  # cache.r6g.large
  port                       = 6379

  # Security
  at_rest_encryption_enabled = true
  transit_encryption_enabled = true
  auth_token                 = var.redis_auth_token

  # Multi-AZ
  automatic_failover_enabled = true
  multi_az_enabled           = true

  subnet_group_name  = aws_elasticache_subnet_group.redis.name
  security_group_ids = [aws_security_group.redis.id]
}
```

---

## CDN Optimization

### CloudFront Caching Rules

```hcl
resource "aws_cloudfront_distribution" "app" {
  # Static assets: aggressively cached (1 year)
  ordered_cache_behavior {
    path_pattern     = "/static/*"
    target_origin_id = "S3-static-assets"

    cache_policy_id            = aws_cloudfront_cache_policy.long_lived.id
    origin_request_policy_id   = data.aws_cloudfront_origin_request_policy.none.id
    response_headers_policy_id = aws_cloudfront_response_headers_policy.security.id

    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    viewer_protocol_policy = "redirect-to-https"
    compress               = true
  }

  # API responses: short TTL or no cache
  ordered_cache_behavior {
    path_pattern     = "/api/*"
    target_origin_id = "ALB-api"

    cache_policy_id          = data.aws_cloudfront_cache_policy.caching_disabled.id
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer.id

    allowed_methods        = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods         = ["GET", "HEAD"]
    viewer_protocol_policy = "redirect-to-https"
  }
}

resource "aws_cloudfront_cache_policy" "long_lived" {
  name    = "long-lived-cache-policy"
  min_ttl = 86400       # 1 day
  default_ttl = 31536000 # 1 year
  max_ttl = 31536000

  parameters_in_cache_key_and_forwarded_to_origin {
    cookies_config { cookie_behavior = "none" }
    headers_config  { header_behavior = "none" }
    query_strings_config { query_string_behavior = "none" }
    enable_accept_encoding_brotli = true
    enable_accept_encoding_gzip   = true
  }
}
```

### Cache Busting Strategy

```typescript
// webpack.config.ts or vite.config.ts
export default defineConfig({
  build: {
    rollupOptions: {
      output: {
        // Content hash in filename for cache busting
        entryFileNames: 'assets/[name]-[hash].js',
        chunkFileNames: 'assets/[name]-[hash].js',
        assetFileNames: 'assets/[name]-[hash].[ext]',
      },
    },
  },
});
```

---

## API Rate Limiting

### Per-User Rate Limiting with Redis

```typescript
// src/middleware/rateLimiter.ts
import { Redis } from 'ioredis';
import { Request, Response, NextFunction } from 'express';

const redis = new Redis(process.env.REDIS_URL);

interface RateLimitConfig {
  windowMs: number;   // Time window in milliseconds
  max: number;        // Max requests per window
  keyFn: (req: Request) => string;  // Key extraction function
}

export function rateLimit(config: RateLimitConfig) {
  return async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const key = `rl:${config.keyFn(req)}`;
    const windowSecs = Math.ceil(config.windowMs / 1000);

    const pipeline = redis.pipeline();
    pipeline.incr(key);
    pipeline.expire(key, windowSecs);
    const results = await pipeline.exec();

    const count = results?.[0]?.[1] as number;

    res.setHeader('X-RateLimit-Limit', config.max);
    res.setHeader('X-RateLimit-Remaining', Math.max(0, config.max - count));
    res.setHeader('X-RateLimit-Reset', Math.ceil(Date.now() / 1000) + windowSecs);

    if (count > config.max) {
      res.status(429).json({
        error: 'Rate limit exceeded',
        retryAfter: windowSecs,
      });
      return;
    }

    next();
  };
}

// Usage: Different limits for different tiers
app.use('/api/', rateLimit({
  windowMs: 60 * 1000,
  max: 60,
  keyFn: (req) => req.ip || 'unknown',
}));

app.use('/api/', rateLimit({
  windowMs: 60 * 1000,
  max: 300,  // Higher limit for authenticated users
  keyFn: (req) => (req as any).user?.id || req.ip || 'unknown',
}));
```

---

## Load Balancing Strategies

### ALB Configuration

```hcl
# terraform/modules/alb/main.tf
resource "aws_lb" "main" {
  name               = "${var.app_name}-alb"
  internal           = false
  load_balancer_type = "application"
  subnets            = var.public_subnet_ids
  security_groups    = [aws_security_group.alb.id]

  # Enable deletion protection in production
  enable_deletion_protection = var.environment == "production"

  # Enable access logs
  access_logs {
    bucket  = aws_s3_bucket.alb_logs.id
    prefix  = "alb-access-logs"
    enabled = true
  }

  # Cross-zone load balancing (enabled by default for ALB)
  enable_cross_zone_load_balancing = true
}

# Target group with sticky sessions for session-based apps
resource "aws_lb_target_group" "app" {
  name     = "${var.app_name}-tg"
  port     = var.app_port
  protocol = "HTTP"
  vpc_id   = var.vpc_id

  target_type = "ip"  # Required for Fargate

  health_check {
    enabled             = true
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 10
    interval            = 30
    path                = "/health"
    matcher             = "200"
  }

  # Load balancing algorithm
  load_balancing_algorithm_type = "least_outstanding_requests"  # Better than round-robin for variable request times

  # Stickiness (if needed for stateful sessions)
  stickiness {
    type            = "lb_cookie"
    cookie_duration = 86400  # 1 day
    enabled         = false  # Only enable if truly needed
  }

  deregistration_delay = 30  # Seconds to wait before removing unhealthy target
}
```

### Multi-App Routing

```hcl
# Route different paths to different services
resource "aws_lb_listener_rule" "app1" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 100

  condition {
    path_pattern { values = ["/app1/*"] }
  }

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app1.arn
  }
}

resource "aws_lb_listener_rule" "app2" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 200

  condition {
    host_header { values = ["app2.yourdomain.com"] }
  }

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app2.arn
  }
}
```

### Load Testing

```bash
# Install k6 for load testing
brew install k6

# Run load test
k6 run tests/load/api-test.js
```

```javascript
// tests/load/api-test.js
import http from 'k6/http';
import { check, sleep } from 'k6';

export const options = {
  stages: [
    { duration: '2m', target: 100 },   // Ramp up to 100 users
    { duration: '5m', target: 100 },   // Stay at 100 users
    { duration: '2m', target: 500 },   // Spike to 500 users
    { duration: '5m', target: 500 },   // Stay at 500 users
    { duration: '2m', target: 0 },     // Ramp down
  ],
  thresholds: {
    http_req_duration: ['p(99)<1000'],  // 99% of requests < 1s
    http_req_failed: ['rate<0.01'],     // Error rate < 1%
  },
};

export default function () {
  const response = http.get(`${__ENV.BASE_URL}/api/health`);

  check(response, {
    'status is 200': (r) => r.status === 200,
    'response time < 500ms': (r) => r.timings.duration < 500,
  });

  sleep(1);
}
```

---

## Related Documentation

- [Deployment Guide](./DEPLOYMENT_GUIDE.md)
- [Monitoring & Observability Guide](./MONITORING.md)
- [Cost Optimization Guide](./COST_OPTIMIZATION.md)
- [Operations Runbook](./OPERATIONS.md)
