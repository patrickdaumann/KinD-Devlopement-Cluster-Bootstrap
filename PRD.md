# Product Requirement

## Kontext:
- Dieses Projekt ist eine Kopie meines eigenen Bootstrap Repos.
- In diesem Projekt sind Secrets vorhanden, die entfernt werden müssen. CA crt und key bspw.
  - Diese sollen durch das bootstrap Skript "setup-cluster.sh" bei ausführung automatisch erstellt werden.
- In den config dateien bspw. Helm Values ist außerdem an einigen stellen die domain "pdn.lab" hinterlegt. Diese soll ausgetauscht werden
  - Der erste teil der ingresses soll erhalten bleiben: argocd.pdn.lab -> argocd.<nutzereingabe-domain>.<nutzereingabe-topleveldomain>
  - Es soll eine Konfig Datei im yaml format implementiert werden.
  - In dieser sollen einige Informationen hinterlegt werden können. Bspw: 
    - welche kind config verwendet werden soll
    - welche domain und toplevel domain für die ingresses und zertifikate etc. verwendet werden soll

## Ziele:
- Veralgemeinerung des Skriptes zur veröffentlichung in einem öffentlichen github repo.
- Stremlining des Prozesses für die erstellung der jetzt hart vorhandenen elemente (CA cert/key, helm values etc.)
- Die Funktionsweise und die verwendung sollen im github style in die Readme eingetragen werden. Ganz oben bitte einen TLDR-Quickstart mit den wichtigsten schritten um schnell einen dev-cluster hoch zu ziehen.
- die 
- Der SSH-Zugriffsschlüssel für argocd ist zu entfernen. Auch der apply teil im bootstrap skript für dieses Secret ist zu entfernen - Das ist ein spezieller teil für mich persönlich und wird in der allgemeinen version nicht benötigt.

## Randbedingungen
- Die Helm Values sollen nur so angepasst werden, dass die domain des ingress durch die konfig vorgegeben wird. Sonst muss alles exakt gleich bleiben.
- die config yaml für die eingabewerte des Skripts sollen im hauptverzeichnis des repos liegen und "bootstrap.yaml" genannt werden. Außerdem soll sie sinnvolle standardwerte beinhalten. bspw topleveldomain = lab, domain = pdn.