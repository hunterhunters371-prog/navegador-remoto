#!/bin/sh
# ============================================================
#  cloudshell.sh — navegador remoto + mini-web en Google Cloud Shell
#  Equivalente docker de: openshift-nav.sh + modo.sh ligero
#
#  Lo que hace:
#    1. Contenedor consol/rocky-icewm-vnc (misma imagen del pod)
#    2. Datos en $HOME/nav-data (SOBREVIVE entre sesiones de
#       Cloud Shell: login de Notion, descargas, Firefox)
#    3. Firefox headless + Marionette + puente de texto (6902)
#    4. Puertos de la VM: 8080 = mini-web · 8081 = VNC visual
#
#  SEGURIDAD (leccion de la suspension de Red Hat):
#    aqui NO hay rutas publicas. La Vista Previa de Cloud Shell
#    solo abre con TU sesion de Google. Nada queda expuesto.
#
#  Limites de Cloud Shell: la sesion duerme a los ~20 min sin
#  uso y la VM se recicla (la imagen se vuelve a bajar; tus
#  datos en $HOME sobreviven). Para volver: sh cloudshell.sh
#
#  Uso:
#    curl -fsSL https://raw.githubusercontent.com/hunterhunters371-prog/navegador-remoto/main/cloudshell.sh -o cs.sh && sh cs.sh
#    VNC_PASSWORD=otra sh cs.sh   (cambiar clave VNC)
# ============================================================
set -eu

IMG="docker.io/consol/rocky-icewm-vnc"
NAME="${NAME:-navegador}"
VNC_PASSWORD="${VNC_PASSWORD:-notion2026}"
RES="${RES:-1024x600}"
DATA="$HOME/nav-data"
RAW="https://raw.githubusercontent.com/hunterhunters371-prog/navegador-remoto/main"

log(){  printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
err(){  printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; }

command -v docker >/dev/null 2>&1 || { err "No hay docker aqui — esto va en Google Cloud Shell (shell.cloud.google.com)"; exit 1; }
log "Datos persistentes: $DATA"
mkdir -p "$DATA"

# ---------- 1. contenedor (idempotente) ----------
log "Recreando contenedor $NAME (los datos NO se tocan)..."
docker rm -f "$NAME" >/dev/null 2>&1 || true
docker run -d --name "$NAME" --shm-size=1g \
  -p 127.0.0.1:8080:6902 -p 127.0.0.1:8081:6901 \
  -e VNC_PW="$VNC_PASSWORD" -e VNC_RESOLUTION="$RES" -e VNC_COL_DEPTH=16 \
  -v "$DATA":/headless/data \
  "$IMG" >/dev/null
sleep 5

# ---------- 2. archivos del puente (del repo, con marca de final) ----------
TMPD=$(mktemp -d 2>/dev/null || echo /tmp)
bajar() {
  _f="$TMPD/pieza"
  if curl -fsSL "$RAW/$1" -o "$_f" 2>/dev/null && [ -s "$_f" ] && grep -q "$3" "$_f"; then
    docker exec -i "$NAME" sh -c "mkdir -p /headless/data/chat && cat > $2" < "$_f"
    log "instalado $1 ($(wc -c < "$_f" | tr -d ' ') bytes)"
  else
    err "no pude descargar $1 — revisa internet y reintenta"
    exit 1
  fi
  rm -f "$_f"
}
bajar chat/server.py /headless/data/chat/server.py MARCA-FIN-SERVER
bajar chat/chat.html /headless/data/chat/chat.html MARCA-FIN-HTML

# ---------- 3. dentro: Firefox actual + prefs + headless + puente ----------
log "Configurando Firefox + Marionette + puente (la 1a vez descarga Firefox: ~2 min)..."
docker exec -i "$NAME" sh -s <<'INNER'
set -e
D=/headless/data
mkdir -p "$D/ff-notion" "$D/Downloads" "$D/subidas"

if [ ! -x "$D/firefox/firefox" ]; then
  echo "==> descargando Firefox actual (solo esta vez; queda en tus datos)..."
  curl -sL "https://download.mozilla.org/?product=firefox-latest-ssl&os=linux64&lang=es-ES" -o "$D/f.tar.xz"
  python3 -c "import lzma,tarfile; tarfile.open('$D/f.tar.xz','r:xz').extractall('$D')"
  rm -f "$D/f.tar.xz"
else
  echo "==> Firefox ya esta en tus datos (no se descarga)"
fi

cat > "$D/ff-notion/user.js" <<PREFS
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
user_pref("browser.download.folderList", 2);
user_pref("browser.download.dir", "/headless/data/Downloads");
user_pref("gfx.webrender.software", true);
user_pref("media.hardware-video-decoding.enabled", false);
user_pref("network.prefetch-next", false);
user_pref("network.dns.disablePrefetch", true);
user_pref("network.http.speculative-parallel-limit", 0);
user_pref("network.predictor.enabled", false);
user_pref("toolkit.telemetry.enabled", false);
user_pref("datareporting.healthreport.uploadEnabled", false);
user_pref("datareporting.policy.dataSubmissionEnabled", false);
user_pref("browser.ping-centre.telemetry", false);
user_pref("app.update.auto", false);
user_pref("app.update.service.enabled", false);
user_pref("browser.discovery.enabled", false);
user_pref("extensions.pocket.enabled", false);
user_pref("accessibility.force_disabled", 1);
user_pref("browser.tabs.unloadOnLowMemory", true);
user_pref("browser.sessionstore.interval", 60000);
user_pref("browser.cache.disk.capacity", 51200);
user_pref("browser.cache.disk.smart_size.enabled", false);
PREFS

pkill -f "$D/firefox/firefox" 2>/dev/null || true
pkill -f 'chat/server.py' 2>/dev/null || true
sleep 2

if [ ! -s "$D/chat/clave.txt" ]; then
  head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$D/chat/clave.txt"
fi

MOZ_HEADLESS=1 nohup "$D/firefox/firefox" --headless --marionette --profile "$D/ff-notion" >/dev/null 2>&1 &
sleep 1
nohup python3 "$D/chat/server.py" >/dev/null 2>&1 &
sleep 3

if pgrep -f 'marionette' >/dev/null 2>&1; then
  echo "   [OK] firefox headless corriendo"
else
  echo "   [x] firefox headless NO arranco"
  exit 1
fi
i=0
while [ $i -lt 20 ]; do
  if curl -fsS http://localhost:6902/salud >/dev/null 2>&1; then
    echo "   [OK] puente respondiendo en 6902"
    break
  fi
  i=$((i+1)); sleep 2
done
INNER

# ---------- 4. prueba real desde la VM + resumen ----------
log "Verificando desde la VM (prueba real, no confianza)..."
SALUD=$(curl -fsS http://localhost:8080/salud 2>/dev/null || echo '{}')
echo "   /salud: $SALUD"
echo "$SALUD" | grep -q '"ok": true' || { err "el puente no responde en 8080 — pega: docker logs $NAME | tail -20"; exit 1; }
CLAVE=$(docker exec -i "$NAME" cat /headless/data/chat/clave.txt | tr -d '\r')

cat <<FIN

============================================================
 ✅ NAVEGADOR + MINI-WEB LISTOS EN CLOUD SHELL
------------------------------------------------------------
 1. Mini-web:  boton "Vista previa en la web" (icono de ojo/
    ventana arriba a la derecha) -> Vista previa en el puerto
    8080. Esa URL es tu mini-web (abrela tambien en tu telefono
    logueado con tu Google: la Vista Previa pide TU sesion,
    no es publica — nadie mas entra).
 2. Clave (boton ⚙ de la mini-web, se guarda sola):
    $CLAVE
 3. VNC visual (opcional): Vista previa -> Cambiar puerto ->
    8081. Clave VNC: $VNC_PASSWORD
------------------------------------------------------------
 VALIDACION: en /salud debe verse "version":"1.9.3" (arriba).
 LOGIN: ⚙ -> Sesion -> correo + codigo. NUNCA "Continuar con
 Google": la IP es de datacenter (ya nos costo una cuenta).
------------------------------------------------------------
 RECUERDA: Cloud Shell duerme a los ~20 min sin uso y recicla
 la VM; tus datos sobreviven en \$HOME/nav-data. Para volver:
   sh cs.sh
 Si la mini-web no abre tras dormir: re-corre este script.
============================================================
FIN
