#!/bin/sh
# ============================================================
#  descargar.sh — saca un archivo del pod del navegador remoto
#  y te da un LINK público para bajarlo en tu PC.
#
#  Uso:
#    sh descargar.sh                      → lista tus descargas del pod
#    sh descargar.sh Downloads/archivo.pdf
#
#  Ejecutar en la TERMINAL WEB de OpenShift (icono >_)
# ============================================================
set -eu
APP="${APP:-nav1}"

POD=$(oc get pods --no-headers 2>/dev/null | awk -v app="$APP" '$1 ~ ("^" app "-") && $3=="Running" {print $1; exit}')
[ -n "$POD" ] || { echo "[x] No hay pod Running de $APP"; exit 1; }

# Sin argumentos: listar lo que hay en las descargas del pod
if [ $# -eq 0 ]; then
  echo "== Archivos en las descargas del pod ($POD):"
  oc exec -i "$POD" -- sh -c 'ls -lh "$HOME/Downloads" 2>/dev/null || echo "   (carpeta vacía o aún no existe)"'
  echo
echo "Uso: sh descargar.sh Downloads/<nombre-del-archivo>"
  exit 0
fi

F="$1"
BASE=$(basename "$F")

echo "[+] copiando '$F' desde el pod $POD ..."
oc cp "$POD:/headless/$F" "./$BASE"

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
