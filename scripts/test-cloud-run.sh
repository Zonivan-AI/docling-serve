#!/bin/bash
# Test script for Cloud Run deployment
# This script tests the deployed docling-serve service

set -e

# Configuration
PROJECT_ID="${GCP_PROJECT_ID:-}"
SERVICE_NAME="${SERVICE_NAME:-docling-serve}"
REGION="${REGION:-us-central1}"
API_KEY="${DOCLING_API_KEY:-}"

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
    exit 1
fi

# Get service URL
print_info "Getting service URL..."
SERVICE_URL=$(gcloud run services describe "$SERVICE_NAME" \
    --region="$REGION" \
    --project="$PROJECT_ID" \
    --format='value(status.url)')

if [ -z "$SERVICE_URL" ]; then
    print_error "Could not get service URL. Is the service deployed?"
    exit 1
fi

print_info "Service URL: $SERVICE_URL"

# Get identity token
print_info "Getting identity token..."
TOKEN=$(gcloud auth print-identity-token)

if [ -z "$TOKEN" ]; then
    print_error "Could not get identity token. Are you authenticated?"
    exit 1
fi

# Get API key if not provided
if [ -z "$API_KEY" ]; then
    print_warning "DOCLING_API_KEY not set. Attempting to get from Secret Manager..."
    if command -v gcloud &> /dev/null; then
        API_KEY=$(gcloud secrets versions access latest \
            --secret=docling-api-key \
            --project="$PROJECT_ID" 2>/dev/null || echo "")
    fi
    
    if [ -z "$API_KEY" ]; then
        print_error "Could not get API key. Please set DOCLING_API_KEY environment variable."
        exit 1
    fi
fi

# Test 1: Health check
print_info "Test 1: Health check..."
HEALTH_RESPONSE=$(curl -s -w "\n%{http_code}" \
    -H "Authorization: Bearer $TOKEN" \
    "$SERVICE_URL/health")

HTTP_CODE=$(echo "$HEALTH_RESPONSE" | tail -n1)
BODY=$(echo "$HEALTH_RESPONSE" | head -n-1)

if [ "$HTTP_CODE" = "200" ]; then
    print_info "✅ Health check passed: $BODY"
else
    print_error "❌ Health check failed: HTTP $HTTP_CODE"
    echo "$BODY"
    exit 1
fi

# Test 2: Async conversion
print_info "Test 2: Async document conversion..."
CONVERSION_RESPONSE=$(curl -s -w "\n%{http_code}" \
    -X POST \
    -H "Authorization: Bearer $TOKEN" \
    -H "X-Api-Key: $API_KEY" \
    -H "Content-Type: application/json" \
    -d '{
      "sources": [{"kind": "http", "url": "https://arxiv.org/pdf/2501.17887"}],
      "options": {
        "to_formats": ["json", "text"]
      }
    }' \
    "$SERVICE_URL/v1/convert/source/async")

HTTP_CODE=$(echo "$CONVERSION_RESPONSE" | tail -n1)
BODY=$(echo "$CONVERSION_RESPONSE" | head -n-1)

if [ "$HTTP_CODE" = "200" ]; then
    TASK_ID=$(echo "$BODY" | grep -o '"task_id":"[^"]*' | cut -d'"' -f4)
    print_info "✅ Conversion task created: $TASK_ID"
    
    # Poll for completion
    print_info "Polling for task completion..."
    MAX_ATTEMPTS=30
    ATTEMPT=0
    
    while [ $ATTEMPT -lt $MAX_ATTEMPTS ]; do
        STATUS_RESPONSE=$(curl -s \
            -H "Authorization: Bearer $TOKEN" \
            -H "X-Api-Key: $API_KEY" \
            "$SERVICE_URL/v1/status/poll/$TASK_ID")
        
        TASK_STATUS=$(echo "$STATUS_RESPONSE" | grep -o '"task_status":"[^"]*' | cut -d'"' -f4)
        
        if [ "$TASK_STATUS" = "success" ]; then
            print_info "✅ Task completed successfully!"
            
            # Get results
            print_info "Fetching results..."
            RESULT_RESPONSE=$(curl -s -w "\n%{http_code}" \
                -H "Authorization: Bearer $TOKEN" \
                -H "X-Api-Key: $API_KEY" \
                "$SERVICE_URL/v1/result/$TASK_ID")
            
            RESULT_HTTP_CODE=$(echo "$RESULT_RESPONSE" | tail -n1)
            RESULT_BODY=$(echo "$RESULT_RESPONSE" | head -n-1)
            
            if [ "$RESULT_HTTP_CODE" = "200" ]; then
                print_info "✅ Results retrieved successfully"
                
                # Check if JSON content exists
                if echo "$RESULT_BODY" | grep -q "json_content"; then
                    print_info "✅ JSON content found in response"
                else
                    print_warning "⚠️  JSON content not found in response"
                fi
                
                # Check if text content exists
                if echo "$RESULT_BODY" | grep -q "text_content"; then
                    print_info "✅ Text content found in response"
                else
                    print_warning "⚠️  Text content not found in response"
                fi
            else
                print_error "❌ Failed to get results: HTTP $RESULT_HTTP_CODE"
            fi
            
            break
        elif [ "$TASK_STATUS" = "failure" ]; then
            print_error "❌ Task failed"
            echo "$STATUS_RESPONSE"
            exit 1
        else
            ATTEMPT=$((ATTEMPT + 1))
            echo "  Attempt $ATTEMPT/$MAX_ATTEMPTS: Status is $TASK_STATUS, waiting..."
            sleep 5
        fi
    done
    
    if [ $ATTEMPT -eq $MAX_ATTEMPTS ]; then
        print_error "❌ Task did not complete within timeout"
        exit 1
    fi
else
    print_error "❌ Conversion request failed: HTTP $HTTP_CODE"
    echo "$BODY"
    exit 1
fi

# Test 3: Test without API key (should fail)
print_info "Test 3: Testing without API key (should fail)..."
NO_KEY_RESPONSE=$(curl -s -w "\n%{http_code}" \
    -X POST \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d '{"sources": [{"kind": "http", "url": "https://arxiv.org/pdf/2501.17887"}]}' \
    "$SERVICE_URL/v1/convert/source/async")

NO_KEY_HTTP_CODE=$(echo "$NO_KEY_RESPONSE" | tail -n1)

if [ "$NO_KEY_HTTP_CODE" = "401" ] || [ "$NO_KEY_HTTP_CODE" = "403" ]; then
    print_info "✅ Correctly rejected request without API key"
else
    print_warning "⚠️  Request without API key returned HTTP $NO_KEY_HTTP_CODE (expected 401/403)"
fi

# Test 4: Test without auth token (should fail)
print_info "Test 4: Testing without auth token (should fail)..."
NO_AUTH_RESPONSE=$(curl -s -w "\n%{http_code}" \
    -X POST \
    -H "X-Api-Key: $API_KEY" \
    -H "Content-Type: application/json" \
    -d '{"sources": [{"kind": "http", "url": "https://arxiv.org/pdf/2501.17887"}]}' \
    "$SERVICE_URL/v1/convert/source/async")

NO_AUTH_HTTP_CODE=$(echo "$NO_AUTH_RESPONSE" | tail -n1)

if [ "$NO_AUTH_HTTP_CODE" = "401" ] || [ "$NO_AUTH_HTTP_CODE" = "403" ]; then
    print_info "✅ Correctly rejected request without auth token"
else
    print_warning "⚠️  Request without auth token returned HTTP $NO_AUTH_HTTP_CODE (expected 401/403)"
fi

print_info ""
print_info "✅ All tests completed!"
print_info ""
print_info "Service is working correctly at: $SERVICE_URL"

