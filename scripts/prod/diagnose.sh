#!/usr/bin/env bash
set -euo pipefail

#################################################################
# Diagnostic Script - Check what's happening with prod-start.sh
#
# Usage: ./scripts/prod/diagnose.sh
#
# This script will help identify where ./scripts/prod/prod-start.sh is stopping
#################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

cd "$SCRIPT_DIR"

echo "=========================================="
echo "Cloud Setup Diagnostic Script"
echo "=========================================="
echo ""

# Check 1: Prerequisites
echo "✓ Checking prerequisites..."
echo ""

if ! command -v terraform &> /dev/null; then
  echo "  ✗ terraform NOT FOUND"
  echo "    Install with: brew install terraform"
else
  echo "  ✓ terraform: $(terraform version -json | jq -r '.terraform_version')"
fi

if ! command -v jq &> /dev/null; then
  echo "  ✗ jq NOT FOUND"
  echo "    Install with: brew install jq"
else
  echo "  ✓ jq: installed"
fi

if ! command -v psql &> /dev/null; then
  echo "  ✗ psql NOT FOUND"
  echo "    Install with: brew install postgresql"
else
  echo "  ✓ psql: $(psql --version)"
fi

echo ""
echo "=========================================="
echo "✓ Checking configuration files..."
echo "=========================================="
echo ""

if [ ! -f "terraform.tf" ]; then
  echo "  ✗ terraform.tf NOT FOUND"
  exit 1
else
  echo "  ✓ terraform.tf exists"
fi

if [ ! -f "terraform.tfvars" ]; then
  echo "  ✗ terraform.tfvars NOT FOUND"
  echo "    Create it with:"
  echo "    cat > terraform.tfvars << 'EOF'"
  echo "    do_token = \"dop_v1_YOUR_TOKEN\""
  echo "    region = \"nyc3\""
  echo "    EOF"
  exit 1
else
  echo "  ✓ terraform.tfvars exists"
fi

# Check the token
DO_TOKEN=$(grep "^do_token" terraform.tfvars | awk -F'"' '{print $2}')
if [ -z "$DO_TOKEN" ]; then
  echo "  ✗ DigitalOcean token not found in terraform.tfvars"
  exit 1
else
  echo "  ✓ DigitalOcean token found (starts with: ${DO_TOKEN:0:10}...)"
fi

echo ""
echo "=========================================="
echo "✓ Testing DigitalOcean API access..."
echo "=========================================="
echo ""

if curl -s -H "Authorization: Bearer $DO_TOKEN" https://api.digitalocean.com/v2/account | jq .account > /dev/null 2>&1; then
  echo "  ✓ DigitalOcean API access: OK"
else
  echo "  ✗ DigitalOcean API access FAILED"
  echo "    Check your token in terraform.tfvars"
  exit 1
fi

echo ""
echo "=========================================="
echo "✓ Testing Terraform..."
echo "=========================================="
echo ""

# Initialize terraform if needed
if [ ! -d ".terraform" ]; then
  echo "  → Initializing terraform..."
  terraform init > /dev/null 2>&1
  echo "  ✓ Terraform initialized"
else
  echo "  ✓ Terraform already initialized"
fi

# Run plan
echo "  → Running terraform plan..."
if terraform plan -var-file="terraform.tfvars" > /tmp/tf_plan.txt 2>&1; then
  RESOURCE_COUNT=$(grep -c "will be created" /tmp/tf_plan.txt || echo "0")
  echo "  ✓ Terraform plan succeeded"
  echo "    Resources to create: $RESOURCE_COUNT"
  echo ""
  echo "    Details:"
  grep "Plan:" /tmp/tf_plan.txt || true
else
  echo "  ✗ Terraform plan FAILED"
  echo ""
  echo "    Error output:"
  cat /tmp/tf_plan.txt | tail -20
  exit 1
fi

echo ""
echo "=========================================="
echo "✅ All checks passed!"
echo "=========================================="
echo ""
echo "Next step: Run ./scripts/prod/prod-start.sh"
echo ""
echo "When it asks 'Continue with creation? (yes/no)'"
echo "Type: yes"
echo "Then press: Enter"
echo ""
echo "Wait 3-5 minutes for infrastructure to be created."
echo ""
