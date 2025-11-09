#!/bin/bash

# complete_aws_setup.sh - Complete AWS EC2 Automated Setup
# This script launches EC2, sets up everything, and provides access URLs

set +e

echo "🚀 Complete AWS EC2 Automated Setup"
echo "==================================="
echo ""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_header() {
    echo -e "${CYAN}========================================${NC}"
    echo -e "${CYAN}$1${NC}"
    echo -e "${CYAN}========================================${NC}"
}

# AWS Credentials - Load from environment or config file
# Option 1: Load from aws_credentials.env file (if exists)
if [ -f "aws_credentials.env" ]; then
    print_status "Loading AWS credentials from aws_credentials.env..."
    source aws_credentials.env
fi

# Option 2: Use environment variables (if set)
if [ -z "$AWS_ACCESS_KEY_ID" ] || [ -z "$AWS_SECRET_ACCESS_KEY" ]; then
    print_error "AWS credentials not found!"
    echo ""
    echo "Please provide AWS credentials in one of these ways:"
    echo ""
    echo "1. Create aws_credentials.env file:"
    echo "   cp aws_credentials.example.env aws_credentials.env"
    echo "   # Then edit aws_credentials.env with your credentials"
    echo ""
    echo "2. Set environment variables:"
    echo "   export AWS_ACCESS_KEY_ID=your-access-key"
    echo "   export AWS_SECRET_ACCESS_KEY=your-secret-key"
    echo "   export AWS_REGION=us-east-1"
    echo ""
    exit 1
fi

AWS_REGION="${AWS_REGION:-us-east-1}"  # Default to us-east-1 if not set

# Configuration
# Using t3.small (2GB RAM) - paid instance but affordable
# Cost: ~$0.0208/hour (~$15/month if running 24/7)
INSTANCE_TYPE="t3.small"  # 2GB RAM - sufficient for setup
AMI_NAME="ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"
KEY_PAIR_NAME="devops-pipeline-key"
SG_NAME="devops-pipeline-sg"
INSTANCE_NAME="devops-pipeline"

print_header "Step 1: Checking Prerequisites"

# Check AWS CLI
if ! command -v aws >/dev/null 2>&1; then
    print_error "AWS CLI not installed!"
    echo ""
    echo "Installing AWS CLI..."
    
    # macOS
    if [[ "$OSTYPE" == "darwin"* ]]; then
        if command -v brew >/dev/null 2>&1; then
            brew install awscli
        else
            print_error "Please install AWS CLI manually:"
            echo "  curl 'https://awscli.amazonaws.com/AWSCLIV2.pkg' -o 'AWSCLIV2.pkg'"
            echo "  sudo installer -pkg AWSCLIV2.pkg -target /"
            exit 1
        fi
    else
        # Linux
        curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
        unzip awscliv2.zip
        sudo ./aws/install
    fi
fi

print_success "AWS CLI is installed"

# Configure AWS CLI
print_status "Configuring AWS CLI..."
export AWS_ACCESS_KEY_ID
export AWS_SECRET_ACCESS_KEY
export AWS_DEFAULT_REGION=$AWS_REGION

aws configure set aws_access_key_id "$AWS_ACCESS_KEY_ID"
aws configure set aws_secret_access_key "$AWS_SECRET_ACCESS"
aws configure set default.region "$AWS_REGION"
aws configure set output json

# Verify AWS credentials
print_status "Verifying AWS credentials..."
if aws sts get-caller-identity >/dev/null 2>&1; then
    ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
    print_success "AWS credentials verified! Account: $ACCOUNT_ID"
else
    print_error "Invalid AWS credentials!"
    exit 1
fi

print_header "Step 2: Setting Up Security Group"

# Get or create VPC
print_status "Finding default VPC..."
VPC_ID=$(aws ec2 describe-vpcs --filters "Name=isDefault,Values=true" --query 'Vpcs[0].VpcId' --output text 2>/dev/null)

if [ -z "$VPC_ID" ] || [ "$VPC_ID" = "None" ]; then
    print_error "No default VPC found!"
    print_status "Please create a VPC or specify VPC ID"
    exit 1
fi

print_success "Found VPC: $VPC_ID"

# Check if security group exists
SG_ID=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=$SG_NAME" "Name=vpc-id,Values=$VPC_ID" --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)

if [ -z "$SG_ID" ] || [ "$SG_ID" = "None" ]; then
    print_status "Creating security group..."
    SG_ID=$(aws ec2 create-security-group \
        --group-name "$SG_NAME" \
        --description "DevOps Pipeline Security Group - Auto-created" \
        --vpc-id "$VPC_ID" \
        --query 'GroupId' \
        --output text 2>/dev/null)
    
    if [ -z "$SG_ID" ] || [ "$SG_ID" = "None" ]; then
        print_error "Failed to create security group"
        exit 1
    fi
    
    print_success "Security group created: $SG_ID"
    
    # Add rules
    print_status "Adding security group rules..."
    
    # SSH
    aws ec2 authorize-security-group-ingress \
        --group-id "$SG_ID" \
        --protocol tcp \
        --port 22 \
        --cidr 0.0.0.0/0 >/dev/null 2>&1
    
    # Application ports
    for port in 30080 30081 30082 30083 30084 9000; do
        aws ec2 authorize-security-group-ingress \
            --group-id "$SG_ID" \
            --protocol tcp \
            --port $port \
            --cidr 0.0.0.0/0 >/dev/null 2>&1 && print_success "Port $port opened"
    done
    
    print_success "Security group rules added"
else
    print_success "Security group exists: $SG_ID"
fi

print_header "Step 3: Setting Up Key Pair"

# Check if key pair exists
if aws ec2 describe-key-pairs --key-names "$KEY_PAIR_NAME" >/dev/null 2>&1; then
    print_success "Key pair exists: $KEY_PAIR_NAME"
    KEY_FILE="$HOME/.ssh/${KEY_PAIR_NAME}.pem"
    
    if [ ! -f "$KEY_FILE" ]; then
        print_warning "Key pair exists in AWS but not locally"
        print_status "Downloading key pair..."
        aws ec2 describe-key-pairs --key-names "$KEY_PAIR_NAME" --query 'KeyPairs[0].KeyMaterial' --output text > "$KEY_FILE" 2>/dev/null || {
            print_error "Cannot download key. Please create new key pair or use existing .pem file"
            exit 1
        }
        chmod 400 "$KEY_FILE"
    fi
else
    print_status "Creating new key pair..."
    KEY_FILE="$HOME/.ssh/${KEY_PAIR_NAME}.pem"
    
    # Create key pair
    aws ec2 create-key-pair \
        --key-name "$KEY_PAIR_NAME" \
        --query 'KeyMaterial' \
        --output text > "$KEY_FILE" 2>/dev/null
    
    if [ $? -eq 0 ] && [ -f "$KEY_FILE" ]; then
        chmod 400 "$KEY_FILE"
        print_success "Key pair created and saved to: $KEY_FILE"
    else
        print_error "Failed to create key pair"
        exit 1
    fi
fi

print_header "Step 4: Finding Ubuntu AMI"

# Get latest Ubuntu 22.04 AMI
print_status "Finding latest Ubuntu 22.04 AMI in $AWS_REGION..."
AMI_ID=$(aws ec2 describe-images \
    --owners 099720109477 \
    --filters \
        "Name=name,Values=$AMI_NAME" \
        "Name=state,Values=available" \
    --query 'Images | sort_by(@, &CreationDate) | [-1].ImageId' \
    --output text 2>/dev/null)

if [ -z "$AMI_ID" ] || [ "$AMI_ID" = "None" ]; then
    print_error "Could not find Ubuntu AMI"
    exit 1
fi

print_success "Found AMI: $AMI_ID"

print_header "Step 5: Launching EC2 Instance"

# Check if instance already exists with same name
EXISTING_INSTANCE=$(aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=$INSTANCE_NAME" "Name=instance-state-name,Values=running,stopped" \
    --query 'Reservations[0].Instances[0].InstanceId' \
    --output text 2>/dev/null)

if [ -n "$EXISTING_INSTANCE" ] && [ "$EXISTING_INSTANCE" != "None" ]; then
    print_warning "Instance with name '$INSTANCE_NAME' already exists: $EXISTING_INSTANCE"
    read -p "Do you want to use existing instance? (y/n): " USE_EXISTING
    
    if [ "$USE_EXISTING" = "y" ] || [ "$USE_EXISTING" = "Y" ]; then
        INSTANCE_ID="$EXISTING_INSTANCE"
        print_status "Using existing instance: $INSTANCE_ID"
        
        # Start if stopped
        STATE=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" --query 'Reservations[0].Instances[0].State.Name' --output text)
        if [ "$STATE" = "stopped" ]; then
            print_status "Starting instance..."
            aws ec2 start-instances --instance-ids "$INSTANCE_ID" >/dev/null
            aws ec2 wait instance-running --instance-ids "$INSTANCE_ID"
        fi
    else
        print_status "Launching new instance..."
        INSTANCE_ID=$(aws ec2 run-instances \
            --image-id "$AMI_ID" \
            --instance-type "$INSTANCE_TYPE" \
            --key-name "$KEY_PAIR_NAME" \
            --security-group-ids "$SG_ID" \
            --associate-public-ip-address \
            --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":30,"VolumeType":"gp3","DeleteOnTermination":true}}]' \
            --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$INSTANCE_NAME}]" \
            --query 'Instances[0].InstanceId' \
            --output text 2>/dev/null)
    fi
else
    print_status "Launching new EC2 instance..."
    print_status "Instance Type: $INSTANCE_TYPE"
    print_status "AMI: $AMI_ID"
    print_status "Security Group: $SG_ID"
    print_status "Key Pair: $KEY_PAIR_NAME"
    
    INSTANCE_ID=$(aws ec2 run-instances \
        --image-id "$AMI_ID" \
        --instance-type "$INSTANCE_TYPE" \
        --key-name "$KEY_PAIR_NAME" \
        --security-group-ids "$SG_ID" \
        --associate-public-ip-address \
        --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":30,"VolumeType":"gp3","DeleteOnTermination":true}}]' \
        --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$INSTANCE_NAME}]" \
        --query 'Instances[0].InstanceId' \
        --output text 2>/dev/null)
fi

if [ -z "$INSTANCE_ID" ] || [ "$INSTANCE_ID" = "None" ]; then
    print_error "Failed to launch instance"
    exit 1
fi

print_success "Instance launched: $INSTANCE_ID"

# Wait for instance to be running
print_status "Waiting for instance to be running (this may take 1-2 minutes)..."
aws ec2 wait instance-running --instance-ids "$INSTANCE_ID"

# Get public IP
print_status "Getting instance details..."
EC2_PUBLIC_IP=$(aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' \
    --output text)

EC2_PRIVATE_IP=$(aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].PrivateIpAddress' \
    --output text)

if [ -z "$EC2_PUBLIC_IP" ] || [ "$EC2_PUBLIC_IP" = "None" ]; then
    print_error "Could not get public IP"
    exit 1
fi

print_success "Instance is running!"
print_status "Public IP: $EC2_PUBLIC_IP"
print_status "Private IP: $EC2_PRIVATE_IP"

# Wait for SSH to be ready
print_status "Waiting for SSH to be ready (30 seconds)..."
sleep 30

print_header "Step 6: Setting Up Instance"

# Test SSH connection
print_status "Testing SSH connection..."
MAX_RETRIES=10
RETRY_COUNT=0

while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    if ssh -i "$KEY_FILE" \
        -o StrictHostKeyChecking=no \
        -o ConnectTimeout=10 \
        -o UserKnownHostsFile=/dev/null \
        ubuntu@"$EC2_PUBLIC_IP" \
        "echo 'SSH connection successful'" >/dev/null 2>&1; then
        print_success "SSH connection successful!"
        break
    else
        RETRY_COUNT=$((RETRY_COUNT + 1))
        if [ $RETRY_COUNT -lt $MAX_RETRIES ]; then
            print_status "Retrying SSH connection ($RETRY_COUNT/$MAX_RETRIES)..."
            sleep 10
        else
            print_error "Cannot connect via SSH after $MAX_RETRIES attempts"
            print_status "Instance may still be initializing. Please try manually:"
            echo "  ssh -i $KEY_FILE ubuntu@$EC2_PUBLIC_IP"
            exit 1
        fi
    fi
done

# Setup instance
print_status "Setting up instance (this will take 10-15 minutes)..."
print_status "Installing prerequisites, setting up Kubernetes, and deploying applications..."

ssh -i "$KEY_FILE" \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    ubuntu@"$EC2_PUBLIC_IP" << 'ENDSSH'
set -e

echo "🚀 Starting setup on EC2 instance..."

# Update system
sudo apt-get update -y
sudo apt-get upgrade -y

# Install git
sudo apt-get install -y git curl wget

# Clone repository
if [ ! -d "Project6-testpurpose" ]; then
    git clone https://github.com/auspicious27/Project6-testpurpose.git
    cd Project6-testpurpose
else
    cd Project6-testpurpose
    git pull
fi

# Make scripts executable
chmod +x *.sh

# Run setup
echo "Running setup scripts..."
./setup_prereqs.sh
./bootstrap_cluster.sh
./deploy_pipeline.sh
./fix_all_services.sh

echo "✅ Setup completed on EC2!"
ENDSSH

if [ $? -eq 0 ]; then
    print_success "Setup completed on EC2!"
else
    print_error "Setup failed. Please check logs above."
    print_status "You can SSH into instance and check manually:"
    echo "  ssh -i $KEY_FILE ubuntu@$EC2_PUBLIC_IP"
    exit 1
fi

print_header "Step 7: Getting Service URLs"

# Get ArgoCD password
print_status "Getting ArgoCD password..."
ARGOCD_PASSWORD=$(ssh -i "$KEY_FILE" \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    ubuntu@"$EC2_PUBLIC_IP" \
    "kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>/dev/null | base64 -d" 2>/dev/null || echo "check-manually")

# Display results
echo ""
print_header "✅ Setup Complete!"
echo ""
echo "🌐 Access URLs:"
echo ""
echo "📱 Flask Application:"
echo "   http://${EC2_PUBLIC_IP}:30080"
echo ""
echo "👥 User Service API:"
echo "   http://${EC2_PUBLIC_IP}:30081/api/users"
echo ""
echo "📦 Product Service API:"
echo "   http://${EC2_PUBLIC_IP}:30082/api/products"
echo ""
echo "🔧 ArgoCD:"
echo "   http://${EC2_PUBLIC_IP}:30083"
echo "   Username: admin"
echo "   Password: ${ARGOCD_PASSWORD}"
echo ""
echo "📚 Gitea:"
echo "   http://${EC2_PUBLIC_IP}:30084"
echo "   Username: admin"
echo "   Password: admin123"
echo ""
echo "=========================================="
echo "📋 Instance Details:"
echo "=========================================="
echo ""
echo "Instance ID: $INSTANCE_ID"
echo "Public IP: $EC2_PUBLIC_IP"
echo "Private IP: $EC2_PRIVATE_IP"
echo "Region: $AWS_REGION"
echo "Security Group: $SG_ID"
echo "Key Pair: $KEY_PAIR_NAME"
echo "Key File: $KEY_FILE"
echo ""
echo "=========================================="
echo "🔍 How to Check in AWS Console:"
echo "=========================================="
echo ""
echo "1. Go to: https://console.aws.amazon.com/ec2"
echo "2. Click 'Instances' in left menu"
echo "3. Find instance: $INSTANCE_NAME"
echo "4. Check Status: Should be 'Running'"
echo "5. Check Public IPv4: $EC2_PUBLIC_IP"
echo ""
echo "To SSH into instance:"
echo "  ssh -i $KEY_FILE ubuntu@$EC2_PUBLIC_IP"
echo ""
echo "To check services:"
echo "  ssh -i $KEY_FILE ubuntu@$EC2_PUBLIC_IP 'kubectl get pods -A'"
echo ""
print_success "All done! Your DevOps pipeline is ready! 🎉"
echo ""

