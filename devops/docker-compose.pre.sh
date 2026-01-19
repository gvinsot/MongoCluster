

# Check for required nodes
REQUIRED_NODES="server-b server-c server-d"
MISSING_NODES=""
for node in $REQUIRED_NODES; do
    if ! docker node ls --format "{{.Hostname}}" | grep -q "^${node}$"; then
        MISSING_NODES="$MISSING_NODES $node"
    fi
done

if [ -n "$MISSING_NODES" ]; then
    echo -e "${YELLOW}Warning: Missing nodes:${MISSING_NODES}${NC}"
    echo "Services will fail to start on missing nodes."
    echo ""
fi


echo -e "${BLUE}Setting up MongoDB keyfile for replica set authentication...${NC}"

if ! docker config ls | grep -q "mongo_keyfile"; then
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