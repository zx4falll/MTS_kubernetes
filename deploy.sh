#!/bin/bash
# Скрипт автоматического развертывания и восстановления инфраструктуры (Идемпотентный)
echo "========================================================="
echo "=== 0. Отключение фонового обновления ОС (APT Lock Fix) ==="
echo "========================================================="
# Отключаем фоновую службу, чтобы она не перехватывала блокировку
sudo systemctl stop unattended-upgrades || true
sudo systemctl disable unattended-upgrades || true

# На всякий случай проверяем и мягко завершаем процессы apt, если они успели запуститься
sudo killall -9 apt apt-get unattended-upgrades 2>/dev/null || true

# Очищаем возможные зависшие блокировки
sudo rm -f /var/lib/dpkg/lock-frontend
sudo rm -f /var/lib/apt/lists/lock
sudo rm -f /var/lib/dpkg/lock

# Восстанавливаем целостность пакетного менеджера
sudo dpkg --configure -a

set -e

echo "========================================================="
echo "=== 1. Очистка старых конфигураций и сброс (Cleanup) ==="
echo "========================================================="
sudo kubeadm reset -f || true
sudo systemctl stop kubelet || true
sudo systemctl stop containerd || true

sudo rm -rf /etc/kubernetes/
sudo rm -rf /var/lib/etcd/
sudo rm -rf /var/lib/kubelet/
sudo rm -rf /var/run/kubernetes/
rm -rf $HOME/.kube/

sudo ip link delete cni0 type bridge || true
sudo ip link delete flannel.1 || true

echo "========================================================="
echo "=== 2. Подготовка системных параметров ядра Linux ===="
echo "========================================================="
sudo swapoff -a
sudo sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab || true

cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

sudo modprobe overlay
sudo modprobe br_netfilter

cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sudo sysctl --system

echo "========================================================="
echo "=== 3. Установка и настройка контейнерного рантмайа ===="
echo "========================================================="
sudo apt-get update
sudo apt-get install -y containerd apt-transport-https ca-certificates curl gpg lsof

sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml > /dev/null
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml

sudo systemctl daemon-reload
sudo systemctl restart containerd
sudo systemctl enable containerd

echo "========================================================="
echo "=== 4. Установка утилит Kubernetes (v1.37) ============="
echo "========================================================="
sudo apt-get update
sudo apt-get install -y apt-transport-https ca-certificates curl gpg
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.37/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.37/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo apt-get update
sudo apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl

echo "========================================================="
echo "=== 5. Чистая инициализация кластера через kubeadm ====="
echo "========================================================="
sudo kubeadm init --pod-network-cidr=192.168.0.0/16

mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

echo "=== Снятие ограничений (Taint) для Single-node ==="
kubectl taint nodes --all node-role.kubernetes.io/control-plane- || true

echo "========================================================="
echo "=== 6. Установка сетевого плагина Flannel ==============="
echo "========================================================="
kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
sleep 10

# Подгоняем конфиг Flannel под


подсеть
kubectl get configmap -n kube-flannel kube-flannel-cfg -o yaml | sed 's/10.244.0.0\/16/192.168.0.0\/16/g' | kubectl apply -f - || true
kubectl delete pods -n kube-flannel --all || true

echo "========================================================="
echo "=== 7. Установка спецификаций Gateway API ================"
echo "========================================================="
kubectl apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.1/standard-install.yaml

echo "========================================================="
echo "=== 8. Установка менеджера пакетов Helm ================"
echo "========================================================="

curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-4
chmod 700 get_helm.sh
./get_helm.sh

echo "========================================================="
echo "=== 9. Установка и патч Envoy Gateway v1.6.1 ==========="
echo "========================================================="

kubectl apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.1/standard-install.yaml

echo "=== Ожидание готовности Envoy Gateway ==="
kubectl wait --timeout=5m -n envoy-gateway-system deployment/envoy-gateway --for=condition=Available

kubectl apply -f https://github.com/envoyproxy/gateway/releases/download/latest/quickstart.yaml -n default

echo "=== Патч Envoy сервиса в NodePort (Локальная ВМ) ==="
sleep 15

ENVOY_SVC=$(kubectl get svc -n envoy-gateway-system -o jsonpath='{.items[?(@.metadata.labels.gateway\.networking\.k8s\.io/gateway-name=="eg")].metadata.name}')
kubectl patch svc "$ENVOY_SVC" -n envoy-gateway-system --type='json' -p='[{"op": "replace", "path": "/spec/type", "value": "NodePort"}, {"op": "add", "path": "/spec/ports/0/nodePort", "value": 30080}]'

echo "========================================================="
echo "=== 10. Деплой Веб-приложения =========================="
echo "========================================================="
kubectl apply -f app.yaml

echo "========================================================="
echo "=== 11. Настройка мониторинга (Prometheus) ============="
echo "========================================================="
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
helm install monitoring prometheus-community/kube-prometheus-stack -f prometheus-values.yaml --namespace monitoring --create-namespace || true

echo "========================================================="
echo "=== 12. Настройка логирования (Filebeat DaemonSet) ====="
echo "========================================================="
kubectl apply -f filebeat.yaml

echo "========================================================="
echo "=== Развертывание успешно завершено!                   ==="
echo "========================================================="
kubectl get nodes
kubectl get pods -A