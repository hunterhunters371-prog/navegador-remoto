#!/bin/sh
# ============================================================
#  openshift-nav.sh — Navegador remoto ligero en OpenShift Sandbox
#  v2: IceWM + Firefox ACTUAL en kiosko + AUTO-VERIFICACIÓN
#  de qué navegador está corriendo (adiós al Firefox viejo)
#  Idempotente. Ejecutar en la TERMINAL WEB de OpenShift (icono >_)
#
#  Uso:  sh openshift-nav.sh
#        VNC_PASSWORD=miclave sh openshift-nav.sh
# ============================================================
set -eu

APP="${APP:-nav1}"
IMG="${IMG:-docker.io/consol/rocky-icewm-vnc}"
VNC_PASSWORD="${VNC_PASSWORD:-notion2026}"
RES="${RES:-1280x720}"
DEPTH="${DEPTH:-16}"
REQ_CPU="${REQ_CPU:-250m}"; REQ_MEM="${REQ_MEM:-512Mi}"
LIM_CPU="${LIM_CPU:-1}";    LIM_MEM="${LIM_MEM:-2Gi}"
FF_URL="https://www.""notion.so"

log(){  printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
err(){  printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; }

command -v oc >/dev/null 2>&1 || { err "No existe 'oc' aqui. Ejecuta esto en la terminal web de OpenShift (icono >_)."; exit 1; }
PROJ=$(oc project -q)
log "Proyecto: $PROJ | App: $APP"
log "Imagen: $IMG"

# ---------- 1. Limpieza idempotente ----------
log "Limpiando restos anteriores de $APP (si existen)..."
oc delete all -l app=$APP 2>/dev/null || true
oc delete route $APP 2>/dev/null || true

# ---------- 2. Despliegue ligero ----------
log "Desplegando imagen liviana (IceWM)..."
oc new-app "$IMG" --name "$APP" \
  -e VNC_PW="$VNC_PASSWORD" \
  -e VNC_RESOLUTION="$RES" \
  -e VNC_COL_DEPTH="$DEPTH"

# ---------- 3. Recursos (anti-OOM) ----------
log "Limites: $REQ_CPU/$REQ_MEM (min) -> $LIM_CPU/$LIM_MEM (max)"
oc set resources deployment "$APP" --requests=cpu=$REQ_CPU,memory=$REQ_MEM --limits=cpu=$LIM_CPU,memory=$LIM_MEM

# ---------- 4. Ruta publica ----------
log "Creando ruta publica..."
oc create route edge "$APP" --service "$APP" --port 6901 --insecure-policy Redirect

# ---------- 5. Esperar rollout ----------
log "Esperando pod Running (descarga ~1.5GB, 3-6 min)..."
oc rollout status "deployment/$APP" --timeout=6m

POD=$(oc get pods -l app=$APP --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')
log "Pod activo: $POD"

# ---------- 6. Dentro del pod: matar viejo, instalar nuevo, VERIFICAR ----------
log "Instalando Firefox actual + perfil de 1 proceso dentro del pod..."
oc exec -i "$POD" -- sh -s <<'INNER'
set -e
cd "$HOME"

echo "==> Navegadores presentes en la imagen (viejos):"
ls /usr/bin 2>/dev/null | grep -iE 'firefox|chrom' || echo "   (ninguno en /usr/bin)"
ls /usr/lib64 2>/dev/null | grep -iE 'firefox|chrom' || true

if [ ! -x firefox/firefox ]; then
  echo "==> descargando Firefox actual..."
  curl -sL "https://download.mozilla.org/?product=firefox-latest-ssl&os=linux64&lang=es-ES" -o f.tar.xz
  python3 -c "import lzma,tarfile; tarfile.open('f.tar.xz','r:xz').extractall()"
  rm -f f.tar.xz
else
  echo "==> Firefox actual ya estaba instalado"
fi

mkdir -p ff-notion
cat > ff-notion/user.js <<PREFS
user_pref("dom.ipc.processCount", 1);
user_pref("browser.cache.memory.enable", false);
user_pref("browser.sessionhistory.max_total_viewers", 0);
user_pref("media.autoplay.default", 5);
user_pref("toolkit.cosmeticAnimations.enabled", false);
user_pref("browser.newtabpage.enabled", false);
PREFS

echo "==> matando navegadores viejos/de fabrica (por ruta exacta)..."
pkill -f /usr/lib64/firefox 2>/dev/null || true
pkill -f /usr/bin/chromium 2>/dev/null || true
pkill -f chromium-browser 2>/dev/null || true
pkill -f firefox-esr 2>/dev/null || true
pkill -f "$HOME/firefox/firefox" 2>/dev/null || true
sleep 1

echo "==> lanzando Firefox ACTUAL en kiosko..."
DISPLAY=:1 nohup "$HOME/firefox/firefox" --kiosk --profile "$HOME/ff-notion" "https://www.""notion.so" >/dev/null 2>&1 &
sleep 6

echo "==> VERIFICACION de que navegador corre realmente:"
echo "   version instalada: $("$HOME/firefox/firefox" --version 2>/dev/null || echo 'no responde')"
if ps aux | grep "$HOME/firefox/firefox" | grep -qv grep; then
  echo "   [OK] el proceso en ejecucion ES el Firefox nuevo (portable, ultima version)"
else
  echo "   [ERROR] el Firefox nuevo no esta corriendo. Salida cruda del intento:"
  DISPLAY=:1 "$HOME/firefox/firefox" --kiosk --profile "$HOME/ff-notion" "https://www.""notion.so" 2>&1 | head -15 || true
fi
echo "==> procesos de navegador activos ahora:"
ps aux | grep -iE 'firefox|chrom' | grep -v grep || echo "   (ninguno)"
INNER

# ---------- 7. Resultado ----------
ROUTE=$(oc get route "$APP" -o jsonpath='{.spec.host}')
cat <<FIN

============================================================
 ✅ $APP OPTIMIZADO Y LISTO
------------------------------------------------------------
 URL:        https://$ROUTE/?password=$VNC_PASSWORD
 Contraseña: $VNC_PASSWORD
 Pagina:     Notion (kiosko, Firefox ACTUAL, 1 solo proceso)
------------------------------------------------------------
 AJUSTES DE CONSUMO APLICADOS
 · Escritorio IceWM (el mas liviano de la familia probada aqui)
 · Pantalla virtual $RES x $DEPTH bits
 · Firefox: 1 proceso, sin cache RAM, sin historial en memoria,
   sin animaciones ni autoplay
 · Limites: $REQ_MEM min / $LIM_MEM max RAM (anti-OOM)
------------------------------------------------------------
 REGLA VISUAL (para no confundir navegadores):
 · Pantalla COMPLETA sin barras ni pestañas = Firefox NUEVO ✓
 · Ventana normal con menus/iconos = el viejo de 2023 ✗ (cierrala)
------------------------------------------------------------
 SI EL POD SE REINICIA: vuelve a ejecutar  sh openshift-nav.sh
 Verificar consumo en vivo:  oc adm top pods
============================================================
FIN
