#!/bin/sh
# ============================================================
#  publicar.sh — expone un archivo del pod en TU misma URL de
#  noVNC para descargarlo directo en tu PC (binario-seguro:
#  sin pegar texto, sin servicios bloqueados, sin logins)
#
#  Uso:   sh publicar.sh RobloxAgentBridge.rbxmx
#         sh publicar.sh "RobloxAgentBridge(1).rbxmx"
#
#  Luego abre en tu PC el link que imprime.
#  Al terminar, bórralo con el comando rm que también imprime.
# ============================================================
set -eu
APP="${APP:-nav1}"

[ $# -ge 1 ] || { echo "Uso: sh publicar.sh <nombre-del-archivo>"; exit 1; }
NAME=$(basename "$1")

POD=$(oc get pods --no-headers 2>/dev/null | awk -v app="$APP" '$1 ~ ("^" app "-") && $3=="Running" {print $1; exit}')
[ -n "$POD" ] || { echo "[x] No hay pod Running de $APP"; exit 1; }

# nombre público sin espacios ni paréntesis (URL-amigable)
SAFE=$(echo "$NAME" | tr ' ()' '___')

echo "[+] localizando '$NAME' en el pod $POD ..."
SRC=$(oc exec -i "$POD" -- sh -c "find /headless -type f -name '$NAME' 2>/dev/null | head -1" | tr -d '\r')
[ -n "$SRC" ] || { echo "[x] no encontrado en el pod"; exit 1; }
echo "    encontrado en: $SRC"

echo "[+] ubicando la carpeta web de noVNC ..."
WEBDIR=$(oc exec -i "$POD" -- sh -c 'for d in /headless/noVNC /headless/novnc "$HOME/noVNC" "$HOME/novnc"; do [ -f "$d/vnc.html" ] && echo "$d" && break; done' | tr -d '\r')
[ -n "$WEBDIR" ] || { echo "[x] no encontré la carpeta web de noVNC en el pod"; exit 1; }
echo "    carpeta web: $WEBDIR"

echo "[+] publicando como '$SAFE' ..."
oc exec -i "$POD" -- sh -c "cp '$SRC' '$WEBDIR/$SAFE'"

ROUTE=$(oc get route "$APP" -o jsonpath='{.spec.host}')

echo
echo "=================================================="
echo " ✅ DESCARGA DIRECTA — abre esto en tu PC:"
echo
echo "    https://$ROUTE/$SAFE"
echo
echo "=================================================="
echo " IMPORTANTE: mientras el archivo esté ahí, cualquiera con"
echo " el link puede verlo. Cuando termine la descarga, bórralo:"
echo
echo "    oc exec -i $POD -- rm $WEBDIR/$SAFE"
echo "=================================================="
