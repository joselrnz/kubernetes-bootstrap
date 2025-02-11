# Kubernetes Node Setup Script

## Overview

This Bash script automates the setup of a Kubernetes node, supporting both control plane (master) and worker node configurations. It performs system validation, installs required components, and configures the system for Kubernetes deployment.

## Features

- Validates system requirements (CPU, memory)
- Disables swap (required for Kubernetes)
- Enables IP forwarding
- Installs `containerd`, `runc`, and CNI plugins
- Installs Kubernetes components (`kubelet`, `kubeadm`, `kubectl`)
- Configures the control plane (if applicable)
- Provides the `kubeadm join` command for worker nodes

## Script Breakdown

### 1. Error Handling and Logging

- `set -e`: Ensures the script exits immediately if any command fails.
- `trap 'log_error "Script failed at line $LINENO with exit code $?"' ERR`: Captures and logs errors.
- `log_info` and `log_error`: Custom functions for logging informational and error messages with timestamps.

### 2. Command-Line Arguments Parsing

The script accepts two required parameters:
- `--hostname <hostname>`: Specifies the hostname for the node.
- `--control-plane <yes|no>`: Defines whether the node is a control plane node.

If these arguments are missing, the script exits with a usage message.

### 3. Root Privileges Check

Ensures the script runs as `root` or with `sudo`. If not, it exits with an error.

### 4. System Configuration

#### Setting Hostname

Uses `hostnamectl set-hostname <hostname>` to set the system hostname.

#### Checking System Requirements

- Requires at least **2 CPU cores** and **2GB RAM**.
- Retrieves CPU count using `nproc` and memory size using `free -g`.

#### Disabling Swap

- Disables swap temporarily with `swapoff -a`.
- Ensures swap is permanently disabled by modifying `/etc/fstab`.

#### Enabling IP Forwarding

- Sets `net.ipv4.ip_forward = 1` in `/etc/sysctl.d/k8s.conf`.
- Applies the change with `sysctl --system`.

### 5. Detecting OS and Architecture

- Reads `/etc/os-release` to identify the OS.
- Supports Ubuntu/Debian and RHEL/CentOS-based distributions.
- Detects system architecture using `uname -m`.

### 6. Installing Required Packages

- Uses `apt-get` (for Debian-based systems) or `dnf` (for RHEL-based systems) to install:
  - `jq`
  - `iproute2`

### 7. Installing and Configuring `containerd`, `runc`, and CNI Plugins

- Fetches the latest versions of `containerd`, `runc`, and CNI plugins from GitHub.
- Downloads and installs them.
- Configures `containerd` to use `SystemdCgroup = true`.

### 8. Installing Kubernetes Components

- Installs `kubelet`, `kubeadm`, and `kubectl`.
- Adds the Kubernetes package repository.
- Holds the Kubernetes versions to prevent unintended upgrades.

### 9. Control Plane Setup

If `--control-plane yes` is specified:

- Runs `kubeadm init --pod-network-cidr=192.168.0.0/16` to initialize the Kubernetes control plane.
- Configures the Kubernetes admin configuration in the user's home directory (`~/.kube/config`).
- Deploys Calico for networking.
- Displays the `kubeadm join` command for adding worker nodes.

### 10. Worker Node Setup

If the node is a worker (`--control-plane no`), the script provides instructions to join it to the cluster using `kubeadm join`.

## Usage

Run the script as root with the required parameters:

```bash
sudo ./setup-k8s-node.sh --hostname my-node --control-plane yes
```

For a worker node:

```bash
sudo ./setup-k8s-node.sh --hostname my-worker-node --control-plane no
```

## Overall

This script automates the preparation of a system for Kubernetes, ensuring all prerequisites are met and required components are installed. It simplifies setting up both control plane and worker nodes for a Kubernetes cluster.
