#!/bin/bash
set -euo pipefail

# Compatible with Ubuntu 24.04 Noble
# Installs:
#   - CRI-O v1.32
#   - kubeadm/kubelet/kubectl v1.32
#
# Note:
# Keep CRI-O and Kubernetes on the same minor version unless you have
# a specific compatibility reason to do otherwise.

KUBERNETES_VERSION="v1.32"
CRIO_VERSION="v1.32"

echo "==> Checking OS version..."
. /etc/os-release

if [[ "${ID}" != "ubuntu" || "${VERSION_ID}" != "24.04" ]]; then
    echo "ERROR: This script is intended for Ubuntu 24.04 only."
    echo "Detected: ${PRETTY_NAME}"
    exit 1
fi

echo "==> Updating system and installing prerequisites..."
sudo apt-get update
sudo apt-get install -y \
    apt-transport-https \
    ca-certificates \
    curl \
    gpg \
    software-properties-common \
    bash-completion \
    iptables \
    containernetworking-plugins

echo "==> Disabling swap..."
sudo swapoff -a
sudo sed -i.bak '/[[:space:]]swap[[:space:]]/ s/^/#/' /etc/fstab

echo "==> Loading Kubernetes required kernel modules..."
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf >/dev/null
overlay
br_netfilter
EOF

sudo modprobe overlay
sudo modprobe br_netfilter

echo "==> Applying Kubernetes networking sysctl settings..."
cat <<EOF | sudo tee /etc/sysctl.d/99-kubernetes-cri.conf >/dev/null
net.ipv4.ip_forward = 1
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF

sudo sysctl --system

echo "==> Preparing APT keyrings..."
sudo mkdir -p -m 755 /etc/apt/keyrings

echo "==> Removing old Kubernetes / CRI-O repository files if they exist..."
sudo rm -f /etc/apt/sources.list.d/kubernetes.list
sudo rm -f /etc/apt/sources.list.d/cri-o.list
sudo rm -f /etc/apt/sources.list.d/devel:kubic:libcontainers:stable.list
sudo rm -f /etc/apt/sources.list.d/devel:kubic:libcontainers:stable:cri-o:*.list

echo "==> Adding Kubernetes ${KUBERNETES_VERSION} repository..."
curl -fsSL "https://pkgs.k8s.io/core:/stable:/${KUBERNETES_VERSION}/deb/Release.key" | \
    sudo gpg --batch --yes --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${KUBERNETES_VERSION}/deb/ /" | \
    sudo tee /etc/apt/sources.list.d/kubernetes.list >/dev/null

echo "==> Adding CRI-O ${CRIO_VERSION} repository..."
curl -fsSL "https://download.opensuse.org/repositories/isv:/cri-o:/stable:/${CRIO_VERSION}/deb/Release.key" | \
    sudo gpg --batch --yes --dearmor -o /etc/apt/keyrings/cri-o-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/cri-o-apt-keyring.gpg] https://download.opensuse.org/repositories/isv:/cri-o:/stable:/${CRIO_VERSION}/deb/ /" | \
    sudo tee /etc/apt/sources.list.d/cri-o.list >/dev/null

echo "==> Installing CRI-O and Kubernetes tools..."
sudo apt-get update
sudo apt-get install -y \
    cri-o \
    kubelet \
    kubeadm \
    kubectl \
    cri-tools

echo "==> Holding Kubernetes packages..."
sudo apt-mark hold kubelet kubeadm kubectl

echo "==> Configuring crictl to use CRI-O..."
cat <<EOF | sudo tee /etc/crictl.yaml >/dev/null
runtime-endpoint: unix:///var/run/crio/crio.sock
image-endpoint: unix:///var/run/crio/crio.sock
timeout: 10
debug: false
EOF

echo "==> Enabling and starting CRI-O..."
sudo systemctl daemon-reload
sudo systemctl enable --now crio

echo "==> Enabling kubelet..."
sudo systemctl enable kubelet

echo "==> Installing crictl bash completion..."
if command -v crictl >/dev/null 2>&1; then
    crictl completion bash | sudo tee /etc/bash_completion.d/crictl >/dev/null
fi

echo "==> Verifying installation..."
crio --version
kubectl version --client=true
kubeadm version
sudo crictl version

echo "==> Done."
echo
echo "Next step for control-plane node:"
echo "  sudo kubeadm init --cri-socket unix:///var/run/crio/crio.sock"
echo
echo "After kubeadm init, install a CNI plugin such as Calico, Cilium, or Flannel."
