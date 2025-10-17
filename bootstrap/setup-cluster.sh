#!/bin/bash

set -euo pipefail

# Stelle sicher, dass relative Pfade funktionieren – unabhängig vom Aufrufort.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Version-Pin für reproduzierbare Cluster-Bootstraps.
CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-v1.15.3}"
# Optional: IP-Range für MetalLB überschreiben (z.B. METALLB_ADDRESS_RANGE="172.18.255.200-172.18.255.250").
METALLB_ADDRESS_RANGE="${METALLB_ADDRESS_RANGE:-}"
METALLB_IP_POOL_NAME="loadbalancerpool"
METALLB_NAMESPACE="metallb-system"

CONFIG_FILE_DEFAULT="$(cd "$SCRIPT_DIR" && pwd)/../bootstrap.yaml"
CONFIG_FILE="${CONFIG_FILE:-$CONFIG_FILE_DEFAULT}"

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "❌ Konfigurationsdatei '$CONFIG_FILE' nicht gefunden."
  echo "👉 Bitte lege 'bootstrap.yaml' im Repository-Wurzelverzeichnis an oder gib den Pfad über CONFIG_FILE an."
  exit 1
fi

if command -v python3 >/dev/null 2>&1; then
  PYTHON_CMD="python3"
elif command -v python >/dev/null 2>&1; then
  PYTHON_CMD="python"
else
  echo "❌ Weder 'python3' noch 'python' gefunden."
  echo "👉 Bitte installiere Python, um das Skript auszuführen."
  exit 1
fi

read_config_value() {
  local key=$1
  local value=""
  value="$("$PYTHON_CMD" - "$CONFIG_FILE" "$key" <<'PY' || true
import sys, re
path, lookup_key = sys.argv[1], sys.argv[2]
pattern = re.compile(r'^\s*' + re.escape(lookup_key) + r'\s*:\s*(.*)$')
try:
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            stripped = line.strip()
            if not stripped or stripped.startswith("#"):
                continue
            match = pattern.match(line)
            if match:
                value = match.group(1).split('#', 1)[0].strip()
                if value and value[0] == value[-1] and value[0] in ('"', "'"):
                    value = value[1:-1]
                print(value, end="")
                break
except FileNotFoundError:
    pass
PY
)"
  echo "$value"
}

CLUSTER_NAME="${CLUSTER_NAME:-$(read_config_value "clusterName")}"
KIND_CONFIG_RELATIVE="${KIND_CONFIG_RELATIVE:-$(read_config_value "kindConfig")}"
BASE_DOMAIN="${BASE_DOMAIN:-$(read_config_value "domain")}"
TOP_LEVEL_DOMAIN="${TOP_LEVEL_DOMAIN:-$(read_config_value "topLevelDomain")}"
CONFIG_METALLB_RANGE="$(read_config_value "metallbAddressRange")"
CA_COMMON_NAME="${CA_COMMON_NAME:-$(read_config_value "caCommonName")}"
CA_ORGANIZATION="${CA_ORGANIZATION:-$(read_config_value "caOrganization")}"
CA_VALIDITY_DAYS="${CA_VALIDITY_DAYS:-$(read_config_value "caValidityDays")}"

CLUSTER_NAME="${CLUSTER_NAME:-dev}"
KIND_CONFIG_RELATIVE="${KIND_CONFIG_RELATIVE:-kind-config/kind-simple.yaml}"
BASE_DOMAIN="${BASE_DOMAIN:-pdn}"
TOP_LEVEL_DOMAIN="${TOP_LEVEL_DOMAIN:-lab}"
CA_COMMON_NAME="${CA_COMMON_NAME:-KinD Dev Root CA}"
CA_ORGANIZATION="${CA_ORGANIZATION:-KinD Dev Lab}"
CA_VALIDITY_DAYS="${CA_VALIDITY_DAYS:-3650}"

if [[ "${KIND_CONFIG_RELATIVE}" = /* ]]; then
  KIND_CONFIG_PATH="$KIND_CONFIG_RELATIVE"
else
  KIND_CONFIG_PATH="$SCRIPT_DIR/$KIND_CONFIG_RELATIVE"
fi

if [[ ! -f "$KIND_CONFIG_PATH" ]]; then
  echo "❌ KIND-Konfigurationsdatei '$KIND_CONFIG_PATH' existiert nicht."
  exit 1
fi

INGRESS_BASE_DOMAIN="${BASE_DOMAIN}.${TOP_LEVEL_DOMAIN}"
METALLB_ADDRESS_RANGE="${METALLB_ADDRESS_RANGE:-$CONFIG_METALLB_RANGE}"

CA_DIR="$SCRIPT_DIR/CA"
CA_CERT_PATH="$CA_DIR/ca.crt"
CA_KEY_PATH="$CA_DIR/ca.key"

echo "ℹ️  Konfiguration:"
echo "   KIND-Cluster: ${CLUSTER_NAME}"
echo "   KIND-Config : ${KIND_CONFIG_PATH}"
echo "   Ingress-Domain: *.${INGRESS_BASE_DOMAIN}"
if [[ -n "$METALLB_ADDRESS_RANGE" ]]; then
  echo "   MetalLB-Range (fix): ${METALLB_ADDRESS_RANGE}"
else
  echo "   MetalLB-Range: automatisch bestimmen"
fi

ensure_ca_material() {
  mkdir -p "$CA_DIR"
  if [[ -f "$CA_CERT_PATH" && -f "$CA_KEY_PATH" ]]; then
    echo "ℹ️  Bestehende lokale CA-Dateien werden verwendet."
    return
  fi

  echo "🔐 Erstelle neue CA-Zertifikate (${CA_VALIDITY_DAYS} Tage gültig)..."
  openssl req -x509 -nodes -newkey rsa:4096 \
    -keyout "$CA_KEY_PATH" \
    -out "$CA_CERT_PATH" \
    -days "$CA_VALIDITY_DAYS" \
    -subj "/CN=${CA_COMMON_NAME}/O=${CA_ORGANIZATION}"
}

TEMP_FILES=()
cleanup_temp_files() {
  for file in "${TEMP_FILES[@]}"; do
    [[ -f "$file" ]] && rm -f "$file"
  done
}
trap cleanup_temp_files EXIT

render_template() {
  local template_file=$1
  local tmp
  tmp="$(mktemp)"
  sed \
    -e "s/__INGRESS_BASE_DOMAIN__/${INGRESS_BASE_DOMAIN//\//\\/}/g" \
    "$template_file" > "$tmp"
  TEMP_FILES+=("$tmp")
  echo "$tmp"
}

require_commands() {
  local missing=()
  for cmd in "$@"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing+=("$cmd")
    fi
  done

  if (( ${#missing[@]} > 0 )); then
    echo "❌ Fehlende benötigte Tools: ${missing[*]}"
    echo "👉 Bitte installiere sie und starte das Skript erneut."
    exit 1
  fi
}

detect_kind_subnet() {
  if ! command -v docker >/dev/null 2>&1; then
    return 1
  fi

  local subnets
  subnets="$(docker network inspect kind -f '{{range .IPAM.Config}}{{if .Subnet}}{{println .Subnet}}{{end}}{{end}}' 2>/dev/null || true)"

  while read -r subnet; do
    [[ -z "$subnet" ]] && continue
    if [[ "$subnet" == *.* ]]; then
      echo "$subnet"
      return 0
    fi
  done <<< "$subnets"

  return 1
}

calculate_ip_range() {
  local subnet=$1

  SUBNET="$subnet" "$PYTHON_CMD" - <<'PY'
import ipaddress, os, sys

subnet = os.environ.get("SUBNET")
if not subnet:
    sys.exit("missing subnet")

network = ipaddress.ip_network(subnet, strict=False)
if network.version != 4:
    sys.exit("ipv6_not_supported")
if network.num_addresses <= 2:
    sys.exit(1)

usable = network.num_addresses - 2  # exclude network + broadcast
block = min(usable, 50)

end = int(network.broadcast_address) - 1
start = end - block + 1

first_host = int(next(network.hosts()))
if start < first_host:
    start = first_host

start_ip = ipaddress.ip_address(start)
end_ip = ipaddress.ip_address(end)

print(f"{start_ip}-{end_ip}")
PY
}

configure_metallb_ip_pool() {
  local range=$1

  echo "📌 Setze MetalLB IPAddressPool auf '${range}'."
  cat <<EOF | kubectl apply -f -
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: ${METALLB_IP_POOL_NAME}
  namespace: ${METALLB_NAMESPACE}
spec:
  addresses:
  - ${range}
EOF
}

REQUIRED_COMMANDS=(kind kubectl helm openssl "$PYTHON_CMD")
require_commands "${REQUIRED_COMMANDS[@]}"

detected_subnet=""
detected_range=""
yaml_fallback=false

if [[ -n "$METALLB_ADDRESS_RANGE" ]]; then
  detected_range="$METALLB_ADDRESS_RANGE"
  echo "ℹ️  MetalLB IP-Range aus Environment gesetzt: $detected_range"
else
  if detected_subnet=$(detect_kind_subnet 2>/dev/null) && [[ -n "$detected_subnet" ]]; then
    if detected_range=$(calculate_ip_range "$detected_subnet" 2>/dev/null); then
      echo "ℹ️  Erkannter KIND-Subnetzbereich: $detected_subnet"
      echo "   Vorgeschlagene MetalLB IP-Range: $detected_range"
    else
      echo "⚠️  Konnte aus Subnetz '$detected_subnet' keine IPv4-Range ableiten (vermutlich IPv6)."
      yaml_fallback=true
    fi
  else
    echo "⚠️  Kind-Subnetz konnte nicht automatisch ermittelt werden."
    yaml_fallback=true
  fi
fi

if [[ "$yaml_fallback" == false && -n "$detected_range" ]]; then
  echo
  echo "Bitte prüfe, ob die vorgeschlagene Range ($detected_range) zu deinem lokalen Netzwerk passt."
  echo "Optionen:"
  echo "  [y] Annehmen und mit dieser Range fortfahren"
  echo "  [f] Fallback: statische Range aus ./metallb/ipaddresspool.yaml verwenden"
  echo "  [a] Abbrechen"
  read -r -p "Deine Auswahl [y/f/a]: " confirm || confirm=""
  case "$confirm" in
    ""|y|Y)
      METALLB_ADDRESS_RANGE="$detected_range"
      yaml_fallback=false
      echo "➡️  Fortfahren mit MetalLB-Range: $METALLB_ADDRESS_RANGE"
      ;;
    f|F)
      yaml_fallback=true
      METALLB_ADDRESS_RANGE=""
      ;;
    a|A)
      echo "🚫 Abbruch auf Wunsch des Nutzers."
      exit 0
      ;;
    *)
      echo "⚠️  Ungültige Eingabe – verwende statische Range aus YAML."
      yaml_fallback=true
      METALLB_ADDRESS_RANGE=""
      ;;
  esac
else
  yaml_fallback=true
  METALLB_ADDRESS_RANGE=""
fi

if [[ "$yaml_fallback" == true && -z "$METALLB_ADDRESS_RANGE" ]]; then
  echo
  echo "Es wird die statische Range aus ./metallb/ipaddresspool.yaml verwendet."
  read -r -p "Weiter mit YAML-Fallback? [weiter/abort]: " fallback_choice || fallback_choice="weiter"
  case "$fallback_choice" in
    abort|a|A)
      echo "🚫 Abbruch auf Wunsch des Nutzers."
      exit 0
      ;;
    *)
      echo "➡️  Fortsetzen mit statischer YAML-Konfiguration."
      ;;
  esac
fi

check_pods_ready() {
  local namespace=$1
  local timeout=${2:-120}
  local retries=${3:-24}
  local interval=${4:-5}

  echo "⌛ Prüfe, ob Pods im Namespace '$namespace' bereit sind..."

  local attempt=1
  local end_time=$((SECONDS + timeout * retries))

  while [ $attempt -le $retries ]; do
    local pods_output
    pods_output="$(kubectl get pods -n "$namespace" --no-headers 2>/dev/null || true)"

    if [[ -z "$pods_output" || "$pods_output" == *"No resources found"* ]]; then
      if (( SECONDS >= end_time )); then
        echo "❌ Fehler: Im Namespace '$namespace' wurden keine Pods angelegt."
        kubectl get pods -n "$namespace" || true
        exit 1
      fi
      echo "ℹ️  Warte auf erste Pods im Namespace '$namespace'..."
      sleep "$interval"
      attempt=$((attempt + 1))
      continue
    fi

    local not_ready=0
    while read -r name ready status _rest; do
      [[ -z "$name" ]] && continue

      case "$status" in
        Running)
          if [[ "$ready" != */* ]]; then
            not_ready=1
            break
          fi
          local current=${ready%%/*}
          local total=${ready##*/}
          if [[ "$current" != "$total" ]]; then
            not_ready=1
            break
          fi
          ;;
        Completed|Succeeded)
          continue
          ;;
        *)
          not_ready=1
          break
          ;;
      esac
    done <<< "$pods_output"

    if [[ $not_ready -eq 0 ]]; then
      echo "✅ Alle Pods im Namespace '$namespace' sind bereit."
      return 0
    fi

    if (( SECONDS >= end_time )); then
      echo "❌ Fehler: Nicht alle Pods im Namespace '$namespace' wurden rechtzeitig bereit."
      kubectl get pods -n "$namespace" || true
      exit 1
    fi

    echo "❌ Pods im Namespace '$namespace' sind noch nicht bereit. Nächster Versuch in ${interval}s..."
    sleep "$interval"
    attempt=$((attempt + 1))
  done

  echo "❌ Fehler: Nicht alle Pods im Namespace '$namespace' wurden rechtzeitig bereit."
  kubectl get pods -n "$namespace" || true
  exit 1
}

echo "==========================================="
echo "⚙️  0. Helm Repositories vorbereiten..."
echo "==========================================="
helm repo add metallb https://metallb.github.io/metallb --force-update
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx --force-update
helm repo add argo https://argoproj.github.io/argo-helm --force-update
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update
helm repo add k8s_gateway https://ori-edge.github.io/k8s_gateway/ --force-update
helm repo update

echo "==========================================="
echo "🔧 1. Create KIND Cluster..."
echo "==========================================="
kind create cluster --name "$CLUSTER_NAME" --config "$KIND_CONFIG_PATH"

echo "==========================================="
echo "🔧 2. Installing MetalLB..."
echo "==========================================="
helm upgrade --install metallb metallb/metallb --create-namespace --namespace metallb-system

echo "✅ MetalLB Installation gestartet."
check_pods_ready "metallb-system" 120 24 5

echo "📂 Anwenden der IPAddressPool und L2Advertisement Konfigurationen..."
if [[ -n "$METALLB_ADDRESS_RANGE" ]]; then
  configure_metallb_ip_pool "$METALLB_ADDRESS_RANGE"
else
  echo "ℹ️  Verwende statische IP-Range aus ./metallb/ipaddresspool.yaml"
  kubectl apply -f ./metallb/ipaddresspool.yaml
fi
kubectl apply -f ./metallb/l2advertisement.yaml
echo "✅ IPAddressPool und L2Advertisement erfolgreich angewendet."

echo "==========================================="
echo "🔧 3. Installing NGINX Ingress Controller..."
echo "==========================================="
helm upgrade --install nginx-ingress ingress-nginx/ingress-nginx --create-namespace --namespace ingress-nginx

echo "✅ NGINX Ingress Controller Installation gestartet."
check_pods_ready "ingress-nginx" 120 24 5

echo "==========================================="
echo "🔧 4. Installing Cert-Manager + Cluster-Issuer"
echo "==========================================="
kubectl apply -f "https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml"

echo "✅ Cert-Manager Installation gestartet."
check_pods_ready "cert-manager" 120 24 5

echo "Create CA Secret"
ensure_ca_material
kubectl create secret tls ca-key-pair \
  --cert="$CA_CERT_PATH" \
  --key="$CA_KEY_PATH" \
  --namespace cert-manager \
  --dry-run=client -o yaml | kubectl apply -f -
echo "✅ CA Secret erfolgreich angewendet."

echo "20 Sekunden Warten vor Cluster Issuer..."
sleep 20
kubectl apply -f ./cert-manager/cluster-issuer.yaml

echo "==========================================="
echo "🚀 5. ArgoCD installieren"
echo "==========================================="
echo "Helm install Argocd with custom values"
ARGOCD_VALUES_FILE="$(render_template "$SCRIPT_DIR/argo-cd/values.yaml")"
helm upgrade --install argocd argo/argo-cd \
  --namespace argocd \
  --create-namespace \
  --version 7.8.23 \
  --values "$ARGOCD_VALUES_FILE"
check_pods_ready "argocd" 120 24 5
echo "setzen von admin admin als user & pw"
#Bcrypt-Hash des gewünschten Passworts
ADMIN_HASH="\$2y\$10\$r2WWCWQuTXsIUSM9ZhzIIOk2jZ/t0thuKrYGioWi4/NMeL/ceb2mu"
#Aktueller UTC-Zeitstempel
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

#Secret anwenden
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: argocd-secret
  namespace: argocd
  labels:
    app.kubernetes.io/name: argocd-secret
    app.kubernetes.io/part-of: argocd
type: Opaque
stringData:
  admin.password: "$ADMIN_HASH"
  admin.passwordMtime: "$TIMESTAMP"
EOF

echo "neustarten des ArgoCD Pods - damit Passwort erneuert wird"
# 🔁 ArgoCD Server neu starten
kubectl -n argocd delete pod -l app.kubernetes.io/name=argocd-server --ignore-not-found --wait=false

echo "https://argocd.${INGRESS_BASE_DOMAIN}"
echo "checkout Workloads at: https://gitlab.com/patrickdaumann/kind-lab-argocd"

echo "==========================================="
echo "🚀 6. Monitoring Bootstrap"
echo "==========================================="
helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --create-namespace \
  --values "$(render_template "$SCRIPT_DIR/kube-prometheus-stack/values.yaml")"

check_pods_ready "monitoring" 120 24 5

echo "==========================================="
echo "🚀 7. Setup Local DNS (ExDNS-Gateway) for local external Name Resolution"
echo "==========================================="
helm upgrade --install exdns k8s_gateway/k8s-gateway --set domain="${INGRESS_BASE_DOMAIN}"
echo "Add: nameserver <Loadbalancer IP of Coredns> to /etc/resolver/${INGRESS_BASE_DOMAIN} to enable DNS Resolution of Cluster Services"

echo "✅ Alles fertig!"
