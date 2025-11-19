#!/bin/bash
# Manual build and deploy script for docling-serve
# This builds the container and deploys to Cloud Run

set -e

PROJECT_ID="${GCP_PROJECT_ID:-crafty-cairn-474720-q9}"
REGION="${REGION:-us-central1}"
ARTIFACT_REPO="${ARTIFACT_REPO:-docling-repo}"
SERVICE_NAME="${SERVICE_NAME:-docling-serve}"
SERVICE_ACCOUNT="${SERVICE_ACCOUNT:-zonivan-backend@${PROJECT_ID}.iam.gserviceaccount.com}"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if PROJECT_ID is set
if [ -z "$PROJECT_ID" ]; then
    print_error "GCP_PROJECT_ID environment variable is not set"
    exit 1
fi

print_info "Building and deploying docling-serve"
print_info "Project: $PROJECT_ID"
print_info "Region: $REGION"
print_info "Service: $SERVICE_NAME"
echo ""

# Set the project
gcloud config set project "$PROJECT_ID"

# Submit the build
print_info "Submitting Cloud Build..."
gcloud builds submit \
    --config=cloudbuild-deploy.yaml \
    --substitutions="_REGION=${REGION},_ARTIFACT_REPO=${ARTIFACT_REPO},_SERVICE_NAME=${SERVICE_NAME},_SERVICE_ACCOUNT=docling-serve@${PROJECT_ID}.iam.gserviceaccount.com,_API_KEY_SECRET=docling-api-key" \
    --project="$PROJECT_ID"

print_info ""
print_info "✅ Build and deployment complete!"
print_info ""
print_info "Service URL:"
gcloud run services describe "$SERVICE_NAME" \
    --region="$REGION" \
    --project="$PROJECT_ID" \
    --format='value(status.url)'

