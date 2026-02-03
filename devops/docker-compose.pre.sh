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
    grep -q 'command: \["mongod", "--replSet", "rs0", "--bind_ip_all", "--quiet", "--setParameter", "diagnosticDataCollectionDirectorySizeMB=0"\]' "$COMPOSE_FILE" 2>/dev/null
    return $?
}

# Function to get the node where mongo-primary is running
get_primary_node() {
    docker service ps mongocluster_mongo-primary --filter "desired-state=running" --format "{{.Node}}" 2>/dev/null | head -1
}

# Function to check if mongo-primary service is running
is_service_running() {
    local replicas=$(docker service ls --filter "name=mongocluster_mongo-primary" --format "{{.Replicas}}" 2>/dev/null)
    [[ "$replicas" == "1/1" ]]
    return $?
}

# Function to execute mongosh command on the primary
# Uses a temporary container on the same network
exec_mongosh() {
    local eval_cmd="$1"
    docker run --rm --network mongocluster_internal mongo:8.2 \
        mongosh --host mongo-primary:27017 --quiet --eval "$eval_cmd" 2>/dev/null
}

# Function to execute mongosh command with auth
exec_mongosh_auth() {
    local eval_cmd="$1"
    docker run --rm --network mongocluster_internal mongo:8.2 \
        mongosh --host mongo-primary:27017 --quiet \
        -u "$MONGO_ADMIN_USER" -p "$MONGO_ADMIN_PASSWORD" --authenticationDatabase admin \
        --eval "$eval_cmd" 2>/dev/null
}

# Function to check if replica set is initialized
is_replica_set_ready() {
    local result=$(exec_mongosh "rs.status().ok")
    [[ "$result" == "1" ]]
    return $?
}

# Function to check if admin user exists
admin_user_exists() {
    local result=$(exec_mongosh "db.getSiblingDB('admin').getUser('${MONGO_ADMIN_USER}')")
    echo "$result" | grep -q "${MONGO_ADMIN_USER}"
    return $?
}

# Function to check if we can connect without auth
can_connect_without_auth() {
    local result=$(exec_mongosh "db.adminCommand('ping').ok")
    [[ "$result" == "1" ]]
    return $?
}

# Function to enable authentication in compose file
enable_auth_in_compose() {
    echo -e "${BLUE}Enabling authentication in docker-compose.swarm.yml...${NC}"
    
    # Replace the no-auth command with the auth command for all mongo services
    sed -i 's|command: \["mongod", "--replSet", "rs0", "--bind_ip_all", "--quiet", "--setParameter", "diagnosticDataCollectionDirectorySizeMB=0"\]|command: ["mongod", "--replSet", "rs0", "--bind_ip_all", "--keyFile", "/etc/mongo-keyfile", "--quiet", "--setParameter", "diagnosticDataCollectionDirectorySizeMB=0"]|g' "$COMPOSE_FILE"
    
    # Comment out the old line marker if present
    sed -i 's|# Phase 1: Sans auth pour init. Phase 2: Décommenter --keyFile|# Authentication enabled|g' "$COMPOSE_FILE"
    
    echo -e "${GREEN}Authentication enabled in compose file${NC}"
}

# Main logic: Check if we need to setup authentication
echo ""
echo -e "${BLUE}Checking authentication status...${NC}"

# Check if the service exists and is running
if is_service_running; then
    PRIMARY_NODE=$(get_primary_node)
    echo "MongoDB primary is running on node: ${PRIMARY_NODE}"
    
    # Check if auth is disabled in compose file
    if is_auth_disabled; then
        echo "Compose file has authentication disabled"
        
        # Check if we can connect to MongoDB
        if can_connect_without_auth; then
            echo -e "${GREEN}MongoDB is accessible without authentication${NC}"
            
            if is_replica_set_ready; then
                echo -e "${GREEN}Replica set is initialized and ready${NC}"
                
                if ! admin_user_exists; then
                    echo ""
                    echo -e "${BLUE}Creating MongoDB admin user...${NC}"
                    
                    # Create admin user
                    RESULT=$(exec_mongosh "
                        db = db.getSiblingDB('admin');
                        try {
                            db.createUser({
                                user: '${MONGO_ADMIN_USER}',
                                pwd: '${MONGO_ADMIN_PASSWORD}',
                                roles: ['root']
                            });
                            print('SUCCESS');
                        } catch(e) {
                            if (e.code === 51003) {
                                print('EXISTS');
                            } else {
                                print('ERROR: ' + e.message);
                            }
                        }
                    ")
                    
                    if echo "$RESULT" | grep -q "SUCCESS"; then
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
                    elif echo "$RESULT" | grep -q "EXISTS"; then
                        echo "Admin user already exists, enabling authentication..."
                        enable_auth_in_compose
                    else
                        echo -e "${RED}Failed to create admin user: $RESULT${NC}"
                    fi
                else
                    echo "Admin user already exists, enabling authentication..."
                    enable_auth_in_compose
                fi
            else
                echo -e "${YELLOW}Replica set not ready yet. Run deployment again after initialization.${NC}"
            fi
        else
            echo -e "${YELLOW}Cannot connect to MongoDB yet. Waiting for services to start.${NC}"
        fi
    else
        echo -e "${GREEN}Authentication is already enabled in compose file${NC}"
        
        # Verify we can connect with auth
        if exec_mongosh_auth "db.adminCommand('ping').ok" | grep -q "1"; then
            echo -e "${GREEN}MongoDB is accessible with authentication${NC}"
        fi
    fi
else
    # Check if the stack exists at all
    if docker service ls --filter "name=mongocluster" --format "{{.Name}}" 2>/dev/null | grep -q "mongocluster"; then
        echo -e "${YELLOW}MongoDB services exist but primary is not running (0/1 replicas)${NC}"
        echo "Check service status: docker service ps mongocluster_mongo-primary --no-trunc"
    else
        echo "MongoDB cluster not deployed yet (first deployment)"
    fi
fi

echo ""
echo -e "${GREEN}Pre-deployment checks complete${NC}"
