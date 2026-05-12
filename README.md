# KIND-Cluster-Bootstrap
Lokales Bootstrap-Skript für eine voll ausgestattete KIND-Spielwiese inklusive Gateway API, TLS, GitOps und Monitoring. Das Projekt wurde generalisiert, sodass keine Secrets im Repository verbleiben und Domains flexibel über eine YAML-Konfiguration gesteuert werden.

---

## TL;DR Quickstart
1. Repository klonen und in das Projektverzeichnis wechseln.
2. `bootstrap.yaml` prüfen/anpassen (Clustername, KIND-Konfig, gewünschte Domain).
3. Optional `METALLB_ADDRESS_RANGE` setzen, falls der automatische Vorschlag nicht passt.
4. `./bootstrap/setup-cluster.sh` ausführen – CA wird generiert, Helm-Releases werden eingerichtet.
5. CA-Zertifikat (`bootstrap/CA/ca.crt`) vertrauen und Gateway-Domains `<prefix>.<domain>.<tld>` lokal auflösen.

---

## Komponenten & Struktur
- **MetalLB** – stellt LoadBalancer-IPs bereit (`bootstrap/metallb`).
- **Gateway API + Envoy Gateway** – ersetzt Ingress-NGINX als lokaler HTTP/HTTPS-Routing-Layer.
- **Cert-Manager** – verwaltet Zertifikate und liefert einen ClusterIssuer (`bootstrap/cert-manager`).
- **Custom CA** – wird beim Bootstrap automatisch erzeugt (`bootstrap/CA` bleibt leer im Repo).
- **Argo CD** – GitOps-Controller inklusive HTTPRoute (`bootstrap/argo-cd`, Gateway-Routen werden zur Laufzeit parametrisiert).
- **kube-prometheus-stack** – Monitoring mit Prometheus, Grafana, Alertmanager (`bootstrap/kube-prometheus-stack`).
- **Lokales DNS** – CoreDNS-basierter lokaler DNS-Layer für `*.<domain>.<tld>` auf die Gateway-IP.

Repository-Layout:
```
bootstrap.yaml              # Konfigurationsdatei für Cluster & Domains
bootstrap/
 ├─ setup-cluster.sh        # Hauptskript
 ├─ CA/                     # wird beim Lauf mit CA-Material befüllt (gitignored)
 ├─ cert-manager/           # ClusterIssuer
 ├─ kind-config/            # KIND-Cluster-Konfigurationen
 ├─ metallb/                # Default-IP-Pool & L2Advertisement
 ├─ gateway/                # Gateway, TLS-Zertifikat und HTTPRoutes
 ├─ argo-cd/                # Helm values (Platzhalter für Domains)
 └─ kube-prometheus-stack/  # Helm values (Platzhalter für Domains)
```

---

## Voraussetzungen

| Komponente | Hinweis |
|------------|---------|
| **KIND**   | Kubernetes in Docker. Auf macOS empfiehlt sich Orbstack statt Docker Desktop (MetalLB benötigt funktionierendes L2-Networking). |
| **Docker** | Basis für KIND & MetalLB. |
| **Helm**   | Version 3 oder neuer. |
| **kubectl** | Für sämtliche `kubectl`-Befehle im Skript. |
| **openssl** | Generiert das lokale CA-Zertifikat. |
| **python3** | Wird zur automatischen IP-Berechnung genutzt. |
| Optional: **`METALLB_ADDRESS_RANGE`** | Überschreibt die automatisch vorgeschlagene Range. |

---

## Konfiguration (`bootstrap.yaml`)

```yaml
clusterName: dev-cluster            # Name des KIND-Clusters
kindConfig: kind-config/kind-simple.yaml
domain: kind                        # Zweite Ebene für Gateway-Domains
topLevelDomain: lab                 # Top-Level-Domain
metallbAddressRange:                # Optionaler Override (z. B. "172.18.0.200-172.18.0.250")
caCommonName: KinD Dev Root CA      # Subject CN für die generierte Root-CA
caOrganization: KinD Dev Lab        # Subject O
caValidityDays: 3650                # Gültigkeit in Tagen
```

Alle Werte lassen sich zur Laufzeit über Umgebungsvariablen überschreiben (`CLUSTER_NAME`, `KIND_CONFIG_RELATIVE`, `BASE_DOMAIN`, `TOP_LEVEL_DOMAIN`, …). Pfade in der YAML-Datei dürfen relativ zum `bootstrap/`-Verzeichnis angegeben werden.

---

## Bootstrap-Ablauf

1. **Checks & Konfiguration laden**  
   `setup-cluster.sh` prüft benötigte Tools, lädt `bootstrap.yaml` und setzt interne Variablen (Clustername, Domain, KIND-Config).

2. **MetalLB-Range ermitteln**  
   - Manuelle Vorgabe via `METALLB_ADDRESS_RANGE` oder `metallbAddressRange` in der YAML.  
   - Automatische Ableitung aus dem KIND-Docker-Netz.  
   - Fallback auf statische YAML bei IPv6 oder fehlgeschlagener Erkennung.

3. **KIND-Cluster erstellen**  
   Verwendet die in `bootstrap.yaml` hinterlegte Konfiguration.

4. **MetalLB deployen & konfigurieren**  
   Helm-Release plus IPAddressPool/L2Advertisement (dynamisch oder statisch).

5. **Gateway API + Envoy Gateway**  
   Installation der Gateway API CRDs und des Envoy-Gateway-Controllers via Helm.

6. **cert-manager & CA-Secret**  
   - cert-manager wird per versionierter YAML von GitHub installiert.  
   - Das Skript erzeugt automatisch ein neues CA-Zertifikat/-Key (RSA 4096) und erstellt daraus das Secret `ca-key-pair`.  
   - Anschließend wird der ClusterIssuer angewendet.

7. **Argo CD**  
   Helm-Installation mit gerenderten Values (`argocd.<domain>.<tld>`).  
   Admin-Passwort wird per Secret gesetzt und der Server-Pod neugestartet.

8. **Monitoring (kube-prometheus-stack)**  
   Helm-Release ohne Ingress-Ressourcen; externe Zugriffe erfolgen über gerenderte HTTPRoutes (`grafana.<domain>.<tld>`, `prometheus.<domain>.<tld>` …).

9. **Lokales DNS**  
   Installiert einen kleinen CoreDNS-Resolver, der `*.<domain>.<tld>` auf die Gateway-LoadBalancer-IP auflöst, und gibt den nötigen Resolver-Eintrag aus.

10. **Ausgabe der wichtigsten URLs**  
    Das Skript gibt u. a. die Argo-CD-URL zurück: `https://argocd.<domain>.<tld>`.

Die Helm-Values deaktivieren die bisherigen Ingress-Ressourcen. Gateway-, Certificate- und HTTPRoute-Manifeste tragen Platzhalter, die das Skript vor dem Anwenden ersetzt.

---

## Nacharbeiten & hilfreiche Befehle

| Aktion | Befehl / Hinweis |
|--------|------------------|
| **Gateway-Domains auflösen** | Siehe DNS-Quickstart unten. Alternativ `/etc/hosts` temporär erweitern. |
| **CA vertrauen** | `bootstrap/CA/ca.crt` nach dem Bootstrap importieren; siehe CA-Trust-Quickstart unten. |
| **Status prüfen** | `kubectl get nodes`, `kubectl get pods -A`. |
| **Argo CD UI** | `https://argocd.<domain>.<tld>` – das Passwort steht als bcrypt-Hash im Skript (`ADMIN_HASH`). |
| **Grafana** | `https://grafana.<domain>.<tld>` – Standard-Login gemäß `kube-prometheus-stack/values.yaml`. |
| **Cluster entfernen** | `kind delete cluster --name <clusterName>`. |

---

## CA-Trust-Quickstart

> ⚠️ **Security-Hinweis:** Die lokale CA kann Zertifikate für beliebige Namen ausstellen. Vertraue ihr nur, solange du den lokalen KIND-Cluster aktiv nutzt. Entferne oder deaktiviere das Trust-Setting danach wieder.

### Arch Linux

Trust aktivieren:

```bash
sudo trust anchor --store bootstrap/CA/ca.crt
sudo update-ca-trust
```

Prüfen:

```bash
trust list | grep -A5 "KinD Dev Root CA"
```

Trust wieder entfernen, wenn der Cluster nicht genutzt wird:

```bash
sudo trust anchor --remove bootstrap/CA/ca.crt
sudo update-ca-trust
```

Hinweis: Chromium/Chrome/Brave nutzen üblicherweise den System-Trust-Store. Firefox nutzt ggf. einen eigenen Store. Dort entweder die CA manuell importieren oder in `about:config` setzen:

```text
security.enterprise_roots.enabled = true
```

Danach Firefox neu starten. Falls du die CA manuell in Firefox importiert hast, entferne sie dort auch wieder unter **Settings → Privacy & Security → Certificates → View Certificates → Authorities**.

### macOS

Trust aktivieren:

1. **Keychain Access** öffnen.
2. `bootstrap/CA/ca.crt` in den Keychain **System** oder **login** ziehen.
3. Zertifikat öffnen, **Trust** aufklappen und **When using this certificate: Always Trust** auswählen.
4. Dialog schließen und mit Passwort/Touch ID bestätigen.
5. Browser ggf. neu starten.

Trust wieder deaktivieren, wenn der Cluster nicht genutzt wird:

1. **Keychain Access** öffnen.
2. Nach **KinD Dev Root CA** suchen.
3. Zertifikat entweder löschen oder **Trust → When using this certificate** zurück auf **Use System Defaults** stellen.
4. Browser ggf. neu starten.

---

## DNS-Quickstart

Nach dem Bootstrap zeigt das Skript zwei IPs an:

- **DNS-IP**: `kubectl get svc exdns-k8s-gateway -o jsonpath='{.status.loadBalancer.ingress[0].ip}'`
- **Gateway-IP**: `kubectl get gateway -n envoy-gateway-system local-gateway -o jsonpath='{.status.addresses[0].value}'`

Für `kind.lab` muss dein System die **DNS-IP** als Resolver verwenden. Der DNS-Resolver antwortet dann für `*.kind.lab` mit der Gateway-IP.

### Arch Linux / systemd-resolved

Interface ggf. anpassen (`ip -br addr`, meistens `br-<docker-network-id>`):

```bash
sudo resolvectl dns br-d42eed08f143 172.18.255.205
sudo resolvectl domain br-d42eed08f143 "~kind.lab"
resolvectl flush-caches
resolvectl query grafana.kind.lab
```

Optional als Alias:

```bash
alias enable-kind-dns='sudo resolvectl dns br-d42eed08f143 172.18.255.205 && sudo resolvectl domain br-d42eed08f143 "~kind.lab"'
```

### macOS

```bash
sudo mkdir -p /etc/resolver
printf 'nameserver 172.18.255.205\n' | sudo tee /etc/resolver/kind.lab
sudo dscacheutil -flushcache
```

Test:

```bash
dig grafana.kind.lab
open https://grafana.kind.lab
```

---

## Troubleshooting
- **MetalLB-IPs sehen falsch aus**  
  - Range manuell setzen (`METALLB_ADDRESS_RANGE="a.b.c.d-a.b.c.e"`).  
  - `docker network inspect kind` zur Kontrolle.  
  - MetalLB-Pods neu starten: `kubectl delete pod -n metallb-system -l app=metallb`.

- **Pods hängen in `CrashLoopBackOff` / `Pending`**  
  - `kubectl get events -A` prüfen.  
  - Ressourcenlimits deines lokalen Docker/Orbstack anpassen.

- **Gateway nicht erreichbar**  
  - Stimmt der Resolver-Eintrag / `/etc/hosts`?  
  - `kubectl get gateway -A` und `kubectl get httproute -A` prüfen.  
  - `kubectl get svc -n envoy-gateway-system` liefert die LoadBalancer-IP.

- **Browser meldet Zertifikatsfehler**  
  - `bootstrap/CA/ca.crt` importieren oder neue CA generieren (lösche `bootstrap/CA/*` und starte das Skript erneut).

- **GitOps-Repository benötigt SSH-Zugriff**  
  - Es werden keine Keys mehr ausgeliefert. Lege eigene Keys an und erstelle das Secret manuell:  
    ```bash
    kubectl -n argocd create secret generic gitlab-argocd-ssh \
      --from-file=sshPrivateKey=<pfad-zum-key> \
      --from-literal=url=git@gitlab.com \
      --dry-run=client -o yaml | kubectl apply -f -
    ```

---

## Konfigurierbare Dateien & Umgebungsvariablen

| Datei / Variable | Zweck |
|------------------|-------|
| `bootstrap.yaml` | Zentrale Konfiguration (Cluster, Domains, CA-Einstellungen, MetalLB-Override). |
| `METALLB_ADDRESS_RANGE` | Vorrangiger Override für den LoadBalancer-Pool. |
| `bootstrap/metallb/ipaddresspool.yaml` | Statischer Fallback für MetalLB. |
| `bootstrap/kind-config/*.yaml` | Alternative KIND-Cluster-Topologien. |
| `bootstrap/gateway/*.yaml` | Shared Gateway und wildcard TLS-Zertifikat. |
| `bootstrap/gateway/routes/**/*.yaml` | HTTPRoutes für Argo CD und Monitoring. |
| `bootstrap/argo-cd/values.yaml` | Helm-Values ohne Ingress-Erzeugung. |
| `bootstrap/kube-prometheus-stack/values.yaml` | Monitoring-Werte ohne Ingress-Erzeugung. |

---

## FAQ
- **Kann ich das Skript mehrfach ausführen?**  
  Ja. `helm upgrade --install` und `kubectl apply` machen den Ablauf idempotent. Secrets (z. B. Argo-CD-Passwort) werden dabei erneut gesetzt.

- **Was passiert bei Abbruch?**  
  Starte das Skript einfach neu. Bereits eingerichtete Releases/Ressourcen werden aktualisiert.

- **Eignung für Produktion?**  
  Das Setup ist für lokale Entwicklungs- und Demo-Umgebungen gedacht. Für Produktion sind zusätzliche Maßnahmen bzgl. Verfügbarkeit, Persistenz und Security erforderlich.

- **Weitere Infos?**  
  - KIND: https://kind.sigs.k8s.io  
  - MetalLB: https://metallb.universe.tf  
  - Cert-Manager: https://cert-manager.io  
  - Argo CD: https://argo-cd.readthedocs.io  
  - kube-prometheus-stack: https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack

---

Viel Erfolg beim Bootstrappen – Feedback und Erweiterungen sind jederzeit willkommen! 💡
