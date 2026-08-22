#!/bin/sh
# ============================================================
#  modo.sh — interruptor de nav1: PANTALLA (VNC) <-> LIGERO (texto)
#  v1.8
#    Este script ya NO lleva el codigo dentro: descarga
#    chat/server.py y chat/chat.html del repo y los mete en el
#    pod. Asi ningun archivo se corta al publicarlo.
#
#    Nuevo en esta version (server v1.8 + mini-web v1.9):
#      🔑 Sesion     — entrar/salir de la cuenta de Notion DESDE
#                      la mini-web (⚙ → Sesion): correo + codigo,
#                      sin tener que volver al modo pantalla.
#                      NUNCA usar "Continuar con Google".
#
#    Novedades anteriores (v1.7):
#      🤖 Elegir IA  — lee el selector de modelo de Notion
#      📎 Archivos   — subir desde el movil y adjuntar al chat
#      ⚙ Cuenta     — Cuenta/Notificaciones/Conexiones/Espacio
#                      de Notion en texto, con botones pulsables
#      🪞 Espejo     — la pagina en texto, en vivo
#
#  Uso (terminal web de OpenShift, icono >_):
#    sh modo.sh ligero     → activa/actualiza el chat de texto
#    sh modo.sh pantalla   → vuelve al escritorio VNC de siempre
#    sh modo.sh estado     → que esta corriendo ahora
# ============================================================
set -eu

APP="${APP:-nav1}"
RES="${RES:-1024x600}"
SIGILO="${SIGILO:-0}"
CHAT_PORT=6902
RAW="${RAW:-https://raw.githubusercontent.com/hunterhunters371-prog/navegador-remoto/main}"
FF_URL="https://www.""notion.so"

log(){  printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
err(){  printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; }

command -v oc >/dev/null 2>&1 || { err "No existe 'oc' aqui. Ejecuta en la terminal web de OpenShift (icono >_)."; exit 1; }

POD=$(oc get pods --no-headers 2>/dev/null | awk -v app="$APP" '$1 ~ ("^" app "-") && $3=="Running" {print $1; exit}')
[ -n "$POD" ] || { err "No hay pod Running de $APP (¿lo pausaste? corre primero os.sh)"; exit 1; }
log "Pod: $POD"

MODO="${1:-estado}"

case "$MODO" in
# ================== LIGERO ==================
ligero)
  log "Asegurando servicio y ruta del chat (puerto $CHAT_PORT)..."
  SEL=$(oc get service "$APP" -o jsonpath='{.spec.selector}' 2>/dev/null || true)
  [ -n "$SEL" ] || { err "No existe el service $APP — corre primero os.sh"; exit 1; }
  oc apply -f - <<SVC
apiVersion: v1
kind: Service
metadata:
  name: $APP-chat
  labels:
    app: $APP
spec:
  selector: $SEL
  ports:
  - name: chat
    port: $CHAT_PORT
    targetPort: $CHAT_PORT
SVC
  oc create route edge "$APP-chat" --service "$APP-chat" --port $CHAT_PORT --insecure-policy Redirect 2>/dev/null || true

  oc exec -i "$POD" -- sh -c 'mkdir -p /headless/data/chat /headless/data/subidas'

  TMPD=$(mktemp -d 2>/dev/null || echo /tmp)
  bajar() {
    # bajar <ruta-en-repo> <destino-en-pod> <marca-de-final>
    _f="$TMPD/pieza"
    if curl -fsSL "$RAW/$1" -o "$_f" 2>/dev/null && [ -s "$_f" ] && grep -q "$3" "$_f"; then
      oc exec -i "$POD" -- sh -c "cat > $2" < "$_f"
      log "instalado $1 ($(wc -c < "$_f" | tr -d ' ') bytes)"
    else
      err "no pude descargar $1 — uso la version que ya esta en el pod"
    fi
    rm -f "$_f"
  }
  log "Descargando el puente v1.8 del repo..."
  bajar chat/server.py /headless/data/chat/server.py MARCA-FIN-SERVER
  bajar chat/chat.html /headless/data/chat/chat.html MARCA-FIN-HTML
  oc exec -i "$POD" -- sh -c '[ -s /headless/data/chat/server.py ]' || {
    err "no hay server.py en el pod y la descarga fallo: revisa tu internet y reintenta"; exit 1; }

  log "Cambiando a modo LIGERO dentro del pod..."
  oc exec -i "$POD" -- env SIGILO="$SIGILO" sh -s <<'INNER'
set -e
D=/headless/data
pkill -f 'vigilante' 2>/dev/null || true
pkill -f "$D/firefox/firefox" 2>/dev/null || true
sleep 2
mkdir -p "$D/subidas"
if [ ! -s "$D/chat/clave.txt" ]; then
  head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$D/chat/clave.txt"
fi
if [ "${SIGILO:-0}" = "1" ]; then
  UJ="$D/ff-notion/user.js"
  touch "$UJ" 2>/dev/null || true
  grep -q 'dom.webdriver.enabled' "$UJ" 2>/dev/null || \
    echo 'user_pref("dom.webdriver.enabled", false);' >> "$UJ"
  echo "   [i] modo sigilo: navigator.webdriver oculto"
fi
MOZ_HEADLESS=1 nohup "$D/firefox/firefox" --headless --marionette --profile "$D/ff-notion" >/dev/null 2>&1 &
pkill -f 'chat/server.py' 2>/dev/null || true
sleep 1
nohup python3 "$D/chat/server.py" >/dev/null 2>&1 &
sleep 3
if pgrep -f 'marionette' >/dev/null 2>&1; then
  echo "   [OK] firefox headless corriendo"
else
  echo "   [x] firefox headless NO arranco — corre: sh modo.sh pantalla"
fi
i=0
while [ $i -lt 20 ]; do
  if curl -fsS http://localhost:6902/salud >/dev/null 2>&1; then
    echo "   [OK] servidor del chat respondiendo en 6902"
    break
  fi
  i=$((i+1)); sleep 2
done
INNER

  RUTA=$(oc get route "$APP-chat" -o jsonpath='{.spec.host}')
  CLAVE=$(oc exec -i "$POD" -- cat /headless/data/chat/clave.txt | tr -d '\r')
  cat <<FIN

============================================================
 ✅ MODO LIGERO ACTIVO (v1.8)
------------------------------------------------------------
 Abre en tu PC/telefono:  https://$RUTA/
 Clave (boton ⚙, se guarda sola): $CLAVE
------------------------------------------------------------
 BOTONES arriba en la mini-web:
   🤖  Elegir IA  — abre el selector de modelo de Notion y
       lista las opciones reales (GPT, Claude, etc.)
   📎  Archivos   — sube desde el movil (max 20 MB) y lo
       adjunta al chat; luego escribes y envias
   ⚙   Ajustes    — clave/destino + 🔑 SESION NUEVO: entrar o
       cerrar la sesion de Notion con correo+codigo, sin salir
       del modo ligero. Mas abajo: Cuenta, Notificaciones,
       Conexiones y Espacio en texto, con botones pulsables
   🪞  Espejo     — la pagina en texto, en vivo
------------------------------------------------------------
 Espera a ver "✓ pagina lista" arriba antes de escribir.
 Autodiagnostico:  https://$RUTA/prueba?clave=$CLAVE
 Estado general:   https://$RUTA/salud
------------------------------------------------------------
 Si dice "pide iniciar sesion": boton ⚙ → seccion Sesion →
 correo + codigo (NUNCA "Continuar con Google").
 Si sospechas bloqueo por automatizacion:
   SIGILO=1 sh modo.sh ligero
============================================================
FIN
  ;;

# ================== PANTALLA ==================
pantalla)
  log "Volviendo a modo PANTALLA (VNC)..."
  oc exec -i "$POD" -- env FF_RES="$RES" FF_URL="$FF_URL" sh -s <<'INNER'
set -e
D="$HOME/data"
pkill -f 'chat/server.py' 2>/dev/null || true
pkill -f 'marionette' 2>/dev/null || true
sleep 2
W=$(echo "$FF_RES" | cut -dx -f1)
H=$(echo "$FF_RES" | cut -dx -f2)
DISPLAY=:1 nohup "$D/firefox/firefox" --width "$W" --height "$H" --profile "$D/ff-notion" "$FF_URL" >/dev/null 2>&1 &
nohup sh -c 'D="$HOME/data"; while true; do if ! pgrep -f "firefo[x]/firefox" >/dev/null 2>&1; then W=$(echo "$FF_RES" | cut -dx -f1); H=$(echo "$FF_RES" | cut -dx -f2); DISPLAY=:1 "$D/firefox/firefox" --width "$W" --height "$H" --profile "$D/ff-notion" "$FF_URL" >/dev/null 2>&1 & fi; sleep 15; done' >/dev/null 2>&1 &
echo "   [OK] escritorio VNC + vigilante activos otra vez"
INNER
  RUTA=$(oc get route "$APP" -o jsonpath='{.spec.host}')
  echo
  echo " ✅ MODO PANTALLA ACTIVO — tu URL de siempre:"
  echo "    https://$RUTA/?password=<tu-clave-VNC>"
  echo
  ;;

# ================== ESTADO ==================
estado|*)
  echo "== procesos en el pod =="
  oc exec -i "$POD" -- sh -c 'ps aux | grep -E "firefox|server.py" | grep -v grep || echo "   (nada de eso corriendo)"' 2>/dev/null || true
  echo
  echo "== rutas =="
  oc get route 2>/dev/null || true
  ;;
esac
