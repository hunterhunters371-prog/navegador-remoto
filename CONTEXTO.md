# CONTEXTO DEL PROYECTO — Navegador remoto (hoy: Cloud Shell + Codespaces)
> Archivo de transferencia entre chats. Si eres un **chat nuevo de Notion AI** leyendo esto: aquí está todo el estado del proyecto. El usuario (Oven, Bogotá, habla español) continúa desde este punto. No le pidas repetir diagnósticos ya hechos.

---

## ⚠ Actualización 22 ago 2026 — LEE ESTO PRIMERO

- **OpenShift SUSPENDIDO** (cuenta Red Hat del usuario). nav1 y la mini-web del pod NO responden; `oc` no funciona. Reactivación solo vía soporte de Red Hat; crear una segunda cuenta viola sus términos (descartado).
- **Instancias vivas hoy:**
  1. **Google Cloud Shell** — principal. `cloudshell.sh` levanta mini-web (puerto VM 8080) + VNC (8081) en el contenedor docker `navegador`; datos en `$HOME/nav-data` (login sobrevive reinicios). Duerme ~20 min sin uso → re-correr `sh cs.sh`.
  2. **GitHub Codespaces** — respaldo. `codespaces-nav.sh` (Firefox visual jlesage en 5800, volumen `ff-perfil` persistente). 60 h/mes en máquina 2-core. Probado de nuevo hoy en el codespace `laughing-telegram-...`.
  3. **Mini-web dentro de Codespaces**: el mismo `cloudshell.sh` con `NAME=navegador2 sh cs2.sh` (puertos 8080/8081). Compatible verificado.
- **Descartados hoy (no re-investigar):** Colab para navegador (sus ToS prohíben VNC/escritorio remoto → suspendería la cuenta Google, que es la misma de Cloud Shell); AWS (pide tarjeta en el registro); GitHub Models (retirado el 30-jul-2026, aquí no se usaba pero consta).
- **Candidatos a 3ª instancia (investigados, NO probados):** Hugging Face Spaces (gratis, sin tarjeta, 2 vCPU/16 GB RAM, docker; disco NO persistente; duerme tras 48 h sin uso; requiere Dockerfile propio escuchando en 7860 — pendiente de que el usuario diga «spaces») y Caasify (gratis hasta el 31-dic-2026, volúmenes NVMe persistentes; verificar primero que el registro no pida tarjeta).
- **Tema PC del usuario:** los chats largos de Notion comen RAM en su navegador. Solución dada: Ahorro de memoria de Chrome (Configuración → Rendimiento) + `chrome://discards` para dormir pestañas manualmente; minimizar NO ahorra RAM; suspender el proceso (Process Explorer) pausa CPU pero no libera RAM. La mini-web sigue siendo la vía de datos mínimos (~1-5 MB/h vs ~100-500 MB/h del video VNC).
- El resto del documento (abajo) describe la arquitectura OpenShift: válida como referencia, **no operativa** mientras la cuenta siga suspendida.

---

## Instrucciones para el chat nuevo (importantes)

1. **NUNCA des bloques grandes de código para pegar en la terminal.** El pegado de texto largo falla (caracteres invisibles U+200B y el chat corrompe el código: asteriscos→cursivas, `_` desaparecen, nombres→links falsos). **El método**: edita/sube los archivos de este repo con la conexión GitHub del usuario y dale UN comando de una línea con `curl -fsSL <raw-url> -o x.sh && sh x.sh`.
2. El usuario opera desde la **terminal web de OpenShift** (ícono `>_` en la consola). Ahí existe `oc` y `curl`, NO existe `sudo` ni `wget`, y no hay root. (En GitHub Codespaces SÍ hay `sudo` y `docker`.) OJO 22 ago: OpenShift suspendido — esta instrucción aplica a Cloud Shell / Codespaces.
3. La detección de pods debe ser **por prefijo de nombre**, no por etiquetas (las etiquetas varían): `oc get pods --no-headers | awk '$1 ~ ("^" app "-") && $3=="Running" {print $1; exit}'`.
4. Antes de dar comandos destructivos o redespliegues, recuérdale que **las descargas y el login viven en el volumen persistente** (`nav1-data`), pero el resto del pod se borra.
5. Todo comando que se le da al usuario ya está probado en este entorno. Si algo falla, pedir la salida de `diagnostico.sh` primero, no adivinar.

## Qué es esto

Navegador remoto completo y gratis para usar **Notion** (incluidos chats pesados de Notion AI) desde cualquier navegador web, corriendo en **Red Hat Developer Sandbox** (OpenShift gratuito, sin tarjeta). El objetivo original incluía bajo consumo de RAM y sesión persistente.

## Estado 21 ago 2026 (HISTÓRICO — ya no vigente): ✅ FUNCIONABA

- Firefox actual (154.x, descargado de Mozilla) corriendo en el pod, Notion aceptado, login hecho.
- El usuario escribió un mensaje a Notion AI **desde dentro del navegador remoto** — prueba final superada.
- Persistencia implementada con PVC: login y descargas sobreviven reinicios.
- El usuario ya fue bloqueado una vez por Google (ver regla de oro abajo).
- **Nuevo (21 ago 2026):** respaldo en **GitHub Codespaces** listo — ver sección abajo.
- **Nuevo (21 ago 2026, v2.9):** paquete de rendimiento en `openshift-nav.sh` — 19 prefs nuevos de Firefox (render por software directo, sin telemetría/updates/prefetch, caché de disco topado a 50 MB, sesión escribe 1/min al volumen, pestañas se descargan con poca RAM, accesibilidad off) + URL rápida `vnc_lite.html` en el resumen. En `codespaces-nav.sh` v1.1: `--shm-size=512m` (evita caídas de pestañas en docker).
- **Nuevo (21 ago 2026, `modo.sh` v1.5):** interruptor pantalla↔**texto ligero** (experimental) — ver sección «Modo ligero» abajo. Motivo: el lag venía del VIDEO del VNC, no de la RAM.

## Arquitectura (histórica, OpenShift)

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
| `openshift-nav.sh` | ▶️ Levantar/reparar TODO en OpenShift (idempotente) — **no operativo mientras la cuenta esté suspendida** | `curl -fsSL https://raw.githubusercontent.com/hunterhunters371-prog/navegador-remoto/main/openshift-nav.sh -o os.sh && sh os.sh` |
| `cerrar.sh` | ⏸️ Pausar (scale 0) / `borrar` / `nuclear` | `curl -fsSL https://raw.githubusercontent.com/hunterhunters371-prog/navegador-remoto/main/cerrar.sh -o c.sh && sh c.sh` |
| `diagnostico.sh` | 🔍 Estado completo (pods, consumo, volumen, navegadores, procesos, RAM) | `curl -fsSL https://raw.githubusercontent.com/hunterhunters371-prog/navegador-remoto/main/diagnostico.sh -o d.sh && sh d.sh` |
| `descargar.sh` | 📥 Lista archivos del pod; los extrae vía servicios externos (0x0.st/transfer.sh/file.io — suelen estar BLOQUEADOS por el firewall del sandbox) | `... /descargar.sh -o d2.sh && sh d2.sh` |
| `publicar.sh` | 🔗 Descarga directa: expone el archivo en la propia URL del noVNC (el método que SÍ funciona en el sandbox) | `... /publicar.sh -o p.sh && sh p.sh "<archivo>"` |
| `codespaces-nav.sh` | 🐙 Firefox web (jlesage/firefox, puerto 5800) en **GitHub Codespaces** | `curl -fsSL https://raw.githubusercontent.com/hunterhunters371-prog/navegador-remoto/main/codespaces-nav.sh -o cs.sh && sh cs.sh` |
| `cloudshell.sh` | ☁️ Navegador + mini-web en **Google Cloud Shell** (v2: espera Marionette, mata navegadores de fábrica, vigilante headless). Puertos VM: 8080 mini-web, 8081 VNC | `curl -fsSL https://raw.githubusercontent.com/hunterhunters371-prog/navegador-remoto/main/cloudshell.sh -o cs.sh && sh cs.sh` |
| `modo.sh` | 🔀 Interruptor: pantalla (VNC) ↔ **texto ligero** (mini chat web con tu Notion AI + espejo 🪞) | `curl -fsSL https://raw.githubusercontent.com/hunterhunters371-prog/navegador-remoto/main/modo.sh -o m.sh && sh m.sh ligero` |
| `navegador-remoto.sh` | Stack completo para una **VM real con root** (Alpine/Debian, x86_64/ARM64): Xvfb+Chromium+x11vnc+noVNC | para cuando tenga VPS |
| `openshift/Dockerfile` | Imagen propia con Firefox horneado (builds corren como root en el sandbox) | nivel 2, opcional |
| `PROBLEMA-MODO-LIGERO.md` | 🆘 Descripción detallada del fallo del modo ligero para escalar a otra IA — RESUELTO en `modo.sh` v1.6 (return en scripts Marionette) | compartir la URL raw del archivo |

## GitHub Codespaces (respaldo por horas, sin tarjeta)

- **Qué es**: respaldo del navegador remoto usando la cuota gratis de Codespaces (cuenta GitHub del usuario, sin tarjeta): **120 horas-núcleo/mes** = 60 h en máquina 2-core (30 h si elige 4-core) + 15 GB de disco. NO es 24/7: el codespace se apaga solo a los ~30 min sin uso.
- **Cómo se usa**: crear el codespace desde el repo (botón Code → Codespaces → «Create codespace on main», imagen por defecto = trae docker) → terminal → correr `codespaces-nav.sh` → pestaña **PUERTOS/PORTS** → abrir puerto **5800** (ícono de globo).
- **Stack**: contenedor `jlesage/firefox` (web UI en 5800, `--shm-size=512m` desde v1.1), volumen docker `ff-perfil` montado en `/config` → el login de Notion sobrevive apagados del codespace. Se borra TODO solo si se elimina el codespace.
- El puerto reenviado es PRIVADO (solo el usuario logueado en GitHub lo ve). No hacerlo público sin poner contraseña.
- Regla de oro igual que en el sandbox: login de Notion = **email + código**, NUNCA Google.
- **Probado (21 ago 2026)**: el usuario lo levantó en el codespace `opulent-zebra-jr4x7x6vvw7rhp9q5` — funcionó tras aclarar que `cs.sh` va en Codespaces y `os.sh` en OpenShift. Bug de URL impresa (llaves dobles) corregido en v1.2. Re-probado 22 ago 2026 (`laughing-telegram-...`).

## Modo ligero de texto (resuelto el 21 ago, v1.6)

- **Por qué existe**: el «lag» que molesta al usuario NO es la RAM — es el **video** del VNC (stream continuo por una ruta de datacenter compartida). Una IA no necesita pantalla: basta hablar con la página y mover texto. Bonus: casi no gasta los datos del usuario (~1-5 MB/hora de uso activo vs ~100-500 MB/hora del VNC; el trabajo pesado usa el internet del datacenter).
- **Causa raíz del fallo «ocupado» (resuelta en v1.6)**: en el protocolo Marionette, `WebDriver:ExecuteScript` ejecuta el string como cuerpo de función: sin `return` devuelve `undefined`. Todos los scripts del puente eran expresiones sin `return` → cero lectura útil + candado en bucle. Corregido: `return` en todos los scripts, navegación con `WebDriver:Navigate` nativo, lector en segundo plano con caché, auto-reconexión, estados de página explícitos, `/prueba` de diagnóstico, `/recargar`, y modo sigilo opcional (`SIGILO=1`). Detalle completo en `PROBLEMA-MODO-LIGERO.md`.
- **Si el pod cae**: la mini-web cae CON el pod (vive dentro), pero NADA se pierde — clave/destino/server.py/login están en el volumen y la conversación vive en los servidores de Notion. Al volver: `sh m.sh ligero`.
- **Limitaciones**: UNA pregunta a la vez (lock); heurísticas genéricas (contenteditable + texto estable + botón Stop/Detener) — si Notion cambia su interfaz hay que ajustar `server.py`; pantalla y ligero NUNCA a la vez (el perfil se bloquearía); el espejo es de TEXTO, no de píxeles.

## Reglas aprendidas a las malas (no repetir)

1. 🚫 **Nunca login de Google/Gmail dentro del navegador remoto** — la IP del sandbox es de datacenter compartida y Google ya bloqueó la cuenta una vez por eso. Login de Notion = **email + código** (el código se lee en el correo desde la PC/teléfono del usuario).
2. 🚫 Nunca pegar código largo en chats ni en la terminal web — siempre descargar del repo con curl.
3. 🚫 El Firefox viejo de la imagen (102 ESR) y el Chromium 127: Notion los rechaza. El navegador bueno es el portable en `/headless/data/firefox/`.
4. El pod se reinicia y la terminal web se desconecta a veces (router compartido) — es normal; el pod sigue vivo.
5. Notion carga el chat completo en RAM al abrirlo: entrar primero a una página ligera; los chats gigantes se abren solo cuando se necesitan. (22 ago: mismo problema en el PC del usuario — Ahorro de memoria de Chrome + `chrome://discards`.)
6. `oc adm top pods` = consumo real. El `free` dentro del pod muestra la RAM del NODO compartido (31 GB), no la cuota — ignorar ese número.
7. 🚫 El lag de la interfaz NO se arregla con más RAM: el cuello de botella es el stream de video del VNC. Para eso existe el modo ligero (`modo.sh`).
8. 🚫 El «destino» del modo ligero es la página de NOTION (notion.so/...), nunca la URL del VNC/noVNC.
9. 🚫 (22 ago) **Nunca tokens en el chat**: si un secreto aparece en la conversación, se ROTA de inmediato, no se oculta (pasó 2 veces hoy).

## Pendientes / siguiente trabajo

- **Recuperación de la cuenta de Google**: en curso desde la PC del usuario (accounts.google.com/signin/recovery). No reintentar logins desde el navegador remoto.
- **Archivos RobloxAgentBridge (.rbxmx)**: estaban en `/headless/Descargas/` del pod viejo; si el pod fue redesplegado a v2.8, revisar `/headless/data/Downloads/` (volumen persistente) — extraerlos con `publicar.sh`. (Proyecto aparte: plugin de Roblox Studio que conecta con agentes.) OJO 22 ago: inaccesible mientras OpenShift siga suspendido.
- **VPS real (VPSWala)**: pedida pero sus 500 MB de disco NO alcanzan para un navegador moderno (~700 MB mínimo con Alpine). Oracle Cloud Always Free recortó a 2 OCPU/12 GB y exige tarjeta → descartado (el usuario no quiere dar tarjeta).
- **Multi-instancia**: con OpenShift suspendido, el mapa real es Cloud Shell + Codespaces + (candidatos: HF Spaces, Caasify). Ver la actualización de arriba.
- **Mejoras de rendimiento pendientes**: (B) Dockerfile que hornee el Firefox de Mozilla para arranques sin descarga; (E) auto-relanzar Firefox si el SANDBOX recrea el pod.
- **ClawCloud Run**: plan 24/7 ($5/mes de crédito gratis) — su regla exige cuenta GitHub de 180+ días; la del usuario se creó el 16-ago-2026 → elegible ~mediados de feb-2027.
- **Renovación del sandbox**: cada 30 días desde la consola de Red Hat Developer (cuando la cuenta se reactive).

## Cómo continuar

El usuario llega al chat nuevo y dice: «Lee https://raw.githubusercontent.com/hunterhunters371-prog/navegador-remoto/main/CONTEXTO.md y seguimos». El chat nuevo debe: leer este archivo, asumir el estado de arriba como cierto, y solo pedir la salida de `diagnostico.sh` si hay síntomas nuevos.
