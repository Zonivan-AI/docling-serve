#!/bin/bash
# Deployment script for docling-serve on Google Cloud Run
# This script deploys the docling-serve container to Cloud Run with proper configuration

set -e

# Configuration variables (can be overridden via environment variables)
PROJECT_ID="${GCP_PROJECT_ID:-}"
SERVICE_NAME="${SERVICE_NAME:-docling-serve}"
REGION="${REGION:-us-central1}"
IMAGE="${IMAGE:-quay.io/docling-project/docling-serve-cpu:latest}"
PORT="${PORT:-8080}"
MEMORY="${MEMORY:-4Gi}"
CPU="${CPU:-2}"
MIN_INSTANCES="${MIN_INSTANCES:-0}"
MAX_INSTANCES="${MAX_INSTANCES:-10}"
CONCURRENCY="${CONCURRENCY:-5}"
TIMEOUT="${TIMEOUT:-3600}"
SECRET_NAME="${DOCLING_API_KEY_SECRET:-docling-api-key}"
SERVICE_ACCOUNT="${SERVICE_ACCOUNT:-docling-serve@${PROJECT_ID}.iam.gserviceaccount.com}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print colored output
print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if required tools are installed
check_dependencies() {
    print_info "Checking dependencies..."
    
    if ! command -v gcloud &> /dev/null; then
        print_error "gcloud CLI is not installed. Please install it from https://cloud.google.com/sdk/docs/install"
        exit 1
    fi
    
    if ! command -v docker &> /dev/null && ! command -v podman &> /dev/null; then
        print_warning "Neither docker nor podman found. You may need to authenticate with the container registry."
    fi
    
    print_info "Dependencies check passed."
}

# Check if PROJECT_ID is set
if [ -z "$PROJECT_ID" ]; then
    print_error "GCP_PROJECT_ID environment variable is not set"
    echo ""
    echo "Usage:"
    echo "  GCP_PROJECT_ID=your-project-id ./deploy-cloud-run.sh"
    echo ""
    echo "Or set it in your environment:"
    echo "  export GCP_PROJECT_ID=your-project-id"
    exit 1
fi

# Set the project
print_info "Setting GCP project to: $PROJECT_ID"
gcloud config set project "$PROJECT_ID"

# Check if secret exists
print_info "Checking if secret '$SECRET_NAME' exists..."
if ! gcloud secrets describe "$SECRET_NAME" --project="$PROJECT_ID" &>/dev/null; then
    print_warning "Secret '$SECRET_NAME' does not exist."
    echo "Please run ./setup-cloud-run-secrets.sh first to create the secret."
    read -p "Do you want to continue without authentication? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
    USE_SECRET=false
else
    USE_SECRET=true
    print_info "Secret found. Will use it for authentication."
fi

# Check if service account exists, create if not
print_info "Checking service account..."
if ! gcloud iam service-accounts describe "$SERVICE_ACCOUNT" --project="$PROJECT_ID" &>/dev/null; then
    print_info "Creating service account: $SERVICE_ACCOUNT"
    gcloud iam service-accounts create docling-serve \
        --project="$PROJECT_ID" \
        --display-name="Docling Serve Service Account" \
        --description="Service account for docling-serve Cloud Run service"
    
    # Grant necessary permissions
    print_info "Granting permissions to service account..."
    gcloud projects add-iam-policy-binding "$PROJECT_ID" \
        --member="serviceAccount:${SERVICE_ACCOUNT}" \
        --role="roles/secretmanager.secretAccessor"
    
    if [ "$USE_SECRET" = true ]; then
        gcloud secrets add-iam-policy-binding "$SECRET_NAME" \
            --project="$PROJECT_ID" \
            --member="serviceAccount:${SERVICE_ACCOUNT}" \
            --role="roles/secretmanager.secretAccessor"
    fi
else
    print_info "Service account already exists."
fi

# Build environment variables
ENV_VARS=(
    "UVICORN_PORT=${PORT}"
    "DOCLING_SERVE_ENABLE_UI=false"
    "DOCLING_SERVE_SCRATCH_PATH=/tmp/scratch"
    "DOCLING_SERVE_ARTIFACTS_PATH=/tmp/models"
)

# Add secret reference if secret exists
if [ "$USE_SECRET" = true ]; then
    ENV_VARS+=("DOCLING_SERVE_API_KEY=${SECRET_NAME}:latest")
fi

# Build the gcloud run deploy command
DEPLOY_CMD=(
    gcloud run deploy "$SERVICE_NAME"
    --image "$IMAGE"
    --platform managed
    --region "$REGION"
    --memory "$MEMORY"
    --cpu "$CPU"
    --min-instances "$MIN_INSTANCES"
    --max-instances "$MAX_INSTANCES"
    --concurrency "$CONCURRENCY"
    --timeout "$TIMEOUT"
    --port "$PORT"
    --service-account "$SERVICE_ACCOUNT"
    --no-allow-unauthenticated
    --project "$PROJECT_ID"
)

# Add environment variables
for env_var in "${ENV_VARS[@]}"; do
    if [[ "$env_var" == *":latest" ]]; then
        # This is a secret reference
        DEPLOY_CMD+=(--set-secrets "$env_var")
    else
        DEPLOY_CMD+=(--set-env-vars "$env_var")
    fi
done

# Deploy the service
print_info "Deploying service '$SERVICE_NAME' to Cloud Run..."
print_info "Configuration:"
echo "  Image: $IMAGE"
echo "  Region: $REGION"
echo "  Memory: $MEMORY"
echo "  CPU: $CPU"
echo "  Port: $PORT"
echo "  Min instances: $MIN_INSTANCES"
echo "  Max instances: $MAX_INSTANCES"
echo "  Concurrency: $CONCURRENCY"
echo "  Timeout: ${TIMEOUT}s"
echo "  Authentication: Enabled (IAM)"
if [ "$USE_SECRET" = true ]; then
    echo "  API Key: Configured via Secret Manager"
else
    echo "  API Key: Not configured"
fi
echo ""

# Execute deployment
"${DEPLOY_CMD[@]}"

# Get the service URL
SERVICE_URL=$(gcloud run services describe "$SERVICE_NAME" \
    --region="$REGION" \
    --project="$PROJECT_ID" \
    --format='value(status.url)')

print_info "✅ Deployment complete!"
echo ""
echo "Service URL: $SERVICE_URL"
echo ""
echo "To test the deployment:"
echo "  1. Get an identity token:"
echo "     gcloud auth print-identity-token"
echo ""
echo "  2. Make a request:"
echo "     curl -X POST \\"
echo "       -H 'Authorization: Bearer \$(gcloud auth print-identity-token)' \\"
echo "       -H 'Content-Type: application/json' \\"
echo "       -H 'X-Api-Key: YOUR_API_KEY' \\"
echo "       -d '{\"sources\": [{\"kind\": \"http\", \"url\": \"https://arxiv.org/pdf/2501.17887\"}]}' \\"
echo "       $SERVICE_URL/v1/convert/source/async"
echo ""
echo "To view logs:"
echo "  gcloud run services logs read $SERVICE_NAME --region=$REGION --project=$PROJECT_ID"
echo ""
echo "To update the service:"
echo "  ./deploy-cloud-run.sh"
echo ""
echo "To delete the service:"
echo "  gcloud run services delete $SERVICE_NAME --region=$REGION --project=$PROJECT_ID"

