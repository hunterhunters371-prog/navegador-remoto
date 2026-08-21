# PROBLEMA A RESOLVER — Puente de texto a Notion AI (modo ligero) no logra leer la página

> Documento de handoff para otra IA. Contiene: objetivo, entorno exacto, arquitectura, evidencia de lo que funciona, síntomas del fallo, hipótesis ordenadas, qué ya se intentó, rutas de solución y restricciones del proyecto.
> Repo: `hunterhunters371-prog/navegador-remoto`, rama `main`.
> Fecha del estado descrito: 21 ago 2026, ~23:20 UTC.

## 1. Objetivo

Dar al usuario una **interfaz de texto minimalista** para hablar con **Notion AI** desde cualquier dispositivo débil, sin el lag del streaming de video VNC. Un programa dentro del pod debe: abrir la página de Notion AI en un Firefox **headless**, escribir la pregunta del usuario en el composer de Notion AI, esperar la respuesta y devolverla como texto a una mini-web de chat.

El modo gráfico (VNC + Firefox visible) **ya funciona** con el mismo pod, perfil y login: el usuario chateó con Notion AI desde ahí. El modo ligero es la pieza nueva y experimental.

## 2. Entorno exacto

- **Plataforma**: Red Hat Developer Sandbox (OpenShift gratis). Namespace `dayalert7-dev`.
- **Pod**: imagen `docker.io/consol/rocky-icewm-vnc` (Rocky Linux 9 + IceWM + noVNC en puerto 6901).
- **Sin root, UID arbitrario** (OpenShift). Existen `python3`, `curl`, `oc` (en la terminal web), NO `sudo`/`wget`.
- **Recursos**: requests 250m CPU / 512Mi RAM — límites 2 CPU / 5Gi RAM. **La CPU capada es relevante**: la SPA de Notion tarda mucho en cargar/hidratar.
- **Volumen persistente** montado en `/headless/data` (PVC `nav1-data`):
  - `firefox/` → Firefox portable 154.x (Mozilla, linux64, es-ES) en `/headless/data/firefox/firefox`.
  - `ff-notion/` → perfil con **login activo de Notion** (probado en modo gráfico).
  - `chat/` → `server.py`, `chat.html`, `clave.txt`, `destino.txt` (los instala `modo.sh`).
- **Red**: ruta edge/Redirect de OpenShift (HAProxy, timeout ~30 s por request → por eso el patrón async job + polling). Ruta del chat: `https://nav1-chat-dayalert7-dev.apps.rm1.0a51.p1.openshiftapps.com` (puerto 6902).

## 3. Arquitectura implementada (`modo.sh` v1.5)

`modo.sh ligero` (script POSIX, corre en la terminal web de OpenShift):

1. Crea Service+Ruta `nav1-chat` (puerto 6902) reutilizando el selector del Service original.
2. Escribe `server.py` y `chat.html` en `/headless/data/chat/`.
3. Mata el Firefox gráfico y el vigilante; arranca:
   `MOZ_HEADLESS=1 /headless/data/firefox/firefox --headless --marionette --profile /headless/data/ff-notion`
4. Arranca `python3 server.py` en 6902.

**`server.py`** (solo stdlib de Python, sin pip):
- **Cliente Marionette mínimo hecho a mano**: protocolo v3, framing `<longitud>:<json>` sobre TCP `127.0.0.1:2828`; comandos usados: `WebDriver:NewSession` y `WebDriver:ExecuteScript` (la navegación se hace con `location.href` vía ExecuteScript, para minimizar superficie de comandos).
- **Un solo lock global** (`m_lock`) serializa TODO acceso a Marionette (el socket no es hilo-seguro).
- Endpoints: `/` (chat.html), `/salud` (sin clave, nunca bloquea), `/preguntar` (POST texto → job async, hilo con lock), `/estado?id=` (incluye `parcial` en vivo), `/espejo` (texto actual de la página, últimos 4000 chars), `/destino` (GET/POST, valida que contenga "notion"), `/debug?clave=` (url/título/composer/login de la página).
- **Precarga**: al arrancar, un hilo navega a `destino` (`lanzar_calentar`). Estado de página: `cargando → por-verificar → lista`.
- **JS inyectado clave**:
  - Composer: `document.querySelectorAll('div[contenteditable="true"]')` visibles, último de la lista.
  - Enviar: `ed.focus(); document.execCommand("selectAll"); document.execCommand("insertText", false, texto); ed.dispatchEvent(new KeyboardEvent("keydown", {key:"Enter", keyCode:13, bubbles:true}))`.
  - Leer: `(document.querySelector("main") || document.body).innerText` + detección de streaming por botón con `aria-label` Stop/Detener.
- Respuesta = texto de `main` tras el último eco del prompt, considerada final cuando es idéntica en 2 polls consecutivos (2 s) y no hay botón Stop visible. Timeout 300 s.

## 4. Qué SÍ funciona (evidencia real del usuario)

- Despliegue, ruta, mini-web, autenticación por clave: OK (capturas del usuario).
- Firefox headless vivo y Marionette con sesión:
  `GET /salud` → `{"ok": true, "modo": "ligero", "firefox_headless": true, "marionette": "conectado (sesion activa)", "destino": "https://www.notion.so/chat", "pagina": ...}`
- El autovalidador de destino corrigió un valor errado previo (el usuario había guardado la URL del VNC por error; hoy solo se aceptan URLs con "notion").

## 5. El problema exacto

**La página nunca se vuelve legible para el puente.** Síntomas observados (con v1.3/v1.4, antes del fix de contención de v1.5):

- `/espejo` siempre devuelve texto vacío → la mini-web muestra "cargando Notion..." indefinidamente.
- `/debug` repetidamente devolvía `{"ocupado": true, "parcial": "", "destino_configurado": "https://www.notion.so/Chat-pesado-de-prueba-3269d22d183d80b0a680dfa3210a7942"}` durante >5 minutos.
- Nadie reportó haber enviado pregunta en ese intervalo → quien sostiene el lock es `lanzar_calentar()` o llamadas `leer()` lentas, NO un trabajo de chat.

**Interpretación del equipo (hipótesis ordenadas por probabilidad):**

1. **Cada `ExecuteScript` queda congelado esperando al hilo principal** mientras la SPA de Notion carga/hidrata con la CPU capada (requests 250m). Síntoma compatible: `NewSession` conecta (eso no toca la página), pero los scripts sobre el documento tardan hasta el timeout (90 s) cada uno. Consecuencia: lock ocupado casi siempre, `innerText` nunca llega, espejo vacío.
2. **La página quedó en una pantalla de login** o en un estado sin texto útil (menos probable: el login se probó en GUI con el mismo perfil; pero las cookies podrían no aplicar en headless si hay particionado/detención).
3. **Notion detecta automatización**: con Marionette activo, `navigator.webdriver === true`. Notion podría alterar el flujo (bloqueo silencioso, captcha invisible, layout distinto). Mitigación candidata: `user_pref("dom.webdriver.enabled", false)` en el perfil (ojo: verificar que Marionette siga funcionando con ese pref).
4. **El destino de prueba era una página de documento** (`/Chat-pesado-de-prueba-<id>`), no un chat de IA → puede no tener composer de "Pregunta...". No explica por sí solo el `ocupado` eterno, pero sí haría fallar `/preguntar` después.
5. Bugs propios ya corregidos en v1.5 (contención del espejo, no-navegación al cambiar destino) — **pendiente re-medir con v1.5**.

## 6. Qué ya se intentó (no repetir)

- v1.1: validación de destino + `/debug`. v1.2: streaming parcial + espejo. v1.3: precarga al arrancar + autovalidación de `destino.txt`. v1.4: `/salud` sin bloqueo + `/debug` no bloqueante. v1.5: navegación inmediata al cambiar destino + estado de página explícito para que el espejo no compita durante la carga.
- Verificar salud de Marionette: OK ("conectado"). El problema NO es la conexión; es la lectura/escritura del DOM en la página cargando.
- El lector web externo del asistente NO alcanza las rutas del sandbox (no reintentar por ahí): el diagnóstico lo abre el usuario en su navegador y pega el JSON.

## 7. Qué debe hacer la IA que tome esto (plan concreto)

1. **Medir con v1.5**: tras `sh m.sh ligero`, esperar 3 min SIN tocar espejo ni chat, luego `GET /debug?clave=...` → registrar `url_actual`, `titulo`, `composer_encontrado`, `parece_pantalla_de_login`, `pagina`. Ese JSON es la bifurcación:
   - `parece_pantalla_de_login: true` → renovar login en modo pantalla (`sh m.sh pantalla`, login email+código, volver con `sh m.sh ligero`).
   - `composer_encontrado: true` → probar `/preguntar` de inmediato; si responde, listo.
   - `url_actual` vacío/about:blank tras 3+ min → la navegación o la carga nunca termina: ir a (2).
2. **Si la carga de la SPA es el cuello de botella** (hipótesis 1):
   - Esperar más antes de leer (subir el `sleep(20)` post-navegación a 60-90 s) y/o subir `REQ_CPU` del pod (400-500m) para la carga inicial.
   - Reducir peso de la página: prefs del perfil para bloquear medios/trackers (`permissions.default.image=2` SOLO si no rompe el composer — probar).
   - Alternativa más robusta que raspar el DOM: **usar la API interna de Notion desde el contexto de la página** (fetch con las cookies de sesión a los endpoints que el propio frontend usa para el chat de AI). Requiere inspeccionar `notion.so/chat` en un navegador normal (DevTools → Network) y replicar las llamadas. Más frágil a cambios internos, pero no depende del render.
3. **Si hay detección de automatización** (hipótesis 3): añadir `dom.webdriver.enabled=false` al `user.js` del perfil, reiniciar headless y re-medir. Verificar que Marionette siga respondiendo.
4. **Aislar CPU**: correr el mismo `server.py` en el codespace de respaldo (2-core, sin capar) contra el MISMO perfil copiado, o localmente, para descartar que sea solo lentitud del sandbox.
5. **Destino de prueba correcto**: usar `https://www.notion.so/chat` (home de Notion AI, garantiza composer) y no una página-documento.

## 8. Restricciones del proyecto (obligatorias)

- NUNCA entregar bloques largos de código para pegar en terminal/chat (se corrompen). Editar/subir archivos al repo vía GitHub y dar UN comando de una línea `curl -fsSL <raw> -o x.sh && sh x.sh`.
- Sin root, sin sudo, sin pip garantizado: `server.py` debe seguir siendo **stdlib pura**.
- Login de Notion = email + código; NUNCA Google (IP de datacenter = bloqueo).
- El perfil `ff-notion` es compartido con el modo gráfico: pantalla y ligero no corren a la vez (lock de perfil).
- El usuario habla español; respuestas y mensajes de UI en español.

## 9. Cómo reproducir

```
# Terminal web de OpenShift (icono >_):
curl -fsSL https://raw.githubusercontent.com/hunterhunters371-prog/navegador-remoto/main/openshift-nav.sh -o os.sh && sh os.sh   # si nav1 no existe
curl -fsSL https://raw.githubusercontent.com/hunterhunters371-prog/navegador-remoto/main/modo.sh -o m.sh && sh m.sh ligero
# Navegador del usuario:
https://nav1-chat-dayalert7-dev.apps.rm1.0a51.p1.openshiftapps.com/salud          (sin clave)
https://nav1-chat-dayalert7-dev.apps.rm1.0a51.p1.openshiftapps.com/debug?clave=<clave>  (clave impresa por m.sh ligero)
```

## 10. Archivos relevantes (raw)

- Todo el modo ligero (instalador + `server.py` + `chat.html` embebidos):
  https://raw.githubusercontent.com/hunterhunters371-prog/navegador-remoto/main/modo.sh
- Contexto completo del proyecto:
  https://raw.githubusercontent.com/hunterhunters371-prog/navegador-remoto/main/CONTEXTO.md
- Stack gráfico (referencia de lo que sí funciona):
  https://raw.githubusercontent.com/hunterhunters371-prog/navegador-remoto/main/openshift-nav.sh
