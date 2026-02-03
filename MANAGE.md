# MongoCluster Management

This document covers the **deployment, architecture, and management** of the MongoDB replica set.

> For connection instructions, see [README.md](README.md).

## Architecture

```
┌─────────────┐    ┌─────────────────┐    ┌─────────────────┐
│   server-b  │    │    server-c     │    │    server-d     │
│   PRIMARY   │◄──►│   SECONDARY 1   │◄──►│   SECONDARY 2   │
│  mongo:8.2  │    │    mongo:8.2    │    │    mongo:8.2    │
└─────────────┘    └─────────────────┘    └─────────────────┘
       │                   │                       │
       └───────────────────┴───────────────────────┘
                    Replica Set: rs0
                Network: mongocluster_internal
```

| Component | Node | Description |
|-----------|------|-------------|
| mongo-primary | server-b | Primary node (read/write) |
| mongo-secondary1 | server-c | Secondary replica |
| mongo-secondary2 | server-d | Secondary replica |
| mongo-init | server-a | Initialization container (runs once) |
| mongo-express | any manager | Web admin UI |

## Prerequisites

- Docker Swarm initialized with nodes: `server-a`, `server-b`, `server-c`, `server-d`
- `mongo:8.2` image pulled on `server-b`, `server-c`, `server-d`
- Overlay network connectivity between all nodes


## Environment Variables

Create a `.env` file in the project root:

```bash
# MongoDB Admin User (root access)
MONGO_ADMIN_USER=admin
MONGO_ADMIN_PASSWORD=ChangeThisSecurePassword123!

# Mongo Express UI
MONGO_EXPRESS_USER=admin
MONGO_EXPRESS_PASSWORD=expresspass789!
```

| Variable | Description | Default |
|----------|-------------|---------|
| `MONGO_ADMIN_USER` | Admin username | `admin` |
| `MONGO_ADMIN_PASSWORD` | Admin password | `admin123` |
| `MONGO_EXPRESS_USER` | Mongo Express UI username | `gildas` |
| `MONGO_EXPRESS_PASSWORD` | Mongo Express UI password | `admin123` |

## Deployment (Two-Phase Process)

### Phase 1: Initial Deployment

The first deployment starts the cluster **without authentication** to allow replica set initialization.

```bash
# Deploy the stack
docker stack deploy -c devops/docker-compose.swarm.yml mongocluster

# Watch the initialization
docker service logs -f mongocluster_mongo-init
# Wait until you see "Replica set initialized"
# Then press Ctrl+C
```

### Phase 2: Enable Authentication

The second deployment automatically:
1. Detects the running cluster without auth
2. Creates admin and application users from `.env`
3. Modifies the compose file to enable `--keyFile`
4. Redeploys with authentication enabled

```bash
# Run deployment again
docker stack deploy -c devops/docker-compose.swarm.yml mongocluster
```

The `pre.sh` script will output the connection string with credentials.

### Verify Deployment

```bash
# Check all services are running
docker stack services mongocluster

# Expected output:
# NAME                            REPLICAS   IMAGE
# mongocluster_mongo-primary      1/1        mongo:8.2
# mongocluster_mongo-secondary1   1/1        mongo:8.2
# mongocluster_mongo-secondary2   1/1        mongo:8.2
# mongocluster_mongo-init         1/1        mongo:8.2
# mongocluster_mongo-express      1/1        mongo-express:...

# Check replica set status
docker exec -it $(docker ps -qf "name=mongo-primary") mongosh --eval "rs.status()"
```

## Authentication

### How It Works

1. MongoDB instances use a shared **keyFile** for internal authentication between replica set members
2. The keyFile is stored as a Docker config (`mongo_keyfile`)
3. User credentials are stored in the `admin` database

### Admin User

The admin user is created automatically on the second deployment:

| User | Database | Role | Source |
|------|----------|------|--------|
| `admin` | admin | root | `MONGO_ADMIN_USER` / `MONGO_ADMIN_PASSWORD` from `.env` |

### Create Application Users

Use the dedicated script to create users for each project:

```bash
./devops/create-app-user.sh <database> <username> <password> [role]
```

**Examples:**

```bash
# Create a read/write user for "myapp" database
./devops/create-app-user.sh myapp appuser secretpassword

# Create a read-only user for analytics
./devops/create-app-user.sh analytics reader readpass read

# Create a database admin
./devops/create-app-user.sh myapp dbadmin adminpass dbAdmin
```

**Available roles:**

| Role | Description |
|------|-------------|
| `read` | Read-only access |
| `readWrite` | Read and write access (default) |
| `dbAdmin` | Database administration |
| `dbOwner` | Full database control |

The script outputs the connection string for the created user.

### Manual User Creation

Alternatively, connect to MongoDB directly:

```bash
docker exec -it $(docker ps -qf "name=mongo-primary") mongosh -u admin -p --authenticationDatabase admin
```

```javascript
use myproject
db.createUser({
  user: "projectuser",
  pwd: "projectpassword",
  roles: [{ role: "readWrite", db: "myproject" }]
})
```

## Mongo Express (Admin UI)

A web-based MongoDB admin interface is included.

| Setting | Value |
|---------|-------|
| URL | https://mongo.methodinfo.fr |
| Access | Local IPs only (192.168.x.x, 10.x.x.x, 172.16-31.x.x) |
| Credentials | From `MONGO_EXPRESS_USER` and `MONGO_EXPRESS_PASSWORD` |

### Security

The UI is protected by:
1. Basic authentication (username/password)
2. IP whitelist (local networks only)
3. HTTPS via Traefik

## Data Persistence

Data is stored in Docker volumes on each node:

| Volume | Node | Container Path |
|--------|------|----------------|
| `mongocluster_mongo_primary_data` | server-b | /data/db |
| `mongocluster_mongo_secondary1_data` | server-c | /data/db |
| `mongocluster_mongo_secondary2_data` | server-d | /data/db |

### Backup

```bash
# Backup from primary
docker exec $(docker ps -qf "name=mongo-primary") \
  mongodump --archive --gzip > backup-$(date +%Y%m%d).archive

# With authentication
docker exec $(docker ps -qf "name=mongo-primary") \
  mongodump -u admin -p <password> --authenticationDatabase admin \
  --archive --gzip > backup-$(date +%Y%m%d).archive
```

### Restore

```bash
# Restore to primary
docker exec -i $(docker ps -qf "name=mongo-primary") \
  mongorestore --archive --gzip < backup-20240120.archive
```

## Logging Configuration

MongoDB instances are configured with reduced log verbosity to minimize unnecessary output:

- **Quiet mode**: `--quiet` flag reduces verbose logging
- **Diagnostic collection disabled**: `diagnosticDataCollectionDirectorySizeMB=0` prevents excessive diagnostic logs

This configuration reduces common logs such as:
- Client metadata connection logs (NETWORK component, log ID 51800)
- Diagnostic data collection messages
- Other verbose informational messages

To view service logs:

```bash
# View logs from primary
docker service logs mongocluster_mongo-primary

# View logs from a specific container
docker logs $(docker ps -qf "name=mongo-primary")
```

## Troubleshooting

### Service Won't Start

```bash
# Check detailed status
docker service ps mongocluster_mongo-primary --no-trunc

# Common issues:
# - "no suitable node" → Node constraint not met
# - "image not found" → Pull image on target node
# - "read-only file system" → Disk issue on node
```

### Image Not Found on Node

```bash
# SSH to the node and pull
docker pull mongo:8.2
```

### Replica Set Not Initialized

```bash
# Check init logs
docker service logs mongocluster_mongo-init

# Manual initialization
docker exec -it $(docker ps -qf "name=mongo-primary") mongosh --eval '
rs.initiate({
  _id: "rs0",
  members: [
    { _id: 0, host: "mongo-primary:27017", priority: 2 },
    { _id: 1, host: "mongo-secondary1:27017", priority: 1 },
    { _id: 2, host: "mongo-secondary2:27017", priority: 1 }
  ]
})'
```

### Authentication Errors

```bash
# Check if auth is enabled
docker service inspect mongocluster_mongo-primary \
  --format '{{.Spec.TaskTemplate.ContainerSpec.Command}}'

# Should include "--keyFile" if auth is enabled
```

### Network Issues

```bash
# Test connectivity from a container
docker run --rm --network mongocluster_internal mongo:8.2 \
  mongosh --host mongo-primary:27017 --eval "db.adminCommand('ping')"

# Check overlay network
docker network inspect mongocluster_internal
```

### Check Replica Set Health

```bash
# Full status
docker exec -it $(docker ps -qf "name=mongo-primary") mongosh --eval "rs.status()"

# Quick check
docker exec -it $(docker ps -qf "name=mongo-primary") mongosh --eval "rs.status().members.map(m => ({name: m.name, state: m.stateStr}))"
```

## Scaling and Maintenance

### Remove the Stack

```bash
docker stack rm mongocluster

# Wait for removal
sleep 15

# Verify
docker stack ps mongocluster
```

### Update MongoDB Version

1. Update the image tag in `docker-compose.swarm.yml`
2. Pull new image on all nodes
3. Redeploy the stack

```bash
# On each node
docker pull mongo:8.3

# Redeploy
docker stack deploy -c devops/docker-compose.swarm.yml mongocluster
```

### Force Restart a Service

```bash
docker service update --force mongocluster_mongo-primary
```

## Network Ports

| Port | Protocol | Purpose |
|------|----------|---------|
| 27017 | TCP | MongoDB (internal only) |
| 8081 | TCP | Mongo Express (via Traefik) |

No ports are exposed externally. All MongoDB access is through the overlay network.
