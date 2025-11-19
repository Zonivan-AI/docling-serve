# Deploying Docling Serve on Google Cloud Run

This guide walks you through deploying docling-serve on Google Cloud Run with proper authentication and secrets management.

## Prerequisites

1. **Google Cloud Account** with billing enabled
2. **gcloud CLI** installed and authenticated
   ```bash
   gcloud auth login
   gcloud auth application-default login
   ```
3. **Docker** or **Podman** (optional, for local testing)
4. **Project ID** - Your GCP project ID

## Quick Start

### Step 1: Set Your Project ID

```bash
export GCP_PROJECT_ID=your-project-id
gcloud config set project $GCP_PROJECT_ID
```

### Step 2: Enable Required APIs

```bash
gcloud services enable \
  run.googleapis.com \
  secretmanager.googleapis.com \
  cloudbuild.googleapis.com
```

### Step 3: Set Up Secrets

Create the API key secret:

```bash
cd scripts
chmod +x setup-cloud-run-secrets.sh
./setup-cloud-run-secrets.sh
```

Or manually:

```bash
# Generate a secure API key
API_KEY=$(openssl rand -hex 32)

# Create the secret
echo -n "$API_KEY" | gcloud secrets create docling-api-key \
  --project=$GCP_PROJECT_ID \
  --data-file=-

# Save the API key securely!
echo "API Key: $API_KEY"
```

### Step 4: Deploy to Cloud Run

```bash
cd scripts
chmod +x deploy-cloud-run.sh
./deploy-cloud-run.sh
```

## Detailed Configuration

### Environment Variables

The deployment script configures these environment variables:

| Variable | Value | Description |
|----------|-------|-------------|
| `UVICORN_PORT` | `8080` | Port Cloud Run expects |
| `DOCLING_SERVE_ENABLE_UI` | `false` | Disable UI for production |
| `DOCLING_SERVE_SCRATCH_PATH` | `/tmp/scratch` | Temporary storage |
| `DOCLING_SERVE_ARTIFACTS_PATH` | `/tmp/models` | Model storage (ephemeral) |
| `DOCLING_SERVE_API_KEY` | From Secret Manager | API key for authentication |

### Resource Configuration

Default configuration (can be customized):

- **Memory**: 4Gi (required for model loading)
- **CPU**: 2 vCPUs
- **Min Instances**: 0 (scale to zero)
- **Max Instances**: 10
- **Concurrency**: 5 requests per instance
- **Timeout**: 3600 seconds (1 hour)

### Customizing Deployment

You can customize the deployment by setting environment variables:

```bash
export GCP_PROJECT_ID=your-project-id
export SERVICE_NAME=my-docling-service
export REGION=us-east1
export MEMORY=8Gi
export CPU=4
export MIN_INSTANCES=1
export MAX_INSTANCES=20
export CONCURRENCY=10

./deploy-cloud-run.sh
```

## Authentication

### Two Layers of Authentication

1. **Cloud Run IAM Authentication** (Required)
   - All requests must include an identity token
   - Prevents unauthorized access to the service

2. **API Key Authentication** (Application-level)
   - Additional layer of security
   - Required header: `X-Api-Key`

### Making Authenticated Requests

#### Using gcloud Identity Token

```bash
# Get identity token
TOKEN=$(gcloud auth print-identity-token)

# Make request
curl -X POST \
  -H "Authorization: Bearer $TOKEN" \
  -H "X-Api-Key: YOUR_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "sources": [{"kind": "http", "url": "https://arxiv.org/pdf/2501.17887"}]
  }' \
  https://your-service-url.run.app/v1/convert/source/async
```

#### Using Service Account

```bash
# Create service account key
gcloud iam service-accounts create docling-client \
  --display-name="Docling Client"

# Grant Cloud Run Invoker role
gcloud run services add-iam-policy-binding docling-serve \
  --region=us-central1 \
  --member="serviceAccount:docling-client@$GCP_PROJECT_ID.iam.gserviceaccount.com" \
  --role="roles/run.invoker"

# Get identity token
gcloud auth activate-service-account \
  docling-client@$GCP_PROJECT_ID.iam.gserviceaccount.com \
  --key-file=key.json

TOKEN=$(gcloud auth print-identity-token)

# Make request
curl -X POST \
  -H "Authorization: Bearer $TOKEN" \
  -H "X-Api-Key: YOUR_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "sources": [{"kind": "http", "url": "https://arxiv.org/pdf/2501.17887"}]
  }' \
  https://your-service-url.run.app/v1/convert/source/async
```

#### Using Python Client

```python
import requests
from google.auth import default
from google.auth.transport.requests import Request

# Get default credentials
credentials, project = default()

# Refresh to get access token
credentials.refresh(Request())

# Make request
url = "https://your-service-url.run.app/v1/convert/source/async"
headers = {
    "Authorization": f"Bearer {credentials.token}",
    "X-Api-Key": "YOUR_API_KEY",
    "Content-Type": "application/json"
}
data = {
    "sources": [{"kind": "http", "url": "https://arxiv.org/pdf/2501.17887"}]
}

response = requests.post(url, json=data, headers=headers)
print(response.json())
```

## Model Storage

### Current Setup (Ephemeral)

Models are stored in `/tmp/models` which is ephemeral. This means:
- Models are downloaded on each cold start
- First request after scale-to-zero will be slow
- No persistence across restarts

### Persistent Model Storage (Recommended for Production)

For production, use Cloud Storage with Cloud Storage FUSE:

```bash
# Create Cloud Storage bucket
gsutil mb -p $GCP_PROJECT_ID -l $REGION gs://$GCP_PROJECT_ID-docling-models

# Download models to bucket (one-time)
# You'll need to run this in a Cloud Run job or Cloud Build
```

Or use a Cloud Storage mount (requires Cloud Run with VPC):

```bash
# Deploy with Cloud Storage mount
gcloud run deploy docling-serve \
  --image quay.io/docling-project/docling-serve-cpu:latest \
  --set-env-vars "DOCLING_SERVE_ARTIFACTS_PATH=/mnt/models" \
  --vpc-connector=your-connector \
  --vpc-egress=all-traffic
```

## Monitoring and Logging

### View Logs

```bash
# Stream logs
gcloud run services logs tail docling-serve \
  --region=us-central1 \
  --project=$GCP_PROJECT_ID

# View recent logs
gcloud run services logs read docling-serve \
  --region=us-central1 \
  --project=$GCP_PROJECT_ID \
  --limit=50
```

### Set Up Monitoring

1. **Create Alert Policy** for error rates
2. **Set up Log-based Metrics** for request counts
3. **Configure Uptime Checks** for health endpoint

## Cost Optimization

### Reduce Cold Starts

Set `MIN_INSTANCES=1` to keep at least one instance warm:

```bash
export MIN_INSTANCES=1
./deploy-cloud-run.sh
```

### Optimize Resource Allocation

Monitor actual usage and adjust:

```bash
# Check metrics
gcloud monitoring time-series list \
  --filter='metric.type="run.googleapis.com/container/memory/utilizations"'

# Adjust based on actual usage
export MEMORY=2Gi  # If 4Gi is too much
export CPU=1       # If 2 CPUs are too much
```

## Troubleshooting

### Service Won't Start

1. **Check logs**:
   ```bash
   gcloud run services logs read docling-serve --region=us-central1
   ```

2. **Verify secret access**:
   ```bash
   gcloud secrets get-iam-policy docling-api-key
   ```

3. **Check service account permissions**:
   ```bash
   gcloud projects get-iam-policy $GCP_PROJECT_ID \
     --flatten="bindings[].members" \
     --filter="bindings.members:docling-serve@*"
   ```

### Authentication Errors

1. **Verify IAM binding**:
   ```bash
   gcloud run services get-iam-policy docling-serve --region=us-central1
   ```

2. **Check identity token**:
   ```bash
   gcloud auth print-identity-token
   ```

3. **Verify API key**:
   ```bash
   gcloud secrets versions access latest --secret=docling-api-key
   ```

### High Latency

1. **Check cold start times** in logs
2. **Increase MIN_INSTANCES** to reduce cold starts
3. **Consider persistent model storage** to avoid model downloads

## Security Best Practices

1. ✅ **Use Secret Manager** for API keys
2. ✅ **Enable IAM authentication** (no public access)
3. ✅ **Use least-privilege service accounts**
4. ✅ **Rotate API keys regularly**
5. ✅ **Enable audit logging**
6. ✅ **Use VPC connector** for private resources
7. ✅ **Set up Cloud Armor** for DDoS protection

## Updating the Service

To update the service with a new image or configuration:

```bash
# Just run the deployment script again
./deploy-cloud-run.sh

# Or update specific settings
gcloud run services update docling-serve \
  --region=us-central1 \
  --memory=8Gi \
  --cpu=4
```

## Cleanup

To remove the deployment:

```bash
# Delete the Cloud Run service
gcloud run services delete docling-serve \
  --region=us-central1 \
  --project=$GCP_PROJECT_ID

# Delete the service account (optional)
gcloud iam service-accounts delete docling-serve@$GCP_PROJECT_ID.iam.gserviceaccount.com

# Delete the secret (optional)
gcloud secrets delete docling-api-key --project=$GCP_PROJECT_ID
```

## Next Steps

1. **Set up CI/CD** for automated deployments
2. **Configure custom domain** for your service
3. **Set up monitoring and alerting**
4. **Implement rate limiting** if needed
5. **Set up persistent model storage** for production

## Additional Resources

- [Cloud Run Documentation](https://cloud.google.com/run/docs)
- [Secret Manager Documentation](https://cloud.google.com/secret-manager/docs)
- [Cloud Run Authentication](https://cloud.google.com/run/docs/authenticating/overview)
- [Docling Serve Configuration](./configuration.md)

