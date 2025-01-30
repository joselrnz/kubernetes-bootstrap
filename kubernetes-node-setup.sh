#!/bin/bash

set -e  # Exit immediately if any command fails
trap 'log_error "Script failed at line $LINENO with exit code $?"' ERR

# ==============================
# Function for logging
# ==============================

log_info() {
    local timestamp
    timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    echo "[$timestamp] INFO: $1"
}

log_error() {
    local timestamp
    timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    echo "[$timestamp] ERROR: $1" >&2
}

# ===================================
# Function to display script usage
# ===================================
usage() {
    echo "Usage: $0 --hostname <hostname> --control-plane <yes|no>"
    echo
    echo "Arguments:"
    echo "  --hostname        Set the hostname for this node."
    echo "  --control-plane   Specify if this is a control plane node (yes or no)."
    exit 1
}

# ===================================
# Parse command-line arguments
# ===================================
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --hostname) HOST_NAME="$2"; shift ;;
        --control-plane) CONTROL_PLANE="$2"; shift ;;
        --help|-h) usage ;;
        *) log_error "Unknown parameter: $1"; usage ;;
    esac
    shift
done

# Validate required arguments
if [[ -z "$HOST_NAME" || -z "$CONTROL_PLANE" ]]; then
    log_error "Missing required arguments."
    usage
fi

# ============================================
# Ensure script is run as root
# ============================================
if [[ $EUID -ne 0 ]]; then
    log_error "This script must be run as root or with sudo."
    exit 1
fi

# ============================================
# Set hostname
# ============================================
log_info "Setting hostname to $HOST_NAME..."
hostnamectl set-hostname "$HOST_NAME"

# ============================================
# Check system requirements (CPU & RAM)
# ============================================
log_info "Checking memory and CPU requirements..."
CORES=$(nproc)
MEM=$(free -g | awk '/^Mem/ {print $2}')
if [[ "$CORES" -lt 2 || "$MEM" -lt 2 ]]; then
    log_error "CPU or memory below minimum requirements (2 cores, 2GB RAM)."
    exit 1
fi

# ============================================
# Disable swap (Required for Kubernetes)
# ============================================
log_info "Disabling swap..."
swapoff -a

# Ensure swap is disabled permanently
sed -i '/ swap / s/^/#/' /etc/fstab

# ============================================
# Enable IP forwarding (Required for Networking)
# ============================================
log_info "Enabling IP forwarding..."
echo "net.ipv4.ip_forward = 1" > /etc/sysctl.d/k8s.conf
sysctl --system > /dev/null 2>&1

# Validate IP forwarding
if ! grep -q "net.ipv4.ip_forward = 1" /etc/sysctl.d/k8s.conf; then
    log_error "IP forwarding not enabled."
    exit 1
fi

# ============================================
# Detect OS and Version
# ============================================
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
elif [ -f /etc/redhat-release ]; then
    OS="rhel"
elif [ -f /etc/debian_version ]; then
    OS="debian"
else
    OS="unknown"
fi

log_info "Detected OS: $OS"

# ============================================
# Function to Install Packages Based on OS
# ============================================
install_packages() {
    log_info "Installing packages: $*"

    case "$OS" in
        "ubuntu"|"debian")
            log_info "Updating package lists..."
            DEBIAN_FRONTEND=noninteractive apt-get update -y -qq && apt-get upgrade -y -qq
            DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" -qq
            ;;
        "rhel"|"centos"|"fedora"|"rocky"|"almalinux"|"amzn")
            log_info "Updating package lists..."
            dnf update -y -q
            dnf install -y "$@" -q
            ;;
        *)
            log_error "Unsupported OS: $OS"
            exit 1
            ;;
    esac
}

# Install required system tools
install_packages jq iproute2

# ============================================
# Detect System Architecture
# ============================================
ARCH=$(uname -m)
log_info "Detected architecture: $ARCH"

# ============================================
# Install Kubernetes Components
# ============================================
log_info "Installing Kubernetes..."

case "$OS" in
    "ubuntu"|"debian")
        install_packages apt-transport-https ca-certificates curl gpg
        mkdir -p /etc/apt/keyrings
        curl -fsSL "https://pkgs.k8s.io/core:/stable:/v1.28/deb/Release.key" | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
        echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.28/deb/ /" > /etc/apt/sources.list.d/kubernetes.list
        apt-get update -qq
        install_packages kubelet kubeadm kubectl
        apt-mark hold kubelet kubeadm kubectl
        systemctl enable --now kubelet
        ;;
    "rhel"|"centos"|"fedora"|"rocky"|"almalinux"|"amzn")
        setenforce 0
        sed -i 's/^SELINUX=enforcing$/SELINUX=permissive/' /etc/selinux/config
        cat <<EOF > /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v1.28/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v1.28/rpm/repodata/repomd.xml.key
EOF
        install_packages kubelet kubeadm kubectl
        systemctl enable kubelet
        ;;
esac

# ============================================
# Kubernetes Control Plane Setup
# ============================================
if [[ "${CONTROL_PLANE,,}" == "yes" ]]; then
    log_info "Setting up control plane..."
    kubeadm init --pod-network-cidr=192.168.0.0/16

    USER_HOME=$(eval echo ~${SUDO_USER:-$USER})
    mkdir -p "$USER_HOME/.kube"
    cp -f /etc/kubernetes/admin.conf "$USER_HOME/.kube/config"
    chown "$(id -u ${SUDO_USER:-$USER}):$(id -g ${SUDO_USER:-$USER})" "$USER_HOME/.kube/config"

    kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/tigera-operator.yaml
    curl -O https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/custom-resources.yaml
    kubectl apply -f custom-resources.yaml

    log_info "##################  Join command:  ##################"
    kubeadm token create --print-join-command
    log_info "#####################################################"
else
    log_info "Worker node setup complete. Use 'kubeadm join' to connect to the cluster."
fi

log_info "Installation completed successfully."
