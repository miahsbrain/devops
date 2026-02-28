#!/bin/bash
echo "Deleting k3d cluster: kustomize-demo..."
k3d cluster delete kustomize-demo
echo "✓ Done!"
