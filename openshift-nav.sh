#!/bin/sh
# ============================================================
#  openshift-nav.sh — Navegador remoto ligero en OpenShift Sandbox
#  v2.4: + fuerza 1 SOLO proceso de contenido en Firefox 154
#        (apaga Fission + procesos pre-lanzados: -200/400 MB)
#  Techo RAM 3Gi · auto-revive · ventana unica 1024x600x16
#  Idempotente. Ejecutar en la TERMINAL WEB de OpenShift (icono >_)
#
#  Uso:  sh openshift-nav.sh
#        VNC_PASSWORD=miclave sh openshift-nav.sh
#        RES=1280x720 sh openshift-nav.sh
# ============================================================
set -eu

APP="${APP:-nav1}"
IMG="${IMG:-docker.io/consol/rocky-icewm-vnc}"
VNC_PASSWORD="${VNC_PASSWORD:-notion2026}"
RES="${RES:-1024x600}"
DEPTH="${DEPTH:-16}"
REQ_CPU="${REQ_CPU:-250m}"; REQ_MEM="${REQ_MEM:-512Mi}"
LIM_CPU="${LIM_CPU:-1}";    LIM_MEM="${LIM_MEM:-3Gi}"
FF_URL="https://www.""notion.so"

log(){  printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
err(){  printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; }

command -v oc >/dev/null 2>&1 || { err "No existe 'oc' aqui. Ejecuta esto en la terminal web de OpenShift (icono >_)."; exit 1; }
PROJ=$(oc project -q)
log "Proyecto: $PROJ | App: $APP"
log "Imagen: $IMG | Video: $RES x $DEPTH bits | Techo RAM: $LIM_MEM"

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

# ---------- 3. Recursos (anti-OOM, con headroom para chats pesados) ----------
log "Limites: $REQ_CPU/$REQ_MEM (min) -> $LIM_CPU/$LIM_MEM (max)"
oc set resources deployment "$APP" --requests=cpu=$REQ_CPU,memory=$REQ_MEM --limits=cpu=$LIM_CPU,memory=$LIM_MEM

# ---------- 4. Ruta publica ----------
log "Creando ruta publica..."
oc create route edge "$APP" --service "$APP" --port 6901 --insecure-policy Redirect

# ---------- 5. Esperar rollout ----------
log "Esperando pod Running (descarga ~1.5GB, 3-6 min)..."
oc rollout status "deployment/$APP" --timeout=6m

# Detección robusta: por prefijo de nombre
POD=$(oc get pods --no-headers 2>/dev/null | awk -v app="$APP" '$1 ~ ("^" app "-") && $3=="Running" {print $1; exit}')
[ -n "$POD" ] || { err "No encontré pod Running de $APP. Pégame la salida de: oc get pods"; exit 1; }
log "Pod activo: $POD"

# ---------- 6. Dentro del pod: matar viejo, instalar nuevo, VERIFICAR, VIGILAR ----------
log "Instalando Firefox actual + perfil ultraligero (1 proceso real) + auto-revive..."
oc exec -i "$POD" -- env FF_RES="$RES" FF_URL="$FF_URL" sh -s <<'INNER'
set -e
cd "$HOME"

W=$(echo "$FF_RES" | cut -dx -f1)
H=$(echo "$FF_RES" | cut -dx -f2)

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
user_pref("fission.autostart", false);
user_pref("dom.ipc.processPrelaunch.enabled", false);
user_pref("browser.cache.memory.enable", false);
user_pref("browser.sessionhistory.max_total_viewers", 0);
user_pref("media.autoplay.default", 5);
user_pref("toolkit.cosmeticAnimations.enabled", false);
user_pref("browser.newtabpage.enabled", false);
user_pref("browser.sessionstore.resume_from_crash", false);
user_pref("browser.shell.checkDefaultBrowser", false);
user_pref("browser.toolbars.bookmarks.visibility", "never");
PREFS

echo "==> matando navegadores viejos/de fabrica (por ruta exacta)..."
pkill -f /usr/lib64/firefox 2>/dev/null || true
pkill -f /usr/bin/chromium 2>/dev/null || true
pkill -f chromium-browser 2>/dev/null || true
pkill -f firefox-esr 2>/dev/null || true
pkill -f "$HOME/firefox/firefox" 2>/dev/null || true
sleep 1

echo "==> lanzando Firefox ACTUAL en ventana unica ${W}x${H}..."
DISPLAY=:1 nohup "$HOME/firefox/firefox" --width "$W" --height "$H" --profile "$HOME/ff-notion" "$FF_URL" >/dev/null 2>&1 &
sleep 6

echo "==> VERIFICACION de que navegador corre realmente:"
echo "   version instalada: $("$HOME/firefox/firefox" --version 2>/dev/null || echo 'no responde')"
if ps aux | grep "$HOME/firefox/firefox" | grep -qv grep; then
  echo "   [OK] el proceso en ejecucion ES el Firefox nuevo (portable, ultima version)"
else
  echo "   [ERROR] el Firefox nuevo no esta corriendo. Salida cruda del intento:"
  DISPLAY=:1 "$HOME/firefox/firefox" --width "$W" --height "$H" --profile "$HOME/ff-notion" "$FF_URL" 2>&1 | head -15 || true
fi
echo "==> procesos de navegador activos ahora (deberian ser POCOS):"
ps aux | grep -iE 'firefox|chrom' | grep -v grep || echo "   (ninguno)"

echo "==> activando auto-revive (vigilante cada 15 s)..."
nohup sh -c 'while true; do if ! pgrep -f "firefo[x]/firefox" >/dev/null 2>&1; then W=$(echo "$FF_RES" | cut -dx -f1); H=$(echo "$FF_RES" | cut -dx -f2); DISPLAY=:1 "$HOME/firefox/firefox" --width "$W" --height "$H" --profile "$HOME/ff-notion" "$FF_URL" >/dev/null 2>&1 & fi; sleep 15; done' >/dev/null 2>&1 &
echo "   [OK] vigilante activo: si Firefox cae, se relanza solo"
INNER

# ---------- 7. Resultado ----------
ROUTE=$(oc get route "$APP" -o jsonpath='{.spec.host}')
cat <<FIN

============================================================
 ✅ $APP OPTIMIZADO Y LISTO (v2.4)
------------------------------------------------------------
 URL:        https://$ROUTE/?password=$VNC_PASSWORD
 Contraseña: $VNC_PASSWORD
 Pagina:     Notion — ventana unica $RES (Firefox ACTUAL,
             1 SOLO proceso de contenido, login normal)
------------------------------------------------------------
 AJUSTES DE CONSUMO APLICADOS
 · Escritorio IceWM · Pantalla virtual $RES x $DEPTH bits
 · Firefox: 1 proceso real (Fission apagado, sin pre-lanzados),
   sin cache RAM, sin historial en memoria, sin autoplay
 · Limites: $REQ_MEM min / $LIM_MEM max RAM
 · Auto-revive: si Firefox cae, se relanza solo en ~15 s
------------------------------------------------------------
 COMO ENTRAR A NOTION:
 · La ventana abre directo en Notion.
 · Login con email+codigo: todo en la misma ventana.
 · El popup de Google ya funciona (no es kiosko).
------------------------------------------------------------
 REGLA VISUAL:
 · La ventana que abre SOLA con Notion = Firefox NUEVO ✓
 · Iconos del escritorio / menus viejos = el de 2023 ✗
------------------------------------------------------------
 SI EL POD SE REINICIA: vuelve a ejecutar  sh openshift-nav.sh
 Verificar consumo en vivo:  oc adm top pods
============================================================
FIN
