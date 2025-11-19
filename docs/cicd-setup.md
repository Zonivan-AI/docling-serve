# CI/CD Setup for Docling Serve on GCP

This guide explains how to set up a complete CI/CD pipeline for docling-serve on Google Cloud Platform.

## Overview

The CI/CD pipeline:
1. **Builds** the container image from source using Cloud Build
2. **Pushes** the image to Artifact Registry
3. **Deploys** automatically to Cloud Run on git push to main branch

## Prerequisites

1. GCP Project with billing enabled
2. `gcloud` CLI installed and authenticated
3. Repository connected to Cloud Build (GitHub, Cloud Source Repositories, etc.)
4. Service account with necessary permissions

## Quick Setup

### Step 1: Run the Setup Script

```bash
export GCP_PROJECT_ID=your-project-id
cd scripts
chmod +x setup-cicd.sh
./setup-cicd.sh
```

This script will:
- Enable required APIs
- Create Artifact Registry repository
- Grant necessary permissions
- Set up the Cloud Build trigger

### Step 2: Connect Your Repository

If using GitHub:

```bash
gcloud builds triggers create github \
  --name=docling-serve-deploy \
  --repo-name=docling-serve \
  --repo-owner=YOUR_GITHUB_ORG \
  --branch-pattern='^main$' \
  --build-config=cloudbuild-deploy.yaml \
  --substitutions="_REGION=us-central1,_ARTIFACT_REPO=docling-repo,_SERVICE_NAME=docling-serve" \
  --service-account=zonivan-backend@${GCP_PROJECT_ID}.iam.gserviceaccount.com
```

### Step 3: Manual Build and Deploy

To build and deploy manually without waiting for git push:

```bash
cd scripts
chmod +x build-and-deploy.sh
./build-and-deploy.sh
```

Or use Cloud Build directly:

```bash
gcloud builds submit --config=cloudbuild-deploy.yaml --project=$GCP_PROJECT_ID
```

## Configuration Files

### `cloudbuild-deploy.yaml`

Main Cloud Build configuration that:
- Builds the CPU variant container image
- Pushes to Artifact Registry
- Deploys to Cloud Run with proper configuration

**Key substitutions:**
- `_REGION`: GCP region (default: us-central1)
- `_ARTIFACT_REPO`: Artifact Registry repository name
- `_SERVICE_NAME`: Cloud Run service name
- `_MEMORY`: Memory allocation (default: 4Gi)
- `_CPU`: CPU allocation (default: 2)
- `_SERVICE_ACCOUNT`: Service account for Cloud Run
- `_API_KEY_SECRET`: Secret name for API key

### Customizing the Build

You can override substitutions:

```bash
gcloud builds submit \
  --config=cloudbuild-deploy.yaml \
  --substitutions="_MEMORY=8Gi,_CPU=4,_MAX_INSTANCES=20" \
  --project=$GCP_PROJECT_ID
```

## Build Process

1. **Build Stage**: Uses Docker to build the container image
   - Platform: `linux/amd64` (required for Cloud Run)
   - Build args: CPU-only PyTorch variant
   - Models: Pre-downloaded during build

2. **Push Stage**: Pushes image to Artifact Registry
   - Tags: `SHORT_SHA` and `latest`

3. **Deploy Stage**: Deploys to Cloud Run
   - Uses the built image
   - Configures environment variables
   - Sets up secrets
   - Enables authentication

## CI/CD Workflow

### Automatic Deployment

When you push to the `main` branch:
1. Cloud Build trigger fires
2. Builds the container image
3. Runs tests (if configured)
4. Deploys to Cloud Run
5. Service is updated with zero downtime

### Manual Deployment

For manual deployments or testing:

```bash
# Build and deploy
./scripts/build-and-deploy.sh

# Or build only
gcloud builds submit --config=cloudbuild-deploy.yaml
```

## Environment Variables

The deployment sets these environment variables:

- `UVICORN_PORT=8080` - Port for Cloud Run
- `DOCLING_SERVE_ENABLE_UI=false` - Disable UI in production
- `DOCLING_SERVE_SCRATCH_PATH=/tmp/scratch` - Temporary storage
- `DOCLING_SERVE_ARTIFACTS_PATH=/opt/app-root/src/.cache/docling/models` - Model storage

## Secrets

The deployment uses Secret Manager for:
- `DOCLING_SERVE_API_KEY` - API key for authentication

Make sure the secret exists:
```bash
gcloud secrets describe docling-api-key --project=$GCP_PROJECT_ID
```

## Monitoring Builds

View build history:
```bash
gcloud builds list --project=$GCP_PROJECT_ID --limit=10
```

View build logs:
```bash
gcloud builds log BUILD_ID --project=$GCP_PROJECT_ID
```

## Troubleshooting

### Build Fails

1. Check build logs:
   ```bash
   gcloud builds list --project=$GCP_PROJECT_ID
   gcloud builds log BUILD_ID --project=$GCP_PROJECT_ID
   ```

2. Verify permissions:
   ```bash
   gcloud projects get-iam-policy $GCP_PROJECT_ID \
     --flatten="bindings[].members" \
     --filter="bindings.members:zonivan-backend@*"
   ```

### Deployment Fails

1. Check Cloud Run logs:
   ```bash
   gcloud run services logs read $SERVICE_NAME \
     --region=$REGION \
     --project=$GCP_PROJECT_ID
   ```

2. Verify service account exists:
   ```bash
   gcloud iam service-accounts describe \
     docling-serve@${GCP_PROJECT_ID}.iam.gserviceaccount.com
   ```

### Image Not Found

Ensure Artifact Registry repository exists:
```bash
gcloud artifacts repositories list --project=$GCP_PROJECT_ID
```

## Advanced Configuration

### Custom Build Args

To build with different PyTorch variants, modify `cloudbuild-deploy.yaml`:

```yaml
args:
  - '--build-arg=UV_SYNC_EXTRA_ARGS=--no-group pypi --group cu126'  # CUDA 12.6
```

### Multi-Region Deployment

Deploy to multiple regions:

```bash
for region in us-central1 us-east1 europe-west1; do
  gcloud builds submit \
    --config=cloudbuild-deploy.yaml \
    --substitutions="_REGION=${region}" \
    --project=$GCP_PROJECT_ID
done
```

### Build Caching

Cloud Build automatically caches Docker layers. To clear cache:

```bash
gcloud builds submit --no-cache --config=cloudbuild-deploy.yaml
```

## Best Practices

1. **Use tags**: Tag images with commit SHA for traceability
2. **Test before deploy**: Run tests in Cloud Build before deployment
3. **Monitor costs**: Cloud Build charges for build minutes
4. **Use build triggers**: Automate deployments on git push
5. **Version secrets**: Use versioned secrets for API keys

## Next Steps

- Set up monitoring and alerting
- Configure custom domains
- Set up staging/production environments
- Implement blue-green deployments
- Add automated testing

