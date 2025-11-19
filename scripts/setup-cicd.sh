#!/bin/bash
# Setup script for CI/CD pipeline on GCP Cloud Build
# This script creates the Cloud Build trigger and necessary resources

set -e

PROJECT_ID="${GCP_PROJECT_ID:-}"
REGION="${REGION:-us-central1}"
ARTIFACT_REPO="${ARTIFACT_REPO:-docling-repo}"
SERVICE_NAME="${SERVICE_NAME:-docling-serve}"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# Check if PROJECT_ID is set
if [ -z "$PROJECT_ID" ]; then
    print_error "GCP_PROJECT_ID environment variable is not set"
    echo ""
    echo "Usage:"
    echo "  GCP_PROJECT_ID=your-project-id ./setup-cicd.sh"
    exit 1
fi

print_info "Setting up CI/CD for project: $PROJECT_ID"

# Set the project
gcloud config set project "$PROJECT_ID"

# Step 1: Enable required APIs
print_info "Enabling required APIs..."
gcloud services enable \
  cloudbuild.googleapis.com \
  run.googleapis.com \
  artifactregistry.googleapis.com \
  secretmanager.googleapis.com \
  --project="$PROJECT_ID"

# Step 2: Create Artifact Registry repository if it doesn't exist
print_info "Checking Artifact Registry repository..."
if ! gcloud artifacts repositories describe "$ARTIFACT_REPO" \
    --location="$REGION" \
    --project="$PROJECT_ID" &>/dev/null; then
    print_info "Creating Artifact Registry repository..."
    gcloud artifacts repositories create "$ARTIFACT_REPO" \
        --repository-format=docker \
        --location="$REGION" \
        --project="$PROJECT_ID"
else
    print_info "Artifact Registry repository already exists."
fi

# Step 3: Grant Cloud Build service account permissions
print_info "Granting permissions to Cloud Build service account..."
PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')
SERVICE_ACCOUNT="${SERVICE_ACCOUNT:-zonivan-backend@${PROJECT_ID}.iam.gserviceaccount.com}"

# Grant Artifact Registry writer
gcloud artifacts repositories add-iam-policy-binding "$ARTIFACT_REPO" \
    --location="$REGION" \
    --member="serviceAccount:${SERVICE_ACCOUNT}" \
    --role="roles/artifactregistry.writer" \
    --project="$PROJECT_ID" || print_warning "Could not grant Artifact Registry permissions"

# Grant Cloud Run Admin
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${SERVICE_ACCOUNT}" \
    --role="roles/run.admin" \
    --condition=None || print_warning "Could not grant Cloud Run permissions"

# Grant Service Account User (to use the docling-serve service account)
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${SERVICE_ACCOUNT}" \
    --role="roles/iam.serviceAccountUser" \
    --condition=None || print_warning "Could not grant Service Account User permissions"

# Grant Secret Manager Secret Accessor (for API key)
gcloud secrets add-iam-policy-binding docling-api-key \
    --project="$PROJECT_ID" \
    --member="serviceAccount:${SERVICE_ACCOUNT}" \
    --role="roles/secretmanager.secretAccessor" || print_warning "Secret might not exist yet"

# Step 4: Create Cloud Build trigger
print_info "Creating Cloud Build trigger..."

# Check if trigger already exists
if gcloud builds triggers describe docling-serve-deploy \
    --project="$PROJECT_ID" &>/dev/null; then
    print_warning "Trigger already exists. Updating..."
    gcloud builds triggers update docling-serve-deploy \
        --project="$PROJECT_ID" \
        --name="docling-serve-deploy" \
        --description="Automatic deployment of docling-serve to Cloud Run" \
        --repo="REPO_NAME" \
        --repo-type="CLOUD_SOURCE_REPOSITORIES" \
        --branch="^main$" \
        --build-config="cloudbuild-deploy.yaml" \
        --substitutions="_REGION=${REGION},_ARTIFACT_REPO=${ARTIFACT_REPO},_SERVICE_NAME=${SERVICE_NAME},_SERVICE_ACCOUNT=docling-serve@${PROJECT_ID}.iam.gserviceaccount.com,_API_KEY_SECRET=docling-api-key" \
        --service-account="${SERVICE_ACCOUNT}" || print_warning "Could not update trigger. You may need to create it manually."
else
    print_info "Creating new trigger..."
    print_warning "Note: You'll need to connect your repository first."
    echo ""
    echo "To connect your repository:"
    echo "  1. Go to Cloud Console > Cloud Build > Triggers"
    echo "  2. Click 'Connect Repository'"
    echo "  3. Select your repository source (GitHub, Cloud Source Repositories, etc.)"
    echo "  4. Then run this script again or create the trigger manually"
    echo ""
    echo "Or create trigger manually with:"
    echo "  gcloud builds triggers create github \\"
    echo "    --name=docling-serve-deploy \\"
    echo "    --repo-name=YOUR_REPO \\"
    echo "    --repo-owner=YOUR_ORG \\"
    echo "    --branch-pattern='^main$' \\"
    echo "    --build-config=cloudbuild-deploy.yaml \\"
    echo "    --substitutions='_REGION=${REGION},_ARTIFACT_REPO=${ARTIFACT_REPO},_SERVICE_NAME=${SERVICE_NAME}' \\"
    echo "    --service-account=${SERVICE_ACCOUNT}"
fi

print_info ""
print_info "✅ CI/CD setup complete!"
print_info ""
print_info "Next steps:"
echo "  1. Connect your repository to Cloud Build"
echo "  2. Create the trigger (or it will be created automatically)"
echo "  3. Push to main branch to trigger automatic deployment"
echo ""
print_info "To manually trigger a build:"
echo "  gcloud builds submit --config=cloudbuild-deploy.yaml --project=$PROJECT_ID"

