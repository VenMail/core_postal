#!/bin/bash

# Build and push Docker image for Postal
# Equivalent to winbuild.cmd

echo "Building Docker image..."
docker build -t ghcr.io/venmail/postal:latest .

echo "Tagging image with version..."
docker tag ghcr.io/venmail/postal:latest ghcr.io/venmail/postal:2.8.11

echo "Pushing latest tag..."
docker push ghcr.io/venmail/postal:latest

echo "Pushing version tag..."
docker push ghcr.io/venmail/postal:2.8.11

echo "Build and push completed successfully!"
