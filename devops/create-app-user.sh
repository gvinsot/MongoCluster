#!/bin/bash

# ============================================================================
# Create MongoDB Application User
# ============================================================================
# Usage: ./create-app-user.sh <database> <username> <password> [role]
#
# Examples:
#   ./create-app-user.sh myapp appuser secretpass
#   ./create-app-user.sh myapp appuser secretpass readWrite
#   ./create-app-user.sh myapp readonly_user secretpass read
# ============================================================================

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Load .env file if it exists (for admin credentials)
if [ -f "$(dirname "$0")/../.env" ]; then
    source "$(dirname "$0")/../.env"
elif [ -f "$(dirname "$0")/.env" ]; then
    source "$(dirname "$0")/.env"
elif [ -f ".env" ]; then
    source ".env"
fi

# Admin credentials for authentication
MONGO_ADMIN_USER="${MONGO_ADMIN_USER:-admin}"
MONGO_ADMIN_PASSWORD="${MONGO_ADMIN_PASSWORD:-admin123}"

# Parse arguments
DATABASE="$1"
USERNAME="$2"
PASSWORD="$3"
ROLE="${4:-readWrite}"

# Validate arguments
if [ -z "$DATABASE" ] || [ -z "$USERNAME" ] || [ -z "$PASSWORD" ]; then
    echo -e "${RED}Error: Missing required arguments${NC}"
    echo ""
    echo "Usage: $0 <database> <username> <password> [role]"
    echo ""
    echo "Arguments:"
    echo "  database    The MongoDB database name"
    echo "  username    The username to create"
    echo "  password    The password for the user"
    echo "  role        Optional role (default: readWrite)"
    echo ""
    echo "Available roles:"
    echo "  read        Read-only access"
    echo "  readWrite   Read and write access (default)"
    echo "  dbAdmin     Database administration"
    echo "  dbOwner     Full database control"
    echo ""
    echo "Examples:"
    echo "  $0 myapp appuser mypassword"
    echo "  $0 analytics reader readpass read"
    exit 1
fi

# Find the primary container
PRIMARY_CONTAINER=$(docker ps -qf "name=mongocluster_mongo-primary" 2>/dev/null | head -1)

if [ -z "$PRIMARY_CONTAINER" ]; then
    echo -e "${RED}Error: MongoDB primary container not found${NC}"
    echo "Make sure the MongoDB cluster is running."
    exit 1
fi

echo -e "${BLUE}Creating user '${USERNAME}' on database '${DATABASE}'...${NC}"

# Create the user
docker exec "$PRIMARY_CONTAINER" mongosh \
    --quiet \
    -u "$MONGO_ADMIN_USER" \
    -p "$MONGO_ADMIN_PASSWORD" \
    --authenticationDatabase admin \
    --eval "
        db = db.getSiblingDB('${DATABASE}');
        try {
            db.createUser({
                user: '${USERNAME}',
                pwd: '${PASSWORD}',
                roles: [
                    { role: '${ROLE}', db: '${DATABASE}' }
                ]
            });
            print('SUCCESS');
        } catch(e) {
            if (e.code === 51003) {
                print('EXISTS');
            } else {
                print('ERROR: ' + e.message);
            }
        }
    " 2>/dev/null

RESULT=$(docker exec "$PRIMARY_CONTAINER" mongosh \
    --quiet \
    -u "$MONGO_ADMIN_USER" \
    -p "$MONGO_ADMIN_PASSWORD" \
    --authenticationDatabase admin \
    --eval "
        db = db.getSiblingDB('${DATABASE}');
        try {
            db.createUser({
                user: '${USERNAME}',
                pwd: '${PASSWORD}',
                roles: [
                    { role: '${ROLE}', db: '${DATABASE}' }
                ]
            });
            print('SUCCESS');
        } catch(e) {
            if (e.code === 51003) {
                print('EXISTS');
            } else {
                print('ERROR: ' + e.message);
            }
        }
    " 2>&1)

if echo "$RESULT" | grep -q "SUCCESS"; then
    echo -e "${GREEN}User created successfully!${NC}"
    echo ""
    echo "User details:"
    echo "  Database: ${DATABASE}"
    echo "  Username: ${USERNAME}"
    echo "  Role:     ${ROLE}"
    echo ""
    echo "Connection string:"
    echo -e "  ${GREEN}mongodb://${USERNAME}:${PASSWORD}@mongo-primary:27017,mongo-secondary1:27017,mongo-secondary2:27017/${DATABASE}?replicaSet=rs0&authSource=${DATABASE}${NC}"
    echo ""
elif echo "$RESULT" | grep -q "EXISTS"; then
    echo -e "${YELLOW}User '${USERNAME}' already exists on database '${DATABASE}'${NC}"
    echo ""
    echo "Connection string:"
    echo -e "  mongodb://${USERNAME}:<password>@mongo-primary:27017,mongo-secondary1:27017,mongo-secondary2:27017/${DATABASE}?replicaSet=rs0&authSource=${DATABASE}"
    echo ""
else
    echo -e "${RED}Failed to create user${NC}"
    echo "$RESULT"
    exit 1
fi
