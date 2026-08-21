#!/bin/sh
# ============================================================
#  descargar.sh — saca un archivo del pod del navegador remoto
#  y te da un LINK público para bajarlo en tu PC.
#
#  Uso:
#    sh descargar.sh                      → lista Downloads + BUSCA
#                                          archivos recientes en todo
#                                          el pod (home y /tmp)
#    sh descargar.sh RobloxAgentBridge.rbmx
#    sh descargar.sh /tmp/algo.pdf        (también acepta ruta absoluta)
#
#  Ejecutar en la TERMINAL WEB de OpenShift (icono >_)
# ============================================================
set -eu
APP="${APP:-nav1}"

POD=$(oc get pods --no-headers 2>/dev/null | awk -v app="$APP" '$1 ~ ("^" app "-") && $3=="Running" {print $1; exit}')
[ -n "$POD" ] || { echo "[x] No hay pod Running de $APP"; exit 1; }

# Sin argumentos: listar Downloads + buscar archivos recientes en todas partes
if [ $# -eq 0 ]; then
  echo "== Carpeta Downloads del pod:"
  oc exec -i "$POD" -- sh -c 'ls -lh "$HOME/Downloads" 2>/dev/null || echo "   (vacía o no existe)"'
  echo
  echo "== Archivos descargados recientemente (últimas 2 h, en todo el pod):"
  oc exec -i "$POD" -- sh -c 'find "$HOME" /tmp -type f -mmin -120 2>/dev/null | grep -v -E "(\.cache|/firefox/|/ff-notion/|\.mozilla|Crash|/noVNC|\.vnc)" | head -30'
  echo
  echo "Uso: sh descargar.sh <nombre-o-ruta>"
  echo "  ej:  sh descargar.sh RobloxAgentBridge.rbmx"
  echo "  ej:  sh descargar.sh /tmp/archivo.pdf"
  exit 0
fi

F="$1"
case "$F" in
  /*) SRC="$F" ;;          # ruta absoluta tal cual
  *)  SRC="/headless/$F" ;; # relativa al home del pod
esac
BASE=$(basename "$F")

echo "[+] copiando '$SRC' desde el pod $POD ..."
oc cp "$POD:$SRC" "./$BASE"

echo "[+] subiendo a transfer.sh ..."
URL=$(curl -fsS --upload-file "./$BASE" "https://transfer.sh/$BASE" 2>/dev/null) || {
  echo "[!] transfer.sh no respondió, probando 0x0.st ..."
  URL=$(curl -fsS -F "file=@./$BASE" "https://0x0.st")
}

echo
echo "=================================================="
echo " ✅ LISTO — descárgalo en tu PC desde este link:"
echo "    $URL"
echo "=================================================="
echo "(el link expira en unos días; el original vive en el"
echo " pod mientras el pod viva — el pod es efímero)"
