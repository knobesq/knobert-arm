#!/bin/bash
# Renamed to armstrap.sh — this redirects for backward compatibility
echo "NOTE: bootstrap.sh has been renamed to armstrap.sh"
echo "Fetching armstrap.sh..."
exec bash <(curl -fsSL https://knobesq.github.io/knobert-arm/armstrap.sh) "$@"
