# PROBLEMA DEL MODO LIGERO — ✅ RESUELTO (causa raíz encontrada)

> Documento de handoff. **Estado: causa raíz identificada y corregida en `modo.sh` v1.6** (21 ago 2026, ~23:25 UTC).
> Repo: `hunterhunters371-prog/navegador-remoto`, rama `main`.

## TL;DR de la solución

**Causa raíz:** en el protocolo **WebDriver/Marionette**, `WebDriver:ExecuteScript` ejecuta el string recibido como **cuerpo de una función**. Un script sin `return` devuelve `undefined`.

Todos los scripts del puente eran expresiones sin `return`:

| Script (v1.0–1.5) | Devolvía | Consecuencia observada |
|---|---|---|
| `location.href` | `undefined` | El puente creía estar siempre en la URL equivocada → renavegaba en bucle |
| `(() => { … })()` (composer) | `undefined` → falsy | El cuadro de texto **nunca** se detectaba; `asegurar_pagina()` agotaba sus 120 s siempre |
| `(() => { … })()` (leer `innerText`) | `undefined` | `leer()` devolvía texto vacío → **espejo eternamente en blanco** |
| `(() => { … })()` (enviar) | `undefined` ≠ `"enviado"` | Habría fallado con "no encontre el cuadro de texto" |

Y el síntoma `{"ocupado": true}` permanente era consecuencia, no causa: el hilo de precarga y las llamadas del espejo se pasaban el candado global (`m_lock`) reintentando lecturas que jamás podían devolver algo.

Esto encaja al 100 % con la evidencia: `firefox_headless: true` + `marionette: "conectado (sesion activa)"` (la conexión **sí** funcionaba, porque `NewSession` no toca el DOM) pero cero lectura útil de la página.

## Correcciones aplicadas en v1.6

1. **`return` en todos los scripts** inyectados (`return location.href`, `return eds.length`, `return JSON.stringify({…})`, `return "enviado"`, etc.). ← el arreglo real.
2. **Navegación con el comando nativo `WebDriver:Navigate`** en vez de asignar `location.href` dentro de un script (que no espera la carga y puede abortar el script por unload).
3. **Lector en segundo plano con caché**: un hilo toma el candado con `acquire(blocking=False)` cada 5 s, lee el texto y lo cachea; `/espejo` responde desde el caché y **nunca** bloquea. Fin de la contención del candado.
4. **Auto-reconexión**: cualquier error de comando cierra la sesión Marionette (`soltar()`) para no quedar desincronizado; el siguiente comando reconecta.
5. **Estados de página explícitos** (`navegando`/`cargando`/`lista`/`login`/`sin-composer`/`error`) visibles en la mini-web (pastilla en la cabecera) y en `/salud`.
6. **Diagnóstico de un golpe**: `GET /prueba?clave=…` devuelve `ejecuta_script` (debe ser `4`), `url_actual`, `titulo`, `cuadros_de_texto`, `parece_login`, `largo_texto`. Si `ejecuta_script` no es 4, el canal de scripts sigue roto; si `largo_texto` es 0, la página no ha renderizado.
7. **Distinción de fallos reales**: si no aparece el composer, el puente ahora comprueba si es **login** (mensaje con instrucciones) o **página sin chat de IA**.
8. **`/recargar?clave=…`** para reabrir el destino sin reiniciar nada.
9. **Modo sigilo opcional** (`SIGILO=1 sh modo.sh ligero`): añade `dom.webdriver.enabled=false` al perfil para ocultar `navigator.webdriver`. Es una palanca **solo** si se sospecha detección de automatización; se dejó fuera del camino por defecto para no mezclar variables.

## Verificación (lo que debe pasar ahora)

```
curl -fsSL https://raw.githubusercontent.com/hunterhunters371-prog/navegador-remoto/main/modo.sh -o m.sh && sh m.sh ligero
```

1. La pastilla de la mini-web pasa de «⏳ cargando Notion…» a «✓ pagina lista» en 1-2 min.
2. `GET /prueba?clave=…` → `ejecuta_script: 4`, `cuadros_de_texto` ≥ 1, `largo_texto` de varios miles.
3. El 🪞 espejo muestra el texto real de la página; una pregunta se responde en vivo.

## Si aún falla, en este orden

- `parece_login: true` → renovar sesión: `sh m.sh pantalla`, entrar con **email + código** (NUNCA Google), luego `sh m.sh ligero`.
- `cuadros_de_texto: 0` con `largo_texto` alto → el destino no es un chat de Notion AI; usar `https://www.notion.so/chat` o un hilo de IA existente.
- `largo_texto: 0` tras 3+ min → la SPA no renderiza en headless: subir `REQ_CPU` del pod (400-500m), o probar `SIGILO=1`, o replicar la prueba en el codespace (2-core sin capar) con el mismo perfil.
- Todo verde pero la respuesta llega cortada → ajustar heurística de fin de respuesta (`estable >= 2` y botón Stop/Detener) en `server.py`.

## Contexto técnico (para quien retome)

- **Entorno**: Red Hat Developer Sandbox (OpenShift gratis), namespace `dayalert7-dev`, pod `nav1` con imagen `consol/rocky-icewm-vnc`; sin root, sin sudo, sin pip → `server.py` es **stdlib pura**. Requests 250m CPU / 512Mi RAM (límites 2 CPU / 5Gi).
- **Volumen** `/headless/data`: `firefox/` (Firefox portable 154.x), `ff-notion/` (perfil con login), `chat/` (`server.py`, `chat.html`, `clave.txt`, `destino.txt`).
- **Arquitectura**: `modo.sh ligero` crea Service+Ruta `nav1-chat` (6902, edge/Redirect), instala el puente, mata el Firefox gráfico y arranca `firefox --headless --marionette` con el MISMO perfil, más `python3 server.py`.
- **Cliente Marionette artesanal**: framing `<longitud>:<json>` sobre TCP `127.0.0.1:2828`; comandos `WebDriver:NewSession`, `WebDriver:Navigate`, `WebDriver:ExecuteScript`. Un candado global serializa el acceso.
- **Envío de mensaje**: `execCommand("insertText")` en el último `div[contenteditable=true]` visible + `KeyboardEvent` Enter sintético. **Lectura**: `innerText` de `main`, respuesta considerada final cuando es idéntica en 2 sondeos y no hay botón Stop/Detener. Patrón async (job + `/estado`) por el timeout ~30 s de HAProxy.
- **Reglas del proyecto**: nunca entregar código largo para pegar (se corrompe) → subir al repo y dar `curl -fsSL <raw> -o x.sh && sh x.sh`; pantalla y ligero nunca a la vez (lock del perfil); usuario en español.

## Archivos

- Modo ligero completo (instalador + `server.py` + `chat.html`): https://raw.githubusercontent.com/hunterhunters371-prog/navegador-remoto/main/modo.sh
- Contexto general del proyecto: https://raw.githubusercontent.com/hunterhunters371-prog/navegador-remoto/main/CONTEXTO.md
