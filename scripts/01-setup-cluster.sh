#!/bin/bash
set -euo pipefail

# ============================================================
# Setup complet : cluster k3d (1 noeud) + Calico + metrics-server
# + university-app + university-monitoring (OTel, Tempo, Grafana)
# + OpenTelemetry Operator
# ============================================================

CLUSTER_NAME="university-cluster"
NAMESPACE="university-app"
MONITORING_NAMESPACE="monitoring"
OTEL_NAMESPACE="opentelemetry-operator-system"
CHART_PATH="$(cd "$(dirname "$0")/.." && pwd)/university-app"
MONITORING_REPO="https://github.com/RehozoedArbi/Test-open.git"
MONITORING_CLONE_DIR="/tmp/university-monitoring-deploy"
CALICO_VERSION="v3.28.0"
K3S_POD_CIDR="10.42.0.0/16"

log() { echo -e "\n\033[1;34m[setup]\033[0m $1"; }
ok()  { echo -e "\033[1;32m  ✓ $1\033[0m"; }
err() { echo -e "\033[1;31m  ✗ $1\033[0m"; }

# ------------------------------------------------------------
log "1. Vérification des prérequis (docker, k3d, kubectl, helm)"

if ! command -v docker &>/dev/null; then
  err "docker n'est pas installé. Installe-le manuellement (https://docs.docker.com/engine/install/) puis relance ce script."
  exit 1
fi
if ! docker info &>/dev/null; then
  err "docker est installé mais le daemon ne répond pas (démarre-le, ou vérifie tes permissions sudo/groupe docker)."
  exit 1
fi
ok "docker présent et opérationnel"

install_k3d() {
  log "Installation de k3d (script officiel)"
  curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash
}

install_kubectl() {
  log "Installation de kubectl"
  local kver
  kver=$(curl -sL https://dl.k8s.io/release/stable.txt)
  curl -sLO "https://dl.k8s.io/release/${kver}/bin/linux/amd64/kubectl"
  chmod +x kubectl
  sudo mv kubectl /usr/local/bin/kubectl
}

install_helm() {
  log "Installation de helm (script officiel)"
  curl -s https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
}

if ! command -v k3d &>/dev/null;     then install_k3d;     else ok "k3d déjà présent";     fi
if ! command -v kubectl &>/dev/null; then install_kubectl;  else ok "kubectl déjà présent";  fi
if ! command -v helm &>/dev/null;    then install_helm;     else ok "helm déjà présent";     fi
if ! command -v git &>/dev/null; then
  err "git n'est pas installé. Installe-le (apt install git / yum install git) puis relance."
  exit 1
fi
ok "git présent"

for cmd in k3d kubectl helm git; do
  if ! command -v "$cmd" &>/dev/null; then
    err "$cmd toujours introuvable après tentative d'installation automatique."
    exit 1
  fi
done
ok "k3d, kubectl, helm, git présents"

# ------------------------------------------------------------
log "2. Création du cluster k3d (1 noeud, Flannel désactivé pour Calico)"
if k3d cluster list | grep -q "^${CLUSTER_NAME}"; then
  ok "Le cluster ${CLUSTER_NAME} existe déjà, on le réutilise"
else
  k3d cluster create "${CLUSTER_NAME}" \
    --servers 1 \
    --agents 0 \
    --k3s-arg "--flannel-backend=none@server:*" \
    --k3s-arg "--disable-network-policy@server:*" \
    --port "8080:80@loadbalancer" \
    --port "3000:3000@loadbalancer"
  ok "Cluster créé (ports 8080→80 pour l'app, 3000→3000 pour Grafana)"
fi

kubectl config use-context "k3d-${CLUSTER_NAME}" >/dev/null

# ------------------------------------------------------------
log "3. Attente que les noeuds soient enregistrés"
for i in $(seq 1 30); do
  if kubectl get nodes &>/dev/null; then
    ok "API server accessible"
    break
  fi
  sleep 2
done

# ------------------------------------------------------------
log "4. Installation de Calico (CNI, nécessaire pour les NetworkPolicy)"
if kubectl get ns calico-system &>/dev/null; then
  ok "Calico déjà présent"
else
  kubectl apply -f "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml"
  log "Ajustement du CIDR Calico pour correspondre à k3s (${K3S_POD_CIDR})"
  kubectl set env daemonset/calico-node -n kube-system \
    CALICO_IPV4POOL_CIDR="${K3S_POD_CIDR}" 2>/dev/null || true
fi

log "Attente que Calico soit opérationnel (peut prendre 1-2 min)"
kubectl wait --for=condition=Ready pods -l k8s-app=calico-node -n kube-system --timeout=180s || {
  err "Calico met du temps à démarrer, vérifie 'kubectl get pods -n kube-system'"
}
ok "Calico opérationnel"

# ------------------------------------------------------------
log "5. Attente que le noeud soit Ready (réseau opérationnel)"
kubectl wait --for=condition=Ready nodes --all --timeout=120s
ok "Noeud Ready"

# ------------------------------------------------------------
log "6. Attente que les CRDs Traefik soient enregistrées"
TRAEFIK_CRDS=("middlewares.traefik.io" "ingressroutes.traefik.io" "ingressroutetcps.traefik.io")
for crd in "${TRAEFIK_CRDS[@]}"; do
  echo -n "  Attente de ${crd}..."
  for i in $(seq 1 60); do
    if kubectl get crd "${crd}" &>/dev/null; then
      echo " ✓"
      break
    fi
    if [ "$i" -eq 60 ]; then
      err "CRD ${crd} toujours absente après 120s. Vérifie que Traefik est bien déployé par k3d."
      exit 1
    fi
    sleep 2
  done
done
ok "CRDs Traefik disponibles"

# ------------------------------------------------------------
log "8. Installation de metrics-server (nécessaire pour les HPA)"
if kubectl get deployment metrics-server -n kube-system &>/dev/null; then
  ok "metrics-server déjà installé"
else
  kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
  kubectl patch deployment metrics-server -n kube-system --type=json \
    -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
  ok "metrics-server installé (mode --kubelet-insecure-tls, adapté au cluster local uniquement)"
fi

log "Attente que metrics-server soit prêt"
kubectl wait --for=condition=Available deployment/metrics-server -n kube-system --timeout=120s
ok "metrics-server prêt"

# ------------------------------------------------------------
log "9. Déploiement du chart Helm university-app"
helm upgrade --install university-app "${CHART_PATH}" \
  --namespace "${NAMESPACE}" \
  --create-namespace \
  --wait --timeout=180s
ok "Chart university-app déployé"

# ------------------------------------------------------------
log "10. Attente que tous les pods applicatifs soient Ready"
kubectl wait --for=condition=Ready pods --all -n "${NAMESPACE}" --timeout=180s || {
  err "Certains pods ne sont pas encore Ready. Diagnostic ci-dessous :"
  kubectl get pods -n "${NAMESPACE}"
  kubectl get events -n "${NAMESPACE}" --sort-by='.lastTimestamp' | tail -20
  exit 1
}
ok "Tous les pods university-app sont Ready"

# ------------------------------------------------------------
log "11. Ajout des dépôts Helm pour le monitoring"
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts 2>/dev/null || true
helm repo update open-telemetry
ok "Dépôt open-telemetry ajouté"

# ------------------------------------------------------------
log "12. Installation de l'OpenTelemetry Operator"
if helm status opentelemetry-operator -n "${OTEL_NAMESPACE}" &>/dev/null; then
  ok "OTel Operator déjà installé"
else
  helm upgrade --install opentelemetry-operator open-telemetry/opentelemetry-operator \
    --namespace "${OTEL_NAMESPACE}" \
    --create-namespace \
    --version 0.65.0 \
    --set manager.collectorImage.repository="otel/opentelemetry-collector-contrib" \
    --set admissionWebhooks.certManager.enabled=false \
    --set admissionWebhooks.autoGenerateCert.enabled=true \
    --wait --timeout=120s
  ok "OTel Operator installé"
fi

log "Attente que l'OTel Operator soit Ready"
OTEL_DEPLOY=$(kubectl get deployment -n "${OTEL_NAMESPACE}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [ -z "${OTEL_DEPLOY}" ]; then
  err "Aucun deployment trouvé dans ${OTEL_NAMESPACE}"; exit 1
fi
kubectl wait --for=condition=Available "deployment/${OTEL_DEPLOY}" \
  -n "${OTEL_NAMESPACE}" --timeout=120s
ok "OTel Operator prêt (${OTEL_DEPLOY})"

# ------------------------------------------------------------
log "13. Clone du chart university-monitoring depuis GitHub"
rm -rf "${MONITORING_CLONE_DIR}"
git clone "${MONITORING_REPO}" "${MONITORING_CLONE_DIR}"
ok "Repo cloné dans ${MONITORING_CLONE_DIR}"

MONITORING_CHART_PATH="${MONITORING_CLONE_DIR}"
if [ -f "${MONITORING_CLONE_DIR}/university-monitoring/Chart.yaml" ]; then
  MONITORING_CHART_PATH="${MONITORING_CLONE_DIR}/university-monitoring"
elif [ -f "${MONITORING_CLONE_DIR}/Chart.yaml" ]; then
  MONITORING_CHART_PATH="${MONITORING_CLONE_DIR}"
else
  err "Impossible de localiser Chart.yaml dans le repo cloné."
  find "${MONITORING_CLONE_DIR}" -name "Chart.yaml" | head -10
  exit 1
fi
ok "Chart trouvé : ${MONITORING_CHART_PATH}"

# ------------------------------------------------------------
log "14. Déploiement du chart university-monitoring"
helm upgrade --install university-monitoring "${MONITORING_CHART_PATH}" \
  --namespace "${MONITORING_NAMESPACE}" \
  --create-namespace \
  --wait --timeout=180s
ok "Chart university-monitoring déployé"

log "Attente que tous les pods monitoring soient Ready"
kubectl wait --for=condition=Ready pods --all -n "${MONITORING_NAMESPACE}" --timeout=180s || {
  err "Certains pods monitoring ne sont pas Ready. Diagnostic :"
  kubectl get pods -n "${MONITORING_NAMESPACE}"
  kubectl get events -n "${MONITORING_NAMESPACE}" --sort-by='.lastTimestamp' | tail -20
  exit 1
}
ok "Tous les pods monitoring sont Ready"

# ------------------------------------------------------------
log "15. Création de l'Ingress Grafana (port 3000 → service grafana:3000)"

cat > /tmp/grafana-ingress.yaml << 'YAMLEOF'
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: grafana-ingress
  namespace: monitoring
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: grafana
spec:
  rules:
  - http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: grafana
            port:
              number: 3000
YAMLEOF

kubectl apply -f /tmp/grafana-ingress.yaml
rm -f /tmp/grafana-ingress.yaml
ok "Ingress Grafana créé (grafana.university.local:3000 → grafana:3000)"

# ------------------------------------------------------------
log "16. Configuration de Traefik pour écouter sur le port 3000"

# Patch du deployment Traefik pour ajouter l'entrypoint grafana sur le port 3000
TRAEFIK_PATCH='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--entrypoints.grafana.address=:3000"}]'
kubectl patch deployment traefik -n kube-system --type=json -p="${TRAEFIK_PATCH}" 2>/dev/null || true

ok "Traefik configuré avec entrypoint grafana sur le port 3000"

log "Attente du redémarrage de Traefik"
kubectl rollout status deployment/traefik -n kube-system --timeout=60s || true

# ------------------------------------------------------------
log "17. Déploiement de la ressource Instrumentation OTel"
sleep 5

helm template university-monitoring "${MONITORING_CHART_PATH}" \
  --show-only templates/otel-instrumentation/instrumentation.yaml \
  | kubectl apply -f -

log "Vérification de la ressource Instrumentation"
kubectl wait --for=condition=Available \
  instrumentation/university-instrumentation \
  -n "${NAMESPACE}" --timeout=60s 2>/dev/null || {
  kubectl get instrumentation -n "${NAMESPACE}" | grep university-instrumentation \
    && ok "Instrumentation créée" \
    || { err "Instrumentation non trouvée"; exit 1; }
}
ok "Ressource Instrumentation déployée"

# ------------------------------------------------------------
log "18. Redémarrage des pods applicatifs pour injection OTel"
kubectl rollout restart deployment -n "${NAMESPACE}"
kubectl rollout status deployment -n "${NAMESPACE}" --timeout=18kubec0s
ok "Pods redémarrés avec injection OTel active"

# ------------------------------------------------------------
log "19. Nettoyage du repo cloné"
rm -rf "${MONITORING_CLONE_DIR}"
ok "Dossier temporaire supprimé"

# ------------------------------------------------------------
log "20. Résumé du déploiement"
echo ""
echo "=== university-app ==="
kubectl get pods -n "${NAMESPACE}" -o wide
echo ""
kubectl get svc -n "${NAMESPACE}"
echo ""
kubectl get hpa -n "${NAMESPACE}"
echo ""
kubectl get ingress -n "${NAMESPACE}"

echo ""
echo "=== monitoring ==="
kubectl get pods -n "${MONITORING_NAMESPACE}" -o wide
echo ""
kubectl get ingress -n "${MONITORING_NAMESPACE}"

echo ""
echo "=== OTel Instrumentation ==="
kubectl get instrumentation -n "${NAMESPACE}"

FRONTEND_HOST=$(kubectl get ingress -n "${NAMESPACE}" \
  -o jsonpath='{.items[0].spec.rules[0].host}' 2>/dev/null || echo "university.local")

echo ""
ok "Déploiement complet terminé avec succès"
echo ""
echo "  Ajoute ces lignes à /etc/hosts :"
echo "    127.0.0.1 ${FRONTEND_HOST}"
echo "    127.0.0.1 grafana.university.local"
echo ""
echo "  Frontend  : http://${FRONTEND_HOST}:8080"
echo "  Grafana   : http://grafana.university.local:3000  (admin / admin123)"
echo ""