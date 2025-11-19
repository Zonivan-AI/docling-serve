#!/bin/bash
# Setup script for Cloud Run secrets
# This script creates the necessary secrets in Google Secret Manager

set -e

PROJECT_ID="${GCP_PROJECT_ID:-}"
SECRET_NAME="${DOCLING_API_KEY_SECRET:-docling-api-key}"

if [ -z "$PROJECT_ID" ]; then
    echo "Error: GCP_PROJECT_ID environment variable is not set"
    echo "Usage: GCP_PROJECT_ID=your-project-id ./setup-cloud-run-secrets.sh"
    exit 1
fi

echo "Setting up secrets for project: $PROJECT_ID"

# Check if secret already exists
if gcloud secrets describe "$SECRET_NAME" --project="$PROJECT_ID" &>/dev/null; then
    echo "Secret '$SECRET_NAME' already exists."
    read -p "Do you want to add a new version? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Skipping secret creation."
        exit 0
    fi
fi

# Generate a secure API key if not provided
if [ -z "$DOCLING_API_KEY_VALUE" ]; then
    echo "Generating a secure API key..."
    API_KEY=$(openssl rand -hex 32)
    echo "Generated API Key: $API_KEY"
    echo "⚠️  IMPORTANT: Save this API key securely!"
    echo ""
    read -p "Press Enter to continue..."
else
    API_KEY="$DOCLING_API_KEY_VALUE"
fi

# Create or update the secret
if gcloud secrets describe "$SECRET_NAME" --project="$PROJECT_ID" &>/dev/null; then
    echo "Adding new version to existing secret..."
    echo -n "$API_KEY" | gcloud secrets versions add "$SECRET_NAME" \
        --project="$PROJECT_ID" \
        --data-file=-
else
    echo "Creating new secret..."
    echo -n "$API_KEY" | gcloud secrets create "$SECRET_NAME" \
        --project="$PROJECT_ID" \
        --data-file=-
fi

# Grant Cloud Run service account access to the secret
SERVICE_ACCOUNT="${SERVICE_ACCOUNT:-docling-serve@${PROJECT_ID}.iam.gserviceaccount.com}"

echo ""
echo "Granting Cloud Run service account access to secret..."
gcloud secrets add-iam-policy-binding "$SECRET_NAME" \
    --project="$PROJECT_ID" \
    --member="serviceAccount:${SERVICE_ACCOUNT}" \
    --role="roles/secretmanager.secretAccessor" \
    || echo "Note: Service account might not exist yet. You'll need to grant access after creating the service account."

echo ""
echo "✅ Secret setup complete!"
echo ""
echo "Secret name: $SECRET_NAME"
echo "To view the secret value:"
echo "  gcloud secrets versions access latest --secret=$SECRET_NAME --project=$PROJECT_ID"
echo ""
echo "To revoke access:"
echo "  gcloud secrets remove-iam-policy-binding $SECRET_NAME \\"
echo "    --member=serviceAccount:${SERVICE_ACCOUNT} \\"
echo "    --role=roles/secretmanager.secretAccessor"

