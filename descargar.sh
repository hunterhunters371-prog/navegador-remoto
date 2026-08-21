#!/bin/sh
# ============================================================
#  descargar.sh v3 — saca un archivo del pod y te da un LINK
#
#  Mejoras v3:
#   · busca el archivo POR NOMBRE en todo el pod (Descargas,
#     Downloads, /tmp, donde sea que Firefox lo haya dejado)
#   · copia por stream directo (sin tar → sin archivos fantasma)
#   · sube con 3 servicios de respaldo (0x0.st / transfer.sh / file.io)
#
#  Uso:
#    sh descargar.sh                      → lista archivos recientes
#    sh descargar.sh RobloxAgentBridge.rbxmx
#    sh descargar.sh "RobloxAgentBridge(1).rbxmx"
# ============================================================
set -eu
APP="${APP:-nav1}"

POD=$(oc get pods --no-headers 2>/dev/null | awk -v app="$APP" '$1 ~ ("^" app "-") && $3=="Running" {print $1; exit}')
[ -n "$POD" ] || { echo "[x] No hay pod Running de $APP"; exit 1; }

if [ $# -eq 0 ]; then
  echo "== Archivos descargados recientemente (últimas 2 h, en todo el pod):"
  oc exec -i "$POD" -- sh -c 'find "$HOME" /tmp -type f -mmin -120 2>/dev/null | grep -v -E "(\.cache|/firefox/|/ff-notion/|\.mozilla|Crash|/noVNC|\.vnc|\.config|\.local|\.dbus|\.X|wm\.log|passwd|Lock|\.xpi)" | head -30'
  echo
  echo "Uso: sh descargar.sh <nombre-del-archivo>"
  exit 0
fi

NAME=$(basename "$1")

echo "[+] buscando '$NAME' dentro del pod $POD ..."
SRC=$(oc exec -i "$POD" -- sh -c "find /headless /tmp -type f -name '$NAME' 2>/dev/null | head -1" | tr -d '\r')
if [ -z "$SRC" ]; then
  echo "[x] No se encontró '$NAME' en el pod."
  echo "    Corre 'sh descargar.sh' sin argumentos para ver qué hay."
  exit 1
fi
echo "    encontrado en: $SRC"

echo "[+] copiando al terminal web ..."
oc exec -i "$POD" -- cat "$SRC" > "./$NAME"
if [ ! -s "./$NAME" ]; then
  echo "[x] La copia local quedó vacía — reintenta."
  exit 1
fi
echo "    tamaño local: $(ls -lh "./$NAME" | awk '{print $5}') ✓"

echo "[+] subiendo (0x0.st → transfer.sh → file.io) ..."
URL=""
URL=$(curl -fsS -F "file=@./$NAME" "https://0x0.st" 2>/dev/null) || URL=""
if [ -z "$URL" ]; then
  URL=$(curl -fsS --upload-file "./$NAME" "https://transfer.sh/$NAME" 2>/dev/null) || URL=""
fi
if [ -z "$URL" ]; then
  URL=$(curl -fsS -F "file=@./$NAME" "https://file.io" 2>/dev/null | grep -o '"link":"[^"]*"' | cut -d'"' -f4) || URL=""
fi
if [ -z "$URL" ]; then
  echo "[x] Los tres servicios fallaron. El archivo YA está en este"
  echo "    terminal web como ./$NAME — dímelo y buscamos otra salida."
  exit 1
fi

echo
echo "=================================================="
echo " ✅ LISTO — descárgalo en tu PC desde este link:"
echo "    $URL"
echo "=================================================="
echo "(el link expira en unos días; el original vive en el pod"
echo " mientras el pod viva — el pod es efímero)"
