# CONTEXTO DEL PROYECTO — Navegador remoto en OpenShift
> Archivo de transferencia entre chats. Si eres un **chat nuevo de Notion AI** leyendo esto: aquí está todo el estado del proyecto. El usuario (Oven, Bogotá, habla español) continúa desde este punto. No le pidas repetir diagnósticos ya hechos.

## Instrucciones para el chat nuevo (importantes)

1. **NUNCA des bloques grandes de código para pegar en la terminal.** El pegado de texto largo falla (caracteres invisibles U+200B y el chat corrompe el código: asteriscos→cursivas, `_` desaparecen, nombres→links falsos). **El método**: edita/sube los archivos de este repo con la conexión GitHub del usuario y dale UN comando de una línea con `curl -fsSL <raw-url> -o x.sh && sh x.sh`.
2. El usuario opera desde la **terminal web de OpenShift** (ícono `>_` en la consola). Ahí existe `oc` y `curl`, NO existe `sudo` ni `wget`, y no hay root. (En GitHub Codespaces SÍ hay `sudo` y `docker`.)
3. La detección de pods debe ser **por prefijo de nombre**, no por etiquetas (las etiquetas varían): `oc get pods --no-headers | awk '$1 ~ ("^" app "-") && $3=="Running" {print $1; exit}'`.
4. Antes de dar comandos destructivos o redespliegues, recuérdale que **las descargas y el login viven en el volumen persistente** (`nav1-data`), pero el resto del pod se borra.
5. Todo comando que se le da al usuario ya está probado en este entorno. Si algo falla, pedir la salida de `diagnostico.sh` primero, no adivinar.

## Qué es esto

Navegador remoto completo y gratis para usar **Notion** (incluidos chats pesados de Notion AI) desde cualquier navegador web, corriendo en **Red Hat Developer Sandbox** (OpenShift gratuito, sin tarjeta). El objetivo original incluía bajo consumo de RAM y sesión persistente.

## Estado actual (21 ago 2026): ✅ FUNCIONANDO

- Firefox actual (154.x, descargado de Mozilla) corriendo en el pod, Notion aceptado, login hecho.
- El usuario escribió un mensaje a Notion AI **desde dentro del navegador remoto** — prueba final superada.
- Persistencia implementada con PVC: login y descargas sobreviven reinicios.
- El usuario ya fue bloqueado una vez por Google (ver regla de oro abajo).
- **Nuevo (21 ago 2026):** respaldo en **GitHub Codespaces** listo — ver sección abajo.
- **Nuevo (21 ago 2026, v2.9):** paquete de rendimiento en `openshift-nav.sh` — 19 prefs nuevos de Firefox (render por software directo, sin telemetría/updates/prefetch, caché de disco topado a 50 MB, sesión escribe 1/min al volumen, pestañas se descargan con poca RAM, accesibilidad off) + URL rápida `vnc_lite.html` en el resumen. En `codespaces-nav.sh` v1.1: `--shm-size=512m` (evita caídas de pestañas en docker).
- **Nuevo (21 ago 2026, `modo.sh` v1.2):** interruptor pantalla↔**texto ligero** (experimental) — ver sección «Modo ligero» abajo. Motivo: el lag venía del VIDEO del VNC, no de la RAM.

## Arquitectura actual

- **Plataforma**: Red Hat Developer Sandbox, namespace `dayalert7-dev`, usuario `dayalert7`
- **Consola**: https://console-openshift-console.apps.rm1.0a51.p1.openshiftapps.com
- **App**: `nav1` (imagen `docker.io/consol/rocky-icewm-vnc` — Rocky Linux 9 + IceWM; contiene Firefox 102 ESR viejo que NO se usa)
- **Ruta/URL**: https://nav1-dayalert7-dev.apps.rm1.0a51.p1.openshiftapps.com (edge/Redirect, puerto 6901; acceso con `?password=<VNC_PASSWORD>`)
- **Ruta del chat ligero**: https://nav1-chat-dayalert7-dev.apps.rm1.0a51.p1.openshiftapps.com (puerto 6902; clave en `/headless/data/chat/clave.txt`)
- **Contraseña VNC**: la por defecto de `openshift-nav.sh` (cambiable con `VNC_PASSWORD=`)
- **Recursos**: requests 250m/512Mi — límites 2 CPU / 5Gi RAM (cuota total del sandbox: ~14 GB RAM, 3 núcleos, 40 GB disco; se renueva cada 30 días gratis)
- **Video**: pantalla virtual 1024x600 x 16 bits (`VNC_RESOLUTION`/`VNC_COL_DEPTH`)
- **Volumen persistente**: PVC `nav1-data` (2Gi) montado en `/headless/data` → ahí viven: `firefox/` (binario portable), `ff-notion/` (perfil con cookies/login), `Downloads/` (descargas), `chat/` (modo ligero: server.py, chat.html, clave.txt, destino.txt). Sobrevive a redespliegues y a `cerrar.sh borrar`. Solo se borra con `oc delete pvc nav1-data` o `sh c.sh nuclear`.
- **Firefox**: portable de Mozilla en `/headless/data/firefox/firefox`, perfil `/headless/data/ff-notion` con 1 proceso de contenido (Fission apagado), sin caché RAM, sin autoplay; ventana única al tamaño de la pantalla (NO kiosko — el kiosko bloqueaba el login y la navegación). Desde v2.9: render por software, telemetría/updates/prefetch apagados.
- **Auto-revive**: vigilante cada 15 s relanza Firefox si cae. Los íconos del escritorio (IceWM menu/toolbar) apuntan al Firefox nuevo.
- **Red**: VNC crudo solo localhost; la puerta es el 6901 web con contraseña.

## Caja de herramientas (este repo, rama main)

| Script | Qué hace | Comando |
|---|---|---|
| `openshift-nav.sh` | ▶️ Levantar/reparar TODO (idempotente) | `curl -fsSL https://raw.githubusercontent.com/hunterhunters371-prog/navegador-remoto/main/openshift-nav.sh -o os.sh && sh os.sh` |
| `cerrar.sh` | ⏸️ Pausar (scale 0) / `borrar` / `nuclear` | `curl -fsSL https://raw.githubusercontent.com/hunterhunters371-prog/navegador-remoto/main/cerrar.sh -o c.sh && sh c.sh` |
| `diagnostico.sh` | 🔍 Estado completo (pods, consumo, volumen, navegadores, procesos, RAM) | `curl -fsSL https://raw.githubusercontent.com/hunterhunters371-prog/navegador-remoto/main/diagnostico.sh -o d.sh && sh d.sh` |
| `descargar.sh` | 📥 Lista archivos del pod; los extrae vía servicios externos (0x0.st/transfer.sh/file.io — suelen estar BLOQUEADOS por el firewall del sandbox) | `... /descargar.sh -o d2.sh && sh d2.sh` |
| `publicar.sh` | 🔗 Descarga directa: expone el archivo en la propia URL del noVNC (el método que SÍ funciona en el sandbox) | `... /publicar.sh -o p.sh && sh p.sh "<archivo>"` |
| `codespaces-nav.sh` | 🐙 Firefox web (jlesage/firefox, puerto 5800) en **GitHub Codespaces** | `curl -fsSL https://raw.githubusercontent.com/hunterhunters371-prog/navegador-remoto/main/codespaces-nav.sh -o cs.sh && sh cs.sh` |
| `modo.sh` | 🔀 Interruptor: pantalla (VNC) ↔ **texto ligero** (mini chat web con tu Notion AI + espejo 🪞) | `curl -fsSL https://raw.githubusercontent.com/hunterhunters371-prog/navegador-remoto/main/modo.sh -o m.sh && sh m.sh ligero` |
| `navegador-remoto.sh` | Stack completo para una **VM real con root** (Alpine/Debian, x86_64/ARM64): Xvfb+Chromium+x11vnc+noVNC | para cuando tenga VPS |
| `openshift/Dockerfile` | Imagen propia con Firefox horneado (builds corren como root en el sandbox) | nivel 2, opcional |

## GitHub Codespaces (respaldo por horas, sin tarjeta) — agregado 21 ago 2026

- **Qué es**: respaldo del navegador remoto usando la cuota gratis de Codespaces (cuenta GitHub del usuario, sin tarjeta): **120 horas-núcleo/mes** = 60 h en máquina 2-core (30 h si elige 4-core) + 15 GB de disco. NO es 24/7: el codespace se apaga solo a los ~30 min sin uso.
- **Cómo se usa**: crear el codespace desde el repo (botón Code → Codespaces → «Create codespace on main», imagen por defecto = trae docker) → terminal → correr `codespaces-nav.sh` (comando en la tabla de arriba) → pestaña **PUERTOS/PORTS** → abrir puerto **5800** (ícono de globo).
- **Stack**: contenedor `jlesage/firefox` (web UI en 5800, `--shm-size=512m` desde v1.1), volumen docker `ff-perfil` montado en `/config` → el login de Notion sobrevive apagados del codespace. Se borra TODO solo si se elimina el codespace.
- El puerto reenviado es PRIVADO (solo el usuario logueado en GitHub lo ve). No hacerlo público sin poner contraseña.
- Regla de oro igual que en el sandbox: login de Notion = **email + código**, NUNCA Google.
- **Probado (21 ago 2026)**: el usuario lo levantó en el codespace `opulent-zebra-jr4x7x6vvw7rhp9q5` — funcionó tras aclarar que `cs.sh` va en Codespaces y `os.sh` en OpenShift. Bug de URL impresa (llaves dobles) corregido en v1.2.

## Modo ligero de texto (experimental) — agregado 21 ago 2026

- **Por qué existe**: el «lag» que molesta al usuario NO es la RAM — es el **video** del VNC (stream continuo por una ruta de datacenter compartida). Una IA no necesita pantalla: basta hablar con la página y mover texto.
- **Qué hace `modo.sh ligero`** (interruptor sobre el MISMO pod de nav1):
  1. Crea service+ruta `$APP-chat` (puerto 6902, edge/Redirect) reutilizando el selector del service original.
  2. Instala en el volumen (`/headless/data/chat/`): `server.py` (puente Python solo-stdlib) y `chat.html` (mini UI de ~10 KB).
  3. Mata el vigilante y el Firefox de pantalla; arranca **Firefox headless** con `--marionette` (protocolo nativo de control de Firefox, puerto 2828, sin descargar nada) usando el MISMO perfil `ff-notion` (login intacto).
  4. Levanta `server.py` en 6902: sirve el chat; `POST /preguntar` escribe en el composer de Notion AI (truco `execCommand("insertText")` + Enter sintético) y espera la respuesta leyendo `innerText` de `main` hasta que queda estable y no hay botón Stop/Detener. Patrón async (job + `/estado`) para esquivar el timeout ~30 s de la ruta HAProxy.
- **Espejo y streaming (v1.2)**: `/estado` devuelve `parcial` mientras genera (la burbuja se actualiza en vivo, cada 2.5 s); el botón 🪞 llama `/espejo` (cada 4 s) y muestra el texto actual de la página (últimos 4000 caracteres; si hay pregunta en curso devuelve el parcial — Marionette es mono-hilo con lock).
- **Clave**: se genera una vez en `/headless/data/chat/clave.txt`, la imprime modo.sh; la mini-web la guarda en localStorage. El endpoint `/debug?clave=...` (v1.1) reporta qué está viendo el headless (url, título, composer, ¿pantalla de login?).
- **Destino por defecto**: https://www.notion.so/chat — cambiable en el ⚙ de la mini-web o en `destino.txt`. **Desde v1.1 se valida que contenga "notion"** (el usuario puso por error la URL del VNC y el headless quedó navegando al noVNC — no repetir).
- **Si el pod cae/se desconecta** (pregunta del usuario 21 ago): la mini-web se cae CON el pod (vive dentro), pero NADA se pierde — clave/destino/server.py/login están en el volumen y la conversación vive en los servidores de Notion. Al volver el pod: `sh m.sh ligero` y listo. (El pendiente E —auto-arranque tras recreación— cubriría reactivarlo solo.)
- **Volver**: `sh modo.sh pantalla` mata server.py + headless y relanza el Firefox gráfico + vigilante (mismo código que os.sh).
- **Estado de la prueba (21 ago 2026 ~22:35Z)**: mini-web OK, clave OK, mensajes llegan al puente; pendiente confirmar que Notion AI responda con el destino correcto (el primer intento quedó en "pensando..." por el destino errado).
- **Limitaciones**: UNA pregunta a la vez (lock); heurísticas genéricas (contenteditable + texto estable + botón Stop/Detener) — si Notion cambia su interfaz hay que ajustar `server.py`; el escritorio VNC (Xvfb/IceWM) sigue corriendo idle en modo ligero; pantalla y ligero NUNCA a la vez (el perfil se bloquearía); el espejo es de TEXTO, no de píxeles (clonar imagen en vivo = video = el lag que estamos evitando).
- **Si falla**: `sh modo.sh pantalla` restaura lo de siempre; pedir salida completa del comando + el JSON de `/debug?clave=...` y ajustar selectores/heurísticas.

## Reglas aprendidas a las malas (no repetir)

1. 🚫 **Nunca login de Google/Gmail dentro del navegador remoto** — la IP del sandbox es de datacenter compartida y Google ya bloqueó la cuenta una vez por eso. Login de Notion = **email + código** (el código se lee en el correo desde la PC/teléfono del usuario).
2. 🚫 Nunca pegar código largo en chats ni en la terminal web — siempre descargar del repo con curl.
3. 🚫 El Firefox viejo de la imagen (102 ESR) y el Chromium 127: Notion los rechaza. El navegador bueno es el portable en `/headless/data/firefox/`.
4. El pod se reinicia y la terminal web se desconecta a veces (router compartido) — es normal; el pod sigue vivo.
5. Notion carga el chat completo en RAM al abrirlo: entrar primero a una página ligera; los chats gigantes (como el que generó este proyecto) se abren solo cuando se necesitan.
6. `oc adm top pods` = consumo real. El `free` dentro del pod muestra la RAM del NODO compartido (31 GB), no la cuota — ignorar ese número.
7. 🚫 El lag de la interfaz NO se arregla con más RAM: el cuello de botella es el stream de video del VNC. Para eso existe el modo ligero (`modo.sh`).
8. 🚫 El «destino» del modo ligero es la página de NOTION (notion.so/...), nunca la URL del VNC/noVNC.

## Pendientes / siguiente trabajo

- **Recuperación de la cuenta de Google**: en curso desde la PC del usuario (accounts.google.com/signin/recovery). No reintentar logins desde el navegador remoto.
- **Archivos RobloxAgentBridge (.rbxmx)**: estaban en `/headless/Descargas/` del pod viejo; si el pod fue redesplegado a v2.8, revisar `/headless/data/Downloads/` (volumen persistente) — extraerlos con `publicar.sh`. (Proyecto aparte: plugin de Roblox Studio que conecta con agentes.)
- **VPS real (VPSWala)**: pedida pero sus 500 MB de disco NO alcanzan para un navegador moderno (~700 MB mínimo con Alpine). Si llega otra VPS con más disco → usar `navegador-remoto.sh`. NOTA (21 ago 2026): Oracle Cloud Always Free daba 4 OCPU/24 GB pero el 15-jun-2026 lo recortó a 2 OCPU/12 GB y exige tarjeta → descartado por ahora (el usuario no quiere dar tarjeta).
- **Multi-instancia (investigado 21 ago 2026)**: NO hace falta otra cuenta — en la misma cuenta/namespace caben ~2-3 instancias (`APP=nav2 sh os.sh`; si la cuota se queja por límites, usar `APP=nav2 LIM_MEM=3Gi sh os.sh`). Crear una segunda cuenta de Red Hat viola sus términos (prohíben múltiples cuentas para eludir límites) y pide otro SMS de teléfono → descartado.
- **Mejoras de rendimiento pendientes (analizadas 21 ago 2026)**: (B) Dockerfile que hornee el Firefox de Mozilla (no el ESR de dnf) para arranques sin descarga; (E) auto-relanzar Firefox si el SANDBOX recrea el pod (FAQ: pods se borran tras 12 h corridas — el vigilante muere con el pod; verificar hook de arranque de la imagen consol, p.ej. icewm startup). A+C+D ya aplicados en v2.9 / v1.1.
- **Otras plataformas gratis sin tarjeta (investigado 21 ago 2026)**: ClawCloud Run ($5/mes cuando el GitHub cumpla 180 días, ~feb-2027) es el único 24/7 viable futuro. Google Cloud Shell (50 h/semana) y Codespaces (60 h/mes) = respaldos por horas. Zeabur/Koyeb/Render/Back4app duermen o tienen ≤512 MB RAM → no sirven. Railway = $5 únicos. Ojo con sitios de «VPS gratis sin tarjeta»: casi todos son estafa.
- **ClawCloud Run** (run.claw.cloud): plan de respaldo 24/7 ($5/mes de crédito gratis). OJO: su regla exige cuenta GitHub de 180+ días para el crédito recurrente; la del usuario se creó el 16-ago-2026 → elegible ~mediados de feb-2027. Con Gmail dan $5 iniciales únicos.
- **Cloud Shell** (shell.cloud.google.com): alternativa estable; el contenedor docker `jlesage/firefox` quedó creado allí (`docker start navegador` → Web Preview puerto 8080). Efímero fuera de $HOME.
- **Renovación del sandbox**: cada 30 días desde la consola de Red Hat Developer.

## Cómo continuar

El usuario llega al chat nuevo y dice: «Lee https://raw.githubusercontent.com/hunterhunters371-prog/navegador-remoto/main/CONTEXTO.md y seguimos». El chat nuevo debe: leer este archivo, asumir el estado de arriba como cierto, y solo pedir la salida de `diagnostico.sh` si hay síntomas nuevos.
