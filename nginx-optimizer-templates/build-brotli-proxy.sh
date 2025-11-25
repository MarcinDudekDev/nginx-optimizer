#!/bin/bash

# Build custom nginx-proxy with Brotli support
# Usage: ./build-brotli-proxy.sh [--update-wp-test]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_NAME="nginx-proxy-brotli"
IMAGE_TAG="latest"

echo "╔════════════════════════════════════════════════════════════╗"
echo "║     Building nginx-proxy with Brotli Support               ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""

# Check for Docker
if ! command -v docker &>/dev/null; then
    echo "Error: Docker not installed"
    exit 1
fi

# Build the image
echo "Building Docker image: ${IMAGE_NAME}:${IMAGE_TAG}"
echo "This may take 5-10 minutes..."
echo ""

docker build \
    -t "${IMAGE_NAME}:${IMAGE_TAG}" \
    -f "${SCRIPT_DIR}/Dockerfile.nginx-proxy-brotli" \
    "${SCRIPT_DIR}"

echo ""
echo "✓ Image built successfully: ${IMAGE_NAME}:${IMAGE_TAG}"

# Verify Brotli is working
echo ""
echo "Verifying Brotli module..."
if docker run --rm "${IMAGE_NAME}:${IMAGE_TAG}" nginx -V 2>&1 | grep -q "brotli"; then
    echo "✓ Brotli module compiled successfully"
else
    echo "⚠ Warning: Brotli module not detected in nginx -V output"
    echo "  (This may be okay if loaded as dynamic module)"
fi

# Test nginx configuration
echo ""
echo "Testing nginx configuration..."
if docker run --rm "${IMAGE_NAME}:${IMAGE_TAG}" nginx -t 2>&1; then
    echo "✓ nginx configuration valid"
else
    echo "✗ nginx configuration test failed"
    exit 1
fi

# Update wp-test if requested
if [ "$1" = "--update-wp-test" ]; then
    echo ""
    echo "Updating wp-test to use Brotli-enabled proxy..."

    WP_TEST_SCRIPT="$HOME/Tools/wp-test"

    if [ -f "$WP_TEST_SCRIPT" ]; then
        # Check if already using brotli image
        if grep -q "nginx-proxy-brotli" "$WP_TEST_SCRIPT"; then
            echo "✓ wp-test already configured for Brotli"
        else
            # Backup original
            cp "$WP_TEST_SCRIPT" "${WP_TEST_SCRIPT}.backup"

            # Replace jwilder/nginx-proxy with nginx-proxy-brotli
            sed -i.bak 's|jwilder/nginx-proxy|nginx-proxy-brotli:latest|g' "$WP_TEST_SCRIPT"

            echo "✓ wp-test updated to use nginx-proxy-brotli"
            echo "  Backup saved: ${WP_TEST_SCRIPT}.backup"
            echo ""
            echo "To apply changes, restart the proxy:"
            echo "  docker stop wp-test-proxy && docker rm wp-test-proxy"
            echo "  wp-test proxy start"
        fi
    else
        echo "⚠ wp-test script not found at $WP_TEST_SCRIPT"
    fi
fi

echo ""
echo "═══════════════════════════════════════════════════════════"
echo "Done!"
echo ""
echo "To use this image with wp-test:"
echo "  1. Stop current proxy: docker stop wp-test-proxy && docker rm wp-test-proxy"
echo "  2. Edit ~/Tools/wp-test and replace 'jwilder/nginx-proxy' with 'nginx-proxy-brotli:latest'"
echo "  3. Start proxy: wp-test proxy start"
echo ""
echo "Or run this script with --update-wp-test to automate step 2"
echo "═══════════════════════════════════════════════════════════"
