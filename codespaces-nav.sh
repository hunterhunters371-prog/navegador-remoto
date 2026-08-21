#!/bin/sh
# codespaces-nav.sh — Firefox remoto (interfaz web) en GitHub Codespaces
# v1.1: + --shm-size=512m (evita que las pestañas de Firefox se caigan:
#         docker da solo 64 MB de /dev/shm por defecto)
# Uso: curl -fsSL https://raw.githubusercontent.com/hunterhunters371-prog/navegador-remoto/main/codespaces-nav.sh -o cs.sh && sh cs.sh
set -e

NAME=navegador
PORT=5800
IMG=jlesage/firefox

echo "==> Verificando docker..."
if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: este codespace no tiene docker. Crealo con la imagen por defecto (universal)." >&2
  exit 1
fi
if ! docker info >/dev/null 2>&1; then
  echo "==> Iniciando dockerd..."
  sudo dockerd >/tmp/dockerd.log 2>&1 &
  sleep 5
fi

if docker ps -a --format '{{.Names}}' | grep -qx "$NAME"; then
  echo "==> El contenedor '$NAME' ya existe; iniciandolo..."
  docker start "$NAME"
else
  echo "==> Creando '$NAME' (la primera vez descarga la imagen, tarda unos minutos)..."
  docker run -d --name "$NAME" \
    -p "$PORT":5800 \
    --shm-size=512m \
    -v ff-perfil:/config \
    -e DISPLAY_WIDTH=1366 \
    -e DISPLAY_HEIGHT=768 \
    --restart unless-stopped \
    "$IMG"
fi

echo "==> Esperando a que responda el puerto $PORT..."
i=0
while [ "$i" -lt 40 ]; do
  if curl -fsS "http://localhost:$PORT" >/dev/null 2>&1; then break; fi
  i=$((i+1)); sleep 3
done

URL="http://localhost:$PORT"
if [ -n "${CODESPACE_NAME:-}" ] && [ -n "${GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN:-}" ]; then
  URL="{{https://${CODESPACE_NAME}}}-${PORT}.${GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN}/"
fi
echo
echo "======================================================="
echo " ✅ Firefox listo"
echo " URL: $URL"
echo " Si no abre: pestana PUERTOS (PORTS) -> $PORT -> icono de globo"
echo " Login/perfil persistente en el volumen docker 'ff-perfil'"
echo " (sobrevive apagados del codespace; se borra si BORRAS el codespace)"
echo " NOTA: si creaste el contenedor con una version vieja de este"
echo " script (sin shm), recrealo una vez: docker rm -f navegador"
echo " y vuelve a correr este comando. El perfil NO se pierde."
echo " RECORDATORIO: login de Notion = email + codigo. NUNCA Google."
echo "======================================================="
