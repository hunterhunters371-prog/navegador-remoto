#!/bin/sh
# ============================================================
#  cerrar.sh — apaga el navegador remoto (libera RAM/CPU)
#
#  Uso:
#    sh cerrar.sh          → PAUSA: escala a 0 (tus datos/login
#                            quedan guardados en el volumen)
#    sh cerrar.sh borrar   → ELIMINA la app (deployment, ruta,
#                            pods) — el volumen CON datos sigue
#    sh cerrar.sh nuclear  → elimina TODO incluido el volumen
#                            (login y descargas se pierden)
#
#  Para encender de nuevo: corre el os.sh de siempre
# ============================================================
set -eu
APP="${APP:-nav1}"

case "${1:-}" in
  nuclear)
    echo "[+] eliminando TODO, incluido el volumen con tu login y descargas..."
    oc delete all -l app=$APP 2>/dev/null || true
    oc delete route $APP 2>/dev/null || true
    oc delete pvc "$APP-data" 2>/dev/null || true
    echo "[✓] $APP eliminado por completo (nada queda guardado)."
    ;;
  borrar)
    echo "[+] eliminando $APP (el volumen persistente se CONSERVA)..."
    oc delete all -l app=$APP 2>/dev/null || true
    oc delete route $APP 2>/dev/null || true
    echo "[✓] $APP eliminado. Tu login y descargas siguen en el volumen $APP-data."
    ;;
  *)
    echo "[+] pausando $APP (escalando a 0 réplicas)..."
    oc scale deployment "$APP" --replicas=0
    echo "[✓] $APP pausado — no consume RAM ni CPU. Datos guardados."
    ;;
esac

echo
echo "== Estado actual: =="
oc get pods 2>/dev/null || true
oc get pvc 2>/dev/null || true
echo
echo "Para encender otra vez:"
echo "  curl -fsSL https://raw.githubusercontent.com/hunterhunters371-prog/navegador-remoto/main/openshift-nav.sh -o os.sh && sh os.sh"
