#!/bin/bash
set -euo pipefail

# Compatible with:
#   Red Hat Enterprise Linux 9.x
#
# Installs:
#   - CRI-O v1.32
#   - kubeadm v1.32
#   - kubelet v1.32
#   - kubectl v1.32
#   - cri-tools

KUBERNETES_VERSION="v1.32"
CRIO_VERSION="v1.32"

echo "==> Checking OS version..."
. /etc/os-release

if [[ "${ID}" != "rhel" || "${VERSION_ID%%.*}" != "9" ]]; then
    echo "ERROR: This script is intended for Red Hat Enterprise Linux 9.x only."
    echo "Detected: ${PRETTY_NAME}"
    exit 1
fi

echo "==> OS detected: ${PRETTY_NAME}"

echo "==> Updating package metadata..."
sudo dnf makecache -y

echo "==> Installing required base packages..."
sudo dnf install -y \
    ca-certificates \
    curl \
    gnupg2 \
    dnf-plugins-core \
    conntrack-tools \
    iproute-tc \
    iptables \
    socat \
    ethtool \
    bash-completion

echo "==> Setting SELinux to permissive..."
sudo setenforce 0 || true
sudo sed -i 's/^SELINUX=enforcing$/SELINUX=permissive/' /etc/selinux/config

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

echo "==> Removing old Kubernetes / CRI-O repo files if they exist..."
sudo rm -f /etc/yum.repos.d/kubernetes.repo
sudo rm -f /etc/yum.repos.d/cri-o.repo

echo "==> Adding Kubernetes ${KUBERNETES_VERSION} RPM repository..."
cat <<EOF | sudo tee /etc/yum.repos.d/kubernetes.repo >/dev/null
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/${KUBERNETES_VERSION}/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/${KUBERNETES_VERSION}/rpm/repodata/repomd.xml.key
exclude=kubelet kubeadm kubectl cri-tools kubernetes-cni
EOF

echo "==> Adding CRI-O ${CRIO_VERSION} RPM repository..."
cat <<EOF | sudo tee /etc/yum.repos.d/cri-o.repo >/dev/null
[cri-o]
name=CRI-O
baseurl=https://download.opensuse.org/repositories/isv:/cri-o:/stable:/${CRIO_VERSION}/rpm/
enabled=1
gpgcheck=1
gpgkey=https://download.opensuse.org/repositories/isv:/cri-o:/stable:/${CRIO_VERSION}/rpm/repodata/repomd.xml.key
EOF

echo "==> Refreshing package metadata..."
sudo dnf makecache -y

echo "==> Installing container-selinux..."
sudo dnf install -y container-selinux

echo "==> Installing CRI-O and Kubernetes packages..."
sudo dnf install -y \
    cri-o \
    kubelet \
    kubeadm \
    kubectl \
    cri-tools \
    --disableexcludes=kubernetes

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

echo "==> Opening Kubernetes API server port if firewalld is running..."
if systemctl is-active --quiet firewalld; then
    sudo firewall-cmd --permanent --add-port=6443/tcp
    sudo firewall-cmd --permanent --add-port=10250/tcp
    sudo firewall-cmd --reload
else
    echo "firewalld is not running. Skipping firewall-cmd configuration."
fi

echo "==> Installing crictl bash completion..."
if command -v crictl >/dev/null 2>&1; then
    crictl completion bash | sudo tee /etc/bash_completion.d/crictl >/dev/null
fi

echo "==> Verifying installation..."
crio --version
kubeadm version
kubectl version --client=true
sudo crictl version

echo
echo "==> Installation completed successfully."
echo
echo "For a control-plane node, next run:"
echo "  sudo kubeadm init --cri-socket unix:///var/run/crio/crio.sock"
echo
echo "After kubeadm init, install a CNI plugin such as Calico, Cilium, or Flannel."
