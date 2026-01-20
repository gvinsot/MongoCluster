#!/bin/bash

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Load .env file if it exists
if [ -f "$(dirname "$0")/../.env" ]; then
    source "$(dirname "$0")/../.env"
elif [ -f "$(dirname "$0")/.env" ]; then
    source "$(dirname "$0")/.env"
elif [ -f ".env" ]; then
    source ".env"
fi

# Default credentials if not set in .env
MONGO_ADMIN_USER="${MONGO_ADMIN_USER:-admin}"
MONGO_ADMIN_PASSWORD="${MONGO_ADMIN_PASSWORD:-admin123}"

COMPOSE_FILE="$(dirname "$0")/docker-compose.swarm.yml"

# Check for required nodes
echo -e "${BLUE}Checking required nodes...${NC}"
REQUIRED_NODES="server-b server-c server-d"
MISSING_NODES=""
for node in $REQUIRED_NODES; do
    if ! docker node ls --format "{{.Hostname}}" 2>/dev/null | grep -q "^${node}$"; then
        MISSING_NODES="$MISSING_NODES $node"
    fi
done

if [ -n "$MISSING_NODES" ]; then
    echo -e "${YELLOW}Warning: Missing nodes:${MISSING_NODES}${NC}"
    echo "Services will fail to start on missing nodes."
    echo ""
fi

# Setup MongoDB keyfile for replica set authentication
echo -e "${BLUE}Setting up MongoDB keyfile for replica set authentication...${NC}"

if ! docker config ls 2>/dev/null | grep -q "mongo_keyfile"; then
    echo "Creating MongoDB keyfile..."
    # Generate random keyfile
    openssl rand -base64 756 > /tmp/mongo-keyfile
    chmod 400 /tmp/mongo-keyfile
    
    # Create Docker config
    docker config create mongo_keyfile /tmp/mongo-keyfile
    rm /tmp/mongo-keyfile
    echo -e "${GREEN}MongoDB keyfile created${NC}"
else
    echo "MongoDB keyfile already exists"
fi

# Function to check if authentication is currently disabled in compose file
is_auth_disabled() {
    grep -q 'command: \["mongod", "--replSet", "rs0", "--bind_ip_all"\]' "$COMPOSE_FILE" 2>/dev/null
    return $?
}

# Function to check if MongoDB is accessible without authentication
can_connect_without_auth() {
    docker exec $(docker ps -qf "name=mongocluster_mongo-primary" 2>/dev/null | head -1) \
        mongosh --quiet --eval "db.adminCommand('ping')" 2>/dev/null | grep -q "ok"
    return $?
}

# Function to check if admin user exists
admin_user_exists() {
    docker exec $(docker ps -qf "name=mongocluster_mongo-primary" 2>/dev/null | head -1) \
        mongosh --quiet --eval "db.getSiblingDB('admin').getUser('${MONGO_ADMIN_USER}')" 2>/dev/null | grep -q "${MONGO_ADMIN_USER}"
    return $?
}

# Function to check if replica set is initialized
is_replica_set_ready() {
    docker exec $(docker ps -qf "name=mongocluster_mongo-primary" 2>/dev/null | head -1) \
        mongosh --quiet --eval "rs.status().ok" 2>/dev/null | grep -q "1"
    return $?
}

# Function to enable authentication in compose file
enable_auth_in_compose() {
    echo -e "${BLUE}Enabling authentication in docker-compose.swarm.yml...${NC}"
    
    # Replace the no-auth command with the auth command for all mongo services
    sed -i 's|command: \["mongod", "--replSet", "rs0", "--bind_ip_all"\]|command: ["mongod", "--replSet", "rs0", "--bind_ip_all", "--keyFile", "/etc/mongo-keyfile"]|g' "$COMPOSE_FILE"
    
    # Comment out the old line marker if present
    sed -i 's|# Phase 1: Sans auth pour init. Phase 2: Décommenter --keyFile|# Authentication enabled|g' "$COMPOSE_FILE"
    
    echo -e "${GREEN}Authentication enabled in compose file${NC}"
}

# Main logic: Check if we need to setup authentication
echo ""
echo -e "${BLUE}Checking authentication status...${NC}"

# Check if primary container is running
PRIMARY_CONTAINER=$(docker ps -qf "name=mongocluster_mongo-primary" 2>/dev/null | head -1)

if [ -n "$PRIMARY_CONTAINER" ] && is_auth_disabled; then
    echo "MongoDB cluster is running without authentication"
    
    if is_replica_set_ready; then
        echo -e "${GREEN}Replica set is initialized and ready${NC}"
        
        if ! admin_user_exists; then
            echo ""
            echo -e "${BLUE}Creating MongoDB users...${NC}"
            
            # Create admin user only
            docker exec "$PRIMARY_CONTAINER" mongosh --quiet --eval "
                db = db.getSiblingDB('admin');
                try {
                    db.createUser({
                        user: '${MONGO_ADMIN_USER}',
                        pwd: '${MONGO_ADMIN_PASSWORD}',
                        roles: ['root']
                    });
                    print('Admin user created: ${MONGO_ADMIN_USER}');
                } catch(e) {
                    if (e.code === 51003) {
                        print('Admin user already exists');
                    } else {
                        print('Error creating admin user: ' + e.message);
                    }
                }
            "
            
            if [ $? -eq 0 ]; then
                echo -e "${GREEN}Admin user created successfully${NC}"
                
                # Enable authentication in compose file
                enable_auth_in_compose
                
                echo ""
                echo -e "${GREEN}=============================================${NC}"
                echo -e "${GREEN}Authentication setup complete!${NC}"
                echo -e "${GREEN}=============================================${NC}"
                echo ""
                echo "Admin credentials (from .env or defaults):"
                echo "  Admin user:       ${MONGO_ADMIN_USER}"
                echo "  Admin password:   ${MONGO_ADMIN_PASSWORD}"
                echo ""
                echo -e "${YELLOW}To create application users, run:${NC}"
                echo "  ./devops/create-app-user.sh <database> <username> <password>"
                echo ""
                echo -e "${YELLOW}The deployment will now continue with authentication enabled.${NC}"
            else
                echo -e "${RED}Failed to create admin user${NC}"
            fi
        else
            echo "Admin user already exists, enabling authentication..."
            enable_auth_in_compose
        fi
    else
        echo -e "${YELLOW}Replica set not ready yet. Run deployment again after initialization.${NC}"
    fi
else
    if [ -z "$PRIMARY_CONTAINER" ]; then
        echo "MongoDB cluster not running yet (first deployment)"
    else
        echo "Authentication is already enabled"
    fi
fi

echo ""
echo -e "${GREEN}Pre-deployment checks complete${NC}"
