#!/bin/bash

set -e  # Exit immediately if any command exits with a non-zero status

trap 'echo "Script failed at line $LINENO with exit code $?"' ERR

# Function to display usage
usage() {
    echo "Usage: $0 --hostname <hostname> --control-plane <yes|no>"
    echo
    echo "Arguments:"
    echo "  --hostname        Hostname to set for this node."
    echo "  --control-plane   Specify if this is a control plane node (yes or no)."
    exit 1
}

# Parse arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --hostname) HOST_NAME="$2"; shift ;;
        --control-plane) CONTROL_PLANE="$2"; shift ;;
        --help|-h) usage ;;
        *) echo "Unknown parameter: $1"; usage ;;
    esac
    shift
done

# Check if required arguments are provided
if [[ -z "$HOST_NAME" || -z "$CONTROL_PLANE" ]]; then
    echo "Error: Missing required arguments."
    usage
fi

# Set hostname
hostnamectl set-hostname "$HOST_NAME"

# Check if script is run as root
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root or with sudo."
    exit 1
fi

# Check system requirements
echo "Checking memory and CPU requirements..."
CORES=$(nproc)
MEM=$(free -g | awk '/^Mem/ {print $2}')
if [[ "$CORES" -lt 2 ]] || [[ "$MEM" -lt 2 ]]; then
    echo "CPU or memory is below minimum requirements."
    exit 1
fi

# Disable swap
echo "Disabling swap..."
swapoff -a

# Enable port forwarding
echo "Enabling port forwarding..."
echo "net.ipv4.ip_forward = 1" | tee /etc/sysctl.d/k8s.conf > /dev/null
sysctl --system > /dev/null 2>&1

if ! grep -q "net.ipv4.ip_forward = 1" /etc/sysctl.d/k8s.conf; then
    echo "IP forwarding not enabled. Exiting."
    exit 1
fi

# Detect OS and version
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
    VERSION_ID=$VERSION_ID
else
    echo "Cannot detect OS version."
    exit 1
fi

# Function to install packages based on OS
install_packages() {
    case "$OS" in
        "ubuntu"|"debian")
            apt-get update -y -qq && apt-get upgrade -y -qq
            apt-get install -y "$@" -qq
            ;;
        "rhel"|"centos"|"fedora"|"rocky"|"almalinux"|"amzn")
            dnf update -y -q
            dnf install -y "$@" -q
            ;;
        *)
            echo "Unsupported OS: $OS"
            exit 1
            ;;
    esac
}

# Ensure required tools are installed
case "$OS" in
    "ubuntu"|"debian")
        install_packages jq iproute2
        ;;
    "rhel"|"centos"|"fedora"|"rocky"|"almalinux"|"amzn")
        install_packages jq iproute iproute-tc
        ;;
esac

# Detect architecture and download/install containerd, runc, and CNI plugins
ARCH=$(uname -m)
echo "Detected architecture: $ARCH"

CONTAINERD_VERSION=$(curl -sSL "https://api.github.com/repos/containerd/containerd/releases/latest" | jq -r '.tag_name' | sed 's/^v//')
RUNC_VERSION=$(curl -sSL "https://api.github.com/repos/opencontainers/runc/releases/latest" | jq -r '.tag_name')
CNI_VERSION=$(curl -sSL "https://api.github.com/repos/containernetworking/plugins/releases/latest" | jq -r '.tag_name')

if [[ "$ARCH" == "x86_64" ]]; then
    # Install containerd
    echo "Installing containerd..."
    wget -q "https://github.com/containerd/containerd/releases/download/v${CONTAINERD_VERSION}/containerd-${CONTAINERD_VERSION}-linux-amd64.tar.gz"
    tar Cxzf /usr/local "containerd-${CONTAINERD_VERSION}-linux-amd64.tar.gz"
    rm "containerd-${CONTAINERD_VERSION}-linux-amd64.tar.gz"
    if ! command -v containerd >/dev/null 2>&1; then
        echo "containerd installation failed."
        exit 1
    fi
    mkdir -p /usr/local/lib/systemd/system/
    curl -o /usr/local/lib/systemd/system/containerd.service https://raw.githubusercontent.com/containerd/containerd/main/containerd.service
    systemctl daemon-reload
    systemctl enable --now containerd

    # Install runc
    echo "Installing runc..."
    wget -q "https://github.com/opencontainers/runc/releases/download/${RUNC_VERSION}/runc.amd64"
    install -m 755 runc.amd64 /usr/local/sbin/runc

    # Install CNI plugins
    echo "Installing CNI plugin..."
    mkdir -p /opt/cni/bin
    wget -q "https://github.com/containernetworking/plugins/releases/download/${CNI_VERSION}/cni-plugins-linux-amd64-${CNI_VERSION}.tgz"
    tar Cxzf /opt/cni/bin "cni-plugins-linux-amd64-${CNI_VERSION}.tgz"
    rm "cni-plugins-linux-amd64-${CNI_VERSION}.tgz"
else
    echo "Unsupported architecture: $ARCH"
    exit 1
fi

# Configure containerd
echo "Configuring containerd..."
mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml

config_file="/etc/containerd/config.toml"
sed -i 's/disabled_plugins.*cri.*/disabled_plugins = []/' "$config_file"
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' "$config_file"
sed -i "/\[plugins\.'io\.containerd\.grpc\.v1\.cri'\]/a\    sandbox_image = \"registry.k8s.io\/pause:3.10\"" "$config_file"

systemctl restart containerd

# Install Kubernetes components
echo "Installing Kubernetes components..."
RELEASE="$(curl -sSL https://dl.k8s.io/release/stable.txt)"
RELEASE="${RELEASE%.*}"

case "$OS" in
    "ubuntu"|"debian")
        install_packages apt-transport-https ca-certificates curl gpg
        curl -fsSL "https://pkgs.k8s.io/core:/stable:/${RELEASE}/deb/Release.key" | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
        echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${RELEASE}/deb/ /" > /etc/apt/sources.list.d/kubernetes.list
        apt-get update -qq
        install_packages kubelet kubeadm
        apt-mark hold kubelet kubeadm
        systemctl enable --now kubelet
        ;;
    "rhel"|"centos"|"fedora"|"rocky"|"almalinux"|"amzn")
        setenforce 0
        sed -i 's/^SELINUX=enforcing$/SELINUX=permissive/' /etc/selinux/config
        cat <<EOF > /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/${RELEASE}/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/${RELEASE}/rpm/repodata/repomd.xml.key
EOF
        install_packages kubelet kubeadm
        systemctl enable kubelet
        ;;
esac

# Handle control plane setup
if [[ "${CONTROL_PLANE,,}" == "yes" ]]; then
    echo "Setting up control plane..."
    kubeadm init --pod-network-cidr=192.168.0.0/16

    USER_HOME=$(eval echo ~${SUDO_USER:-$USER})
    mkdir -p "$USER_HOME/.kube"
    cp -i /etc/kubernetes/admin.conf "$USER_HOME/.kube/config"
    chown "$(id -u ${SUDO_USER:-$USER}):$(id -g ${SUDO_USER:-$USER})" "$USER_HOME/.kube/config"

    echo "******************************************"
    echo "            Join Command                 "
    echo "******************************************"
    kubeadm token create --print-join-command
    echo "******************************************"
else
    echo "Worker node setup complete. Use 'kubeadm join' to connect to the cluster."
fi

echo "Installation completed successfully."
