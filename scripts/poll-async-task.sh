#!/bin/bash
# Script to poll async task status and fetch results when complete

set -e

PROJECT_ID="${GCP_PROJECT_ID:-crafty-cairn-474720-q9}"
SERVICE_URL="${SERVICE_URL:-https://docling-serve-8252053021.us-central1.run.app}"
TASK_ID="${1:-}"

if [ -z "$TASK_ID" ]; then
    echo "Usage: $0 <task_id>"
    echo "Example: $0 1b2cf727-8804-4897-a579-60ddd9bdbee2"
    exit 1
fi

# Get credentials
TOKEN=$(gcloud auth print-identity-token)
API_KEY=$(gcloud secrets versions access latest --secret=docling-api-key --project=$PROJECT_ID)

echo "Polling task: $TASK_ID"
echo "Service: $SERVICE_URL"
echo ""

MAX_ATTEMPTS=60
ATTEMPT=0

while [ $ATTEMPT -lt $MAX_ATTEMPTS ]; do
    ATTEMPT=$((ATTEMPT + 1))
    
    # Get status
    STATUS_RESPONSE=$(curl -s -H "Authorization: Bearer $TOKEN" \
        -H "X-Api-Key: $API_KEY" \
        "$SERVICE_URL/v1/status/poll/$TASK_ID")
    
    STATUS=$(echo "$STATUS_RESPONSE" | jq -r '.task_status')
    TASK_META=$(echo "$STATUS_RESPONSE" | jq -r '.task_meta // empty')
    
    echo "[$ATTEMPT/$MAX_ATTEMPTS] Status: $STATUS"
    if [ -n "$TASK_META" ] && [ "$TASK_META" != "null" ]; then
        echo "  Meta: $TASK_META"
    fi
    
    if [ "$STATUS" = "success" ]; then
        echo ""
        echo "✅ Task completed! Fetching results..."
        echo ""
        
        # Fetch results
        RESULT=$(curl -s -H "Authorization: Bearer $TOKEN" \
            -H "X-Api-Key: $API_KEY" \
            "$SERVICE_URL/v1/result/$TASK_ID")
        
        # Save to file
        OUTPUT_FILE="task_${TASK_ID}_result.json"
        echo "$RESULT" | jq . > "$OUTPUT_FILE"
        
        echo "Results saved to: $OUTPUT_FILE"
        echo ""
        echo "=== Summary ==="
        echo "Total chunks: $(echo "$RESULT" | jq '.chunks | length')"
        echo ""
        
        # Show first chunk structure
        echo "=== First Chunk Structure ==="
        echo "$RESULT" | jq '.chunks[0] | keys'
        echo ""
        
        # Show first chunk with metadata
        echo "=== First Chunk Sample ==="
        echo "$RESULT" | jq '.chunks[0] | {
            text_preview: (.text | .[0:200]),
            metadata: .metadata
        }'
        echo ""
        
        # Check for bounding box
        echo "=== Bounding Box Check ==="
        echo "$RESULT" | jq '.chunks[0].metadata | {
            has_box: (.box != null),
            box: .box,
            has_page: (.page != null),
            page: .page,
            has_bbox: (.bbox != null),
            bbox: .bbox
        }'
        
        exit 0
    elif [ "$STATUS" = "failure" ]; then
        echo ""
        echo "❌ Task failed!"
        echo "$STATUS_RESPONSE" | jq .
        exit 1
    fi
    
    sleep 5
done

echo ""
echo "⏰ Timeout: Task did not complete within $((MAX_ATTEMPTS * 5)) seconds"
echo "Current status: $STATUS"
exit 1

