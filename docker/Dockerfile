# =============================================================================
# Multi-stage Dockerfile for TypeScript Applications
# =============================================================================

# --- Stage 1: Base dependencies ---
FROM node:18-alpine AS base

# Install security updates and required packages
RUN apk update && apk upgrade && apk add --no-cache \
    dumb-init \
    curl \
  && rm -rf /var/cache/apk/*

# Create non-root user for security
RUN addgroup -g 1001 -S nodejs \
  && adduser -S appuser -u 1001 -G nodejs

WORKDIR /app

# --- Stage 2: Development dependencies ---
FROM base AS deps

# Copy package files
COPY package.json package-lock.json* ./

# Install all dependencies (including dev)
RUN npm ci --include=dev

# --- Stage 3: Build the application ---
FROM deps AS builder

# Copy source code
COPY --chown=nodejs:nodejs . .

# Build TypeScript application
RUN npm run build

# --- Stage 4: Production dependencies only ---
FROM base AS prod-deps

COPY package.json package-lock.json* ./

# Install only production dependencies
RUN npm ci --omit=dev \
  && npm cache clean --force

# --- Stage 5: Production image (minimal, secure) ---
FROM base AS production

# Set production environment
ENV NODE_ENV=production \
    PORT=3000 \
    # Optimize Node.js for production
    NODE_OPTIONS="--max-old-space-size=512"

# Copy production node_modules from prod-deps stage
COPY --from=prod-deps --chown=appuser:nodejs /app/node_modules ./node_modules

# Copy built application from builder stage
COPY --from=builder --chown=appuser:nodejs /app/dist ./dist

# Copy only necessary config files
COPY --chown=appuser:nodejs package.json ./

# Switch to non-root user
USER appuser

# Expose application port
EXPOSE 3000

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
  CMD curl -f http://localhost:3000/health || exit 1

# Use dumb-init to handle PID 1 signals properly
ENTRYPOINT ["/usr/bin/dumb-init", "--"]

# Start the application
CMD ["node", "dist/index.js"]

# --- Stage 6: Development image (with hot-reload) ---
FROM deps AS development

ENV NODE_ENV=development \
    PORT=3000

COPY --chown=nodejs:nodejs . .

USER appuser

EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=10s --start-period=10s --retries=3 \
  CMD curl -f http://localhost:3000/health || exit 1

ENTRYPOINT ["/usr/bin/dumb-init", "--"]
CMD ["npm", "run", "dev"]
