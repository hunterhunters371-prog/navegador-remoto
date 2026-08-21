#!/bin/sh
# diagnostico.sh — recoge TODO el estado del navegador remoto en un solo bloque
# Uso: sh diagnostico.sh   (en la terminal web de OpenShift, icono >_)
set -u
APP="${APP:-nav1}"

echo "=================================================="
echo " DIAGNOSTICO $APP - $(date)"
echo "=================================================="

echo
echo "== PODS =="
oc get pods 2>&1

echo
echo "== CONSUMO (oc adm top pods) =="
oc adm top pods 2>&1 || echo "(metrics no disponibles)"

echo
echo "== RUTA =="
oc get route "$APP" 2>&1 || echo "(sin ruta)"

POD=$(oc get pods -l app=$APP --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -z "$POD" ]; then
  echo
  echo "[x] No hay pod Running de $APP — nada que revisar dentro."
  exit 0
fi
echo
echo "== POD ACTIVO: $POD =="

oc exec -i "$POD" -- sh -s <<'INNER'
echo
echo "== NAVEGADORES INSTALADOS =="
echo "-- en la imagen (viejos):"
ls /usr/bin 2>/dev/null | grep -iE 'firefox|chrom' || echo "   ninguno en /usr/bin"
for b in /usr/bin/firefox /usr/lib64/firefox/firefox /usr/bin/chromium /usr/bin/chromium-browser; do
  [ -e "$b" ] && echo "   $b -> $($b --version 2>/dev/null || echo '?')"
done
echo "-- portable (nuevo):"
if [ -x "$HOME/firefox/firefox" ]; then
  echo "   $HOME/firefox/firefox -> $($HOME/firefox/firefox --version 2>/dev/null)"
else
  echo "   NO INSTALADO"
fi

echo
echo "== PROCESOS DE NAVEGADOR CORRIENDO =="
ps aux | grep -iE 'firefox|chrom' | grep -v grep || echo "   (ninguno corriendo)"

echo
echo "== MEMORIA DENTRO DEL POD =="
free -m

echo
echo "== PROCESOS QUE MAS RAM COMEN =="
ps aux --sort=-%mem 2>/dev/null | head -8 || ps aux | head -8
INNER

echo
echo "=================================================="
echo " Copia TODO este bloque y pegalo en el chat"
echo "=================================================="
