#!/bin/sh
# ============================================================
#  cerrar.sh — apaga el navegador remoto (libera RAM/CPU)
#
#  Uso:
#    sh cerrar.sh          → PAUSA: escala a 0, guarda la config
#    sh cerrar.sh borrar   → ELIMINA todo (deployment, ruta, pods)
#
#  Para encender de nuevo: corre el os.sh de siempre
#  (reconstruye todo solo, es idempotente)
# ============================================================
set -eu
APP="${APP:-nav1}"

if [ "${1:-}" = "borrar" ]; then
  echo "[+] eliminando $APP por completo..."
  oc delete all -l app=$APP 2>/dev/null || true
  oc delete route $APP 2>/dev/null || true
  echo "[✓] $APP eliminado."
else
  echo "[+] pausando $APP (escalando a 0 réplicas)..."
  oc scale deployment "$APP" --replicas=0
  echo "[✓] $APP pausado — ya no consume RAM ni CPU de tu cuota."
fi

echo
echo "== Estado actual de los pods: =="
oc get pods 2>/dev/null || true
echo
echo "Para encender otra vez:"
echo "  curl -fsSL https://raw.githubusercontent.com/hunterhunters371-prog/navegador-remoto/main/openshift-nav.sh -o os.sh && sh os.sh"
