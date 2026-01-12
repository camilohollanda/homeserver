#!/bin/bash
set -euo pipefail

# Check if running as root
if [ "$EUID" -ne 0 ]; then
  echo "Error: This script must be run as root (use sudo)"
  exit 1
fi

# Set up kubeconfig
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

echo "Setting up Argo CD access to private GitHub repository..."
echo ""

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
  echo "Error: kubectl is not available. Make sure K3s is installed."
  exit 1
fi

# Check if Argo CD namespace exists
if ! kubectl get namespace argocd &>/dev/null; then
  echo "Error: Argo CD namespace not found. Please install Argo CD first."
  exit 1
fi

echo "This script will help you configure Argo CD to access a private GitHub repository."
echo ""
echo "You have two options:"
echo "1. SSH Deploy Key (recommended for single repository)"
echo "2. GitHub App (recommended for multiple repositories)"
echo ""
read -p "Choose option (1 or 2): " option

case $option in
  1)
    echo ""
    echo "=== SSH Deploy Key Setup ==="
    echo ""
    echo "Step 1: Generate SSH key pair"
    read -p "Enter a name for the SSH key (e.g., argocd-github): " key_name
    key_name="${key_name:-argocd-github}"

    KEY_DIR="/tmp/argocd-keys"
    mkdir -p "$KEY_DIR"
    KEY_PATH="$KEY_DIR/$key_name"

    echo "Generating SSH key..."
    ssh-keygen -t ed25519 -f "$KEY_PATH" -N "" -C "argocd@homeserver"

    echo ""
    echo "Step 2: Add the public key to GitHub"
    echo "1. Go to your GitHub repository"
    echo "2. Settings → Deploy keys → Add deploy key"
    echo "3. Paste the public key below:"
    echo ""
    echo "--- Public Key ---"
    cat "${KEY_PATH}.pub"
    echo "--- End Public Key ---"
    echo ""
    read -p "Press Enter after you've added the deploy key to GitHub..."

    echo ""
    echo "Step 3: Create Argo CD secret"
    read -p "Enter GitHub repository URL (e.g., git@github.com:username/repo.git): " repo_url

    # Create secret with SSH key
    kubectl create secret generic argocd-repo-credentials \
      --from-file=sshPrivateKey="$KEY_PATH" \
      --from-literal=type=git \
      --from-literal=url="$repo_url" \
      -n argocd \
      --dry-run=client -o yaml | kubectl apply -f -

    echo ""
    echo "Step 4: Create repository secret in Argo CD"

    # Remove old secret if exists
    kubectl delete secret github-repo -n argocd 2>/dev/null || true

    # Create new secret with proper format
    kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: github-repo
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
type: Opaque
stringData:
  type: git
  url: ${repo_url}
  sshPrivateKey: |
$(sed 's/^/    /' "$KEY_PATH")
EOF

    echo ""
    echo "Step 5: Restarting Argo CD repo-server to pick up new secret..."
    kubectl delete pod -n argocd -l app.kubernetes.io/name=argocd-repo-server --wait=false 2>/dev/null || true
    sleep 3

    echo ""
    echo "✓ Argo CD repository configured!"
    echo ""
    echo "Repository URL: ${repo_url}"
    echo ""
    echo "To verify:"
    echo "1. Wait a few seconds for repo-server to restart"
    echo "2. Check Argo CD UI → Settings → Repositories"
    echo "3. The repository should show 'Successful' status"
    echo ""
    echo "If connection fails, run diagnostics:"
    echo "  sudo ~/bootstrap/argocd-repo-debug.sh"

    # Clean up temporary keys (optional - user might want to keep them)
    read -p "Delete temporary key files? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
      rm -rf "$KEY_DIR"
      echo "Temporary keys deleted."
    else
      echo "Keys kept at: $KEY_DIR"
    fi
    ;;

  2)
    echo ""
    echo "=== GitHub App Setup ==="
    echo ""
    echo "Step 1: Create a GitHub App"
    echo "1. Go to: https://github.com/settings/apps/new"
    echo "2. Fill in:"
    echo "   - GitHub App name: ArgoCD-HomeServer"
    echo "   - Homepage URL: https://github.com"
    echo "   - Webhook: Leave unchecked (or configure if needed)"
    echo "   - Repository permissions:"
    echo "     - Contents: Read-only"
    echo "     - Metadata: Read-only"
    echo "3. Click 'Create GitHub App'"
    echo ""
    read -p "Press Enter after creating the GitHub App..."

    echo ""
    echo "Step 2: Generate and download private key"
    echo "1. After creating the app, click 'Generate a private key'"
    echo "2. Download the .pem file"
    echo ""
    read -p "Enter the path to the downloaded .pem file: " pem_path

    if [ ! -f "$pem_path" ]; then
      echo "Error: File not found: $pem_path"
      exit 1
    fi

    # Validate private key format
    echo ""
    echo "Validating private key format..."
    if ! grep -q "BEGIN RSA PRIVATE KEY" "$pem_path" && ! grep -q "BEGIN PRIVATE KEY" "$pem_path"; then
      echo "Error: The file does not appear to be a valid private key (missing BEGIN marker)"
      exit 1
    fi
    if ! grep -q "END RSA PRIVATE KEY" "$pem_path" && ! grep -q "END PRIVATE KEY" "$pem_path"; then
      echo "Error: The file does not appear to be a valid private key (missing END marker)"
      exit 1
    fi
    echo "✓ Private key format looks valid"

    echo ""
    echo "Step 3: Install the GitHub App on your repository"
    echo "1. Go to your GitHub App settings"
    echo "2. Click 'Install App'"
    echo "3. Select your repository or organization"
    echo ""
    read -p "Press Enter after installing the app on your repository..."

    echo ""
    read -p "Enter GitHub App ID: " app_id
    read -p "Enter GitHub App Installation ID: " installation_id
    read -p "Enter repository URL (e.g., https://github.com/username/repo): " repo_url

    # Ensure IDs are treated as strings
    app_id="${app_id}"
    installation_id="${installation_id}"

    echo ""
    echo "Step 4: Remove old secret if exists"
    kubectl delete secret github-repo -n argocd 2>/dev/null || true

    echo ""
    echo "Step 5: Test network connectivity to GitHub API"
    echo "Testing connection to api.github.com..."
    if curl -s -o /dev/null -w "%{http_code}" --connect-timeout 10 https://api.github.com > /dev/null 2>&1; then
      echo "✓ Network connectivity to GitHub API is working"
    else
      echo "⚠ Warning: Cannot reach GitHub API. This may cause connection issues."
      echo "  Check firewall rules and network connectivity."
    fi
    echo ""

    echo "Step 6: Create repository secret in Argo CD"
    # Create a temporary file with properly formatted key (ensure no trailing spaces, correct line endings)
    TEMP_KEY=$(mktemp)
    # Remove any Windows line endings and ensure proper formatting
    sed 's/\r$//' "$pem_path" > "$TEMP_KEY"

    # Use kubectl create secret with --from-literal to ensure IDs are stored as strings
    # This is more reliable than YAML stringData which can be interpreted as numbers
    kubectl create secret generic github-repo \
      --from-literal=type=git \
      --from-literal=url="${repo_url}" \
      --from-literal=githubAppID="${app_id}" \
      --from-literal=githubAppInstallationID="${installation_id}" \
      --from-file=githubAppPrivateKey="$TEMP_KEY" \
      -n argocd \
      --dry-run=client -o yaml | kubectl apply -f -

    # Add label
    kubectl label secret github-repo -n argocd argocd.argoproj.io/secret-type=repository --overwrite

    # Clean up temp file
    rm -f "$TEMP_KEY"

    echo ""
    echo "Step 7: Restart Argo CD repo-server to pick up new secret"
    kubectl delete pod -n argocd -l app.kubernetes.io/name=argocd-repo-server 2>/dev/null || true
    echo "  Waiting for repo-server to restart..."
    sleep 5

    echo ""
    echo "✓ Argo CD repository configured with GitHub App!"
    echo ""
    echo "You can now use this repository URL in Argo CD Applications:"
    echo "  ${repo_url}"
    echo ""
    echo "If you see TLS handshake errors, check:"
    echo "1. Network connectivity: kubectl exec -n argocd -l app.kubernetes.io/name=argocd-repo-server -- curl -v https://api.github.com"
    echo "2. Certificate issues: The repo-server pod may need updated CA certificates"
    echo "3. Private key format: Ensure the .pem file is correctly formatted"
    echo ""
    echo "To check repo-server logs:"
    echo "  kubectl logs -n argocd -l app.kubernetes.io/name=argocd-repo-server --tail=50 -f"
    ;;

  *)
    echo "Invalid option. Exiting."
    exit 1
    ;;
esac

echo ""
echo "To verify the repository connection:"
echo "1. Access Argo CD UI"
echo "2. Go to Settings → Repositories"
echo "3. Check if your repository appears and shows 'Successful' status"
