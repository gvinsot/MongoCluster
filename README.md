# MongoCluster

A MongoDB Replica Set for Docker Swarm. This document explains how to **connect your services** to the cluster.

> For deployment and management instructions, see [MANAGE.md](MANAGE.md).

## Naming Conventions

### Database Names

Use the format: `<project>_<environment>`

| Environment | Example |
|-------------|---------|
| Development | `myapp_dev` |
| Staging | `myapp_staging` |
| Production | `myapp_prod` |
| Testing | `myapp_test` |

**Rules:**
- Use lowercase letters, numbers, and underscores only
- Start with the project name
- End with the environment suffix
- Maximum 64 characters

### Collection Names

Use the format: `<entity>` (singular or plural, be consistent)

| Good ✅ | Bad ❌ |
|---------|--------|
| `users` | `Users` |
| `order_items` | `OrderItems` |
| `audit_logs` | `audit-logs` |

**Rules:**
- Use lowercase with underscores (snake_case)
- No hyphens, spaces, or special characters
- Be consistent: either all singular or all plural
- Prefix with module name for large projects: `auth_users`, `billing_invoices`

### User Names

Use the format: `<project>_<environment>_<role>`

| Example | Description |
|---------|-------------|
| `myapp_prod_app` | Production application user |
| `myapp_dev_app` | Development application user |
| `myapp_prod_readonly` | Read-only user for reporting |

### Examples

```bash
# Create users for different environments
./devops/create-app-user.sh myapp_dev devuser devpass123
./devops/create-app-user.sh myapp_staging staginguser stagingpass123
./devops/create-app-user.sh myapp_prod produser prodpass123!

# Create a read-only user for analytics
./devops/create-app-user.sh myapp_prod analytics_reader readpass read
```

## Quick Start

### 1. Add the Network

Your service must join the `mongocluster_internal` overlay network:

```yaml
services:
  your-service:
    image: your-image
    networks:
      - mongocluster_internal

networks:
  mongocluster_internal:
    external: true
```

### 2. Use the Connection String

Ask the cluster admin to create a user for your project:

```bash
# Admin runs this command
./devops/create-app-user.sh myapp appuser secretpass
```

Then use the credentials in your service:

```yaml
environment:
  - MONGODB_URI=mongodb://appuser:secretpass@mongo-primary:27017,mongo-secondary1:27017,mongo-secondary2:27017/myapp?replicaSet=rs0&authSource=myapp
```

## Connection Options

| Option | Description | Example |
|--------|-------------|---------|
| `replicaSet` | **Required.** Replica set name | `replicaSet=rs0` |
| `authSource` | Database for authentication | `authSource=myapp` |
| `readPreference` | Where to route reads | `readPreference=secondaryPreferred` |
| `w` | Write concern | `w=majority` |
| `retryWrites` | Auto-retry failed writes | `retryWrites=true` |
| `maxPoolSize` | Connection pool size | `maxPoolSize=50` |

### Production-Ready Connection String

```
mongodb://user:pass@mongo-primary:27017,mongo-secondary1:27017,mongo-secondary2:27017/mydb?replicaSet=rs0&authSource=mydb&readPreference=secondaryPreferred&w=majority&retryWrites=true
```

## Service Hostnames

| Hostname | Role | Description |
|----------|------|-------------|
| `mongo-primary` | Primary | Read/write operations |
| `mongo-secondary1` | Secondary | Read replica |
| `mongo-secondary2` | Secondary | Read replica |

## Read Preferences

| Value | Description |
|-------|-------------|
| `primary` | Always read from primary (default) |
| `primaryPreferred` | Read from primary, fallback to secondary |
| `secondary` | Always read from secondaries |
| `secondaryPreferred` | Read from secondary, fallback to primary |
| `nearest` | Read from the nearest node (lowest latency) |

## Testing Connection

Test from any container on the network:

```bash
docker run --rm --network mongocluster_internal mongo:8.2 \
  mongosh --host mongo-primary:27017 --eval "db.adminCommand('ping')"
```

## Ports

MongoDB uses port `27017` internally. No ports are exposed externally - all connections go through the Docker overlay network.
