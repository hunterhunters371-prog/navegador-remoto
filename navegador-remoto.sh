#!/bin/sh
# ============================================================
#  navegador-remoto.sh — Navegador remoto ultra-ligero
#  Alpine 3.20+ / Debian 12+ · x86_64 / ARM64
#  Stack: Xvfb + Chromium kiosko + x11vnc + noVNC (SIN escritorio)
#  Idempotente: ejecútalo las veces que quieras; reconfigura y ya.
#
#  Uso:       sudo sh navegador-remoto.sh
#  Personal:  sudo VNC_PASSWORD='MiClave#2026' \
#                  HOME_URL='https://www.notion.so' \
#                  RES='1280x720x16' \
#                  sh navegador-remoto.sh
#  Poco disco: sudo FORZAR=1 sh navegador-remoto.sh
# ============================================================
set -eu

# ---------- 0. Config ----------
VNC_PASSWORD="${VNC_PASSWORD:-Remoto#2026}"
HOME_URL="${HOME_URL:-https://www.notion.so}"
RES="${RES:-1280x720x16}"
HTTP_PORT="${HTTP_PORT:-6080}"
VNC_PORT="${VNC_PORT:-5900}"
DISP=":0"
STATE_DIR=/var/lib/rb
CACHE_DIR=/var/cache/rb
START_BIN=/usr/local/bin/rb-start
SVC=remotebrowser

log(){  printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
err(){  printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; }

[ "$(id -u)" -eq 0 ] || { err "Ejecuta como root (sudo sh $0)"; exit 1; }

# ---------- 1. Detectar distribución y arquitectura ----------
. /etc/os-release
DISTRO="$ID"; ARCH="$(uname -m)"
log "SO: $DISTRO ${VERSION_ID:-?} | Arch: $ARCH"

case "$DISTRO" in
  alpine)        PKG=apk ;;
  debian|devuan) PKG=apt ;;
  ubuntu|pop|linuxmint|neon)
    err "Ubuntu usa Snap para navegadores (prohibido aquí). Usa Debian 12 minimal o Alpine."
    exit 1 ;;
  *) err "Distro no soportada: $DISTRO (soportadas: alpine, debian, devuan)"; exit 1 ;;
esac
case "$ARCH" in
  x86_64|aarch64) : ;;
  *) err "Arquitectura no soportada: $ARCH"; exit 1 ;;
esac

# ---------- 2. Verificar RAM y disco ----------
RAM_MB=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
DISK_MB=$(df -m / | awk 'NR==2{print $4}')
log "RAM: ${RAM_MB} MB | Disco libre: ${DISK_MB} MB"
[ "$RAM_MB" -lt 700 ] && warn "RAM < 700 MB: irá al límite (zram se activa igual)."
if [ "$DISK_MB" -lt 900 ]; then
  warn "Disco < 900 MB: un navegador moderno no cabe en 500 MB (mínimo real ~650-700 MB con Alpine)."
  [ "${FORZAR:-0}" = "1" ] || { err "Abortado. Reintenta: sudo FORZAR=1 sh $0"; exit 1; }
  warn "Continuando por FORZAR=1."
fi

# ---------- 3. Eliminar navegadores antiguos/conflictivos ----------
log "Eliminando Firefox viejo / navegadores conflictivos (si existen)..."
if [ "$PKG" = apt ]; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get purge -y 'firefox*' 'chromium-browser' 2>/dev/null || true
  apt-get purge -y chromium 2>/dev/null || true
  apt-get autoremove -y --purge || true
else
  apk del firefox firefox-esr chromium 2>/dev/null || true
fi
if command -v firefox >/dev/null 2>&1; then
  warn "firefox aún existe en $(command -v firefox) — revisión manual recomendada"
else
  log "Firefox viejo: ausente ✓"
fi

# ---------- 4. Instalar SOLO lo necesario ----------
log "Instalando paquetes mínimos (tarda unos minutos)..."
if [ "$PKG" = apt ]; then
  apt-get install -y --no-install-recommends \
    xvfb x11vnc novnc websockify chromium fonts-freefont-ttf zram-tools iproute2 procps
  apt-get clean; rm -rf /var/lib/apt/lists/*
else
  apk add --no-cache x11vnc novnc websockify chromium ttf-freefont zram-init procps
  apk add --no-cache xorg-server-xvfb 2>/dev/null || apk add --no-cache xvfb
  rm -rf /var/cache/apk/* 2>/dev/null || true
fi

# ---------- 5. zram (colchón anti-congelamiento, sin usar disco) ----------
log "Configurando zram..."
if [ "$PKG" = apt ]; then
  systemctl enable --now zramswap.service 2>/dev/null || warn "zramswap no inició"
else
  printf 'ALGO=lz4\nSWAP_SIZE=512\n' > /etc/conf.d/zram-init
  rc-update add zram-init boot 2>/dev/null || true
  rc-service zram-init start 2>/dev/null || warn "zram-init no inició (arrancará en el próximo boot)"
fi

# ---------- 6. Contraseña VNC ----------
mkdir -p "$STATE_DIR" "$CACHE_DIR" /run/rb
x11vnc -storepasswd "$VNC_PASSWORD" "$STATE_DIR/vncpass"
chmod 600 "$STATE_DIR/vncpass"

# ---------- 7. Detectar binarios y rutas ----------
CHROME_BIN=$(command -v chromium || command -v chromium-browser || true)
[ -n "$CHROME_BIN" ] || { err "Chromium no quedó instalado."; exit 1; }
NOVNC_DIR=""
for d in /usr/share/novnc /usr/share/webapps/novnc /usr/lib/novnc; do
  [ -f "$d/vnc.html" ] && NOVNC_DIR="$d" && break
done
[ -n "$NOVNC_DIR" ] || { err "noVNC no encontrado."; exit 1; }
log "Chromium: $CHROME_BIN | noVNC: $NOVNC_DIR"

# ---------- 8. Script de arranque (todo el stack en un proceso) ----------
cat > "$START_BIN" <<EOF
#!/bin/sh
export DISPLAY=$DISP
pkill -f 'Xvfb $DISP' 2>/dev/null
pkill -x x11vnc 2>/dev/null
pkill -f websockify 2>/dev/null
pkill -f kiosk 2>/dev/null
sleep 1
Xvfb $DISP -screen 0 $RES -nolisten tcp &
sleep 1
x11vnc -display $DISP -rfbauth $STATE_DIR/vncpass -rfbport $VNC_PORT -localhost -forever -shared -noxdamage &
websockify --web $NOVNC_DIR $HTTP_PORT localhost:$VNC_PORT &
exec $CHROME_BIN --kiosk "$HOME_URL" \\
  --no-sandbox --disable-gpu --disable-dev-shm-usage \\
  --no-first-run --no-default-browser-check --password-store=basic \\
  --disable-background-networking --disable-component-update --disable-sync \\
  --disable-extensions --disable-features=site-per-process,TranslateUI \\
  --force-device-scale-factor=1 \\
  --user-data-dir=$STATE_DIR/profile \\
  --disk-cache-dir=$CACHE_DIR --disk-cache-size=52428800
EOF
chmod +x "$START_BIN"

# ---------- 9. Medición base + servicio con auto-recuperación ----------
RAM_IDLE=$(free -m | awk '/^Mem:/{print $3}')
SVC_TYPE=manual

if [ "$PKG" = apt ] && [ -d /run/systemd/system ]; then
  SVC_TYPE=systemd
  cat > /etc/systemd/system/$SVC.service <<EOF
[Unit]
Description=Navegador remoto (Xvfb+Chromium+noVNC)
After=network.target

[Service]
Type=simple
ExecStart=$START_BIN
Restart=always
RestartSec=3
MemoryMax=1100M

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now $SVC.service
elif [ "$PKG" = apk ]; then
  SVC_TYPE=openrc
  cat > /usr/local/bin/rb-supervise <<EOF
#!/bin/sh
while true; do
  $START_BIN >>/var/log/rb.log 2>&1
  sleep 3
done
EOF
  chmod +x /usr/local/bin/rb-supervise
  cat > /etc/init.d/$SVC <<EOF
#!/sbin/openrc-run
name="$SVC"
command="/usr/local/bin/rb-supervise"
command_background="yes"
pidfile="/run/rb/supervise.pid"
EOF
  chmod +x /etc/init.d/$SVC
  rc-update add $SVC default 2>/dev/null || true
  rc-service $SVC restart 2>/dev/null || { nohup /usr/local/bin/rb-supervise >/var/log/rb.log 2>&1 & }
else
  warn "Sin systemd/OpenRC: arranque manual. Para auto-inicio agrega '$START_BIN' a tu rc.local."
  nohup "$START_BIN" >/var/log/rb.log 2>&1 &
fi

# ---------- 10. Verificación automática ----------
sleep 10
check(){ if eval "$2" >/dev/null 2>&1; then printf '  [\033[1;32m✓\033[0m] %s\n' "$1"; else printf '  [\033[1;31m✗\033[0m] %s\n' "$1"; fi; }
alive(){ ps aux | grep "$1" | grep -qv grep; }

echo; log "VERIFICACIÓN"
check "arquitectura ($ARCH)"            "[ '$ARCH' = 'x86_64' ] || [ '$ARCH' = 'aarch64' ]"
check "RAM disponible (>=700 MB)"       "[ $RAM_MB -ge 700 ]"
check "almacenamiento (>=900 MB libres)" "[ $DISK_MB -ge 900 ]"
check "navegador instalado"             "command -v $CHROME_BIN"
check "versión: $($CHROME_BIN --version 2>/dev/null | head -1)" "true"
check "firefox antiguo eliminado"       "! command -v firefox"
case "$SVC_TYPE" in
  systemd) check "servicio remoto activo" "systemctl is-active --quiet $SVC" ;;
  openrc)  check "supervisor activo"      "alive rb-supervise" ;;
  *)       check "proceso de arranque"    "alive rb-start" ;;
esac
check "puerto web $HTTP_PORT escuchando" "ss -tln 2>/dev/null | grep -q ':$HTTP_PORT' || netstat -tln 2>/dev/null | grep -q ':$HTTP_PORT'"
check "chromium ejecutándose"            "alive kiosk"

echo; echo "─── consumo real ───"
free -h; echo; df -h /
echo
if ps aux --sort=-%mem >/tmp/rb_ps.$$ 2>/dev/null; then head -8 /tmp/rb_ps.$$; else ps aux | head -8; fi
rm -f /tmp/rb_ps.$$

# ---------- 11. Prueba de estabilidad (60 s) ----------
echo; log "Prueba de estabilidad (60 segundos)..."
sleep 20
RAM_BROWSER=$(free -m | awk '/^Mem:/{print $3}')
STABLE=0; i=1
while [ $i -le 6 ]; do
  sleep 10
  if alive kiosk && alive websockify; then STABLE=$((STABLE+1)); fi
  printf '   t=%ss  RAM usada=%s MB\n' "$((i*10))" "$(free -m | awk '/^Mem:/{print $3}')"
  i=$((i+1))
done
LOAD=$(cut -d' ' -f1-3 /proc/loadavg)
DISK_USED=$(df -h / | awk 'NR==2{print $3}')

# ---------- 12. Resumen + datos de conexión ----------
IP=$(hostname -I 2>/dev/null | awk '{print $1}')
[ -n "$IP" ] || IP=$(ip -4 addr show scope global 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -1)
cat <<FIN

============================================================
 ✅ NAVEGADOR REMOTO LISTO
------------------------------------------------------------
 URL:        http://$IP:$HTTP_PORT/vnc.html
             (rápida: http://$IP:$HTTP_PORT/vnc_lite.html?autoconnect=true)
 Contraseña: $VNC_PASSWORD
 Página:     $HOME_URL
------------------------------------------------------------
 RESUMEN DE RENDIMIENTO
 RAM idle:     ${RAM_IDLE} MB
 RAM browser:  ${RAM_BROWSER} MB
 CPU browser:  $LOAD  (loadavg 1/5/15 min)
 Disk used:    $DISK_USED
 Estabilidad:  $STABLE/6 chequeos OK en 60 s
------------------------------------------------------------
 RECUPERACIÓN
 Debian:  systemctl {start|stop|restart|status} $SVC
          logs: journalctl -u $SVC -f
 Alpine:  rc-service $SVC {start|stop|restart|status}
          logs: tail -f /var/log/rb.log
 Manual:  sh $START_BIN
 Reconfigurar: ejecuta de nuevo este script con nuevas variables
 Desinstalar: para el servicio y borra:
   $START_BIN, /etc/systemd/system/$SVC.service o /etc/init.d/$SVC,
   $STATE_DIR y $CACHE_DIR
------------------------------------------------------------
 SEGURIDAD
 · VNC crudo ($VNC_PORT) solo escucha en localhost; tu puerta es $HTTP_PORT con clave.
 · Cambia la clave: sudo VNC_PASSWORD='OtraClave' sh $0
 · Para exponer a Internet: NO abras $VNC_PORT; pon Caddy/nginx con TLS
   delante del $HTTP_PORT, o entra por túnel SSH:
   ssh -L $HTTP_PORT:localhost:$HTTP_PORT usuario@$IP
============================================================
FIN
