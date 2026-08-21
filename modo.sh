#!/bin/sh
# ============================================================
#  modo.sh — interruptor de nav1: PANTALLA (VNC) <-> LIGERO (texto)
#  v1.7 — TRES FUNCIONES NUEVAS (sobre el arreglo de raiz de v1.6)
#    · 🤖 Elegir IA: abre el selector de modelo de Notion, lista las
#      opciones reales y elige la que pidas.
#    · 📎 Archivos: subes desde el telefono -> se guardan en el pod ->
#      se adjuntan al chat (input[type=file] nativo, y si falla,
#      plan B pegando el archivo con DataTransfer).
#    · ⚙ Cuenta: abre Cuenta / Notificaciones / Conexiones / Espacio
#      de Notion en el navegador oculto, te las muestra en texto y
#      puedes pulsar cualquier boton de esas pantallas.
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

  log "Instalando el puente v1.7 en el volumen persistente..."
  oc exec -i "$POD" -- sh -c 'mkdir -p /headless/data/chat /headless/data/subidas'
  oc exec -i "$POD" -- sh -c 'cat > /headless/data/chat/server.py' <<'PYEOF'
#!/usr/bin/env python3
# server.py v1.7 - puente de texto <-> Notion AI (Firefox headless + Marionette)
# Solo stdlib. Lo instala modo.sh en /headless/data/chat/
import base64, json, mimetypes, os, re, socket, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

BASE = "/headless/data/chat"
SUBIDAS = "/headless/data/subidas"
CLAVE = open(os.path.join(BASE, "clave.txt")).read().strip()
DESTINO_FILE = os.path.join(BASE, "destino.txt")
MODELO_FILE = os.path.join(BASE, "modelo.txt")
DESTINO_DEFAULT = "https://www.notion.so/chat"
if "{" in DESTINO_DEFAULT:                       # red de seguridad
    DESTINO_DEFAULT = "https://www." + "notion.so/"
LIMITE = 20 * 1024 * 1024                        # 20 MB por archivo
PORT = int(os.environ.get("CHAT_PORT", "6902"))
try:
    os.makedirs(SUBIDAS)
except Exception:
    pass

jobs = {}
contador = [0]
cont_lock = threading.Lock()
m_lock = threading.Lock()          # Marionette no es hilo-seguro
vivo = {"texto": "", "job": None}  # respuesta parcial en curso
cache = {"texto": "", "cuando": 0, "escribiendo": False}
pagina = {"estado": "iniciando", "desde": time.time(), "detalle": ""}
_navegando = [False]

# ---------------- Marionette minimo (solo stdlib) ----------------
class Marionette:
    def __init__(self, port=2828):
        self.s = socket.create_connection(("127.0.0.1", port), timeout=30)
        self.s.settimeout(180)
        self.buf = b""
        self.hello = self._recv()
        self.mid = 0
    def close(self):
        try:
            self.s.close()
        except Exception:
            pass
    def _recv(self):
        while b":" not in self.buf:
            c = self.s.recv(65536)
            if not c:
                raise IOError("firefox cerro la conexion")
            self.buf += c
        head, _, rest = self.buf.partition(b":")
        n = int(head)
        while len(rest) < n:
            c = self.s.recv(65536)
            if not c:
                raise IOError("firefox cerro la conexion")
            rest += c
        self.buf = rest[n:]
        return json.loads(rest[:n].decode("utf-8"))
    def cmd(self, nombre, params=None):
        self.mid += 1
        payload = json.dumps([0, self.mid, nombre, params or {}]).encode("utf-8")
        self.s.sendall(str(len(payload)).encode("ascii") + b":" + payload)
        while True:
            msg = self._recv()
            if msg[0] == 1 and msg[1] == self.mid:
                if msg[2]:
                    raise RuntimeError(str(msg[2]))
                return msg[3]

def valor(r):
    if isinstance(r, dict) and "value" in r:
        return r["value"]
    return r

_m = None
def conectar():
    global _m
    if _m is not None:
        return _m
    ultimo = None
    for _ in range(10):
        c = None
        try:
            c = Marionette()
            try:
                c.cmd("WebDriver:NewSession", {})
            except Exception:
                c.cmd("WebDriver:NewSession", {"capabilities": {}})
            _m = c
            return _m
        except Exception as e:
            ultimo = e
            if c is not None:
                c.close()
            _m = None
            time.sleep(2)
    raise RuntimeError("no pude conectar con Firefox headless: %s" % ultimo)

def soltar():
    global _m
    if _m is not None:
        _m.close()
        _m = None

def cmd(nombre, params=None):
    try:
        return valor(conectar().cmd(nombre, params or {}))
    except Exception:
        soltar()   # sesion posiblemente desincronizada: reconectar luego
        raise

# OJO (arreglo de v1.6): el script va como CUERPO de funcion -> necesita return
def js(script):
    return cmd("WebDriver:ExecuteScript", {"script": script, "args": []})

def navegar(url):
    return cmd("WebDriver:Navigate", {"url": url})

def tomar(seg=20):
    return m_lock.acquire(True, seg)

def marionette_vivo():
    try:
        s = socket.create_connection(("127.0.0.1", 2828), timeout=5)
        s.settimeout(5)
        data = s.recv(4096)
        s.close()
        return b"applicationType" in data or b"arionette" in data
    except Exception:
        return False

def destino_actual():
    if os.path.exists(DESTINO_FILE):
        d = open(DESTINO_FILE).read().strip()
        if d and "notion" in d.lower() and "{" not in d:
            return d
    return DESTINO_DEFAULT

def modelo_actual():
    if os.path.exists(MODELO_FILE):
        return open(MODELO_FILE).read().strip()
    return ""

def nombre_seguro(n):
    n = os.path.basename((n or "archivo").strip())
    n = re.sub(r"[^A-Za-z0-9._\- ]", "_", n)[:120]
    return n or "archivo"

def lista_subidas():
    out = []
    try:
        for n in sorted(os.listdir(SUBIDAS)):
            p = os.path.join(SUBIDAS, n)
            if os.path.isfile(p):
                out.append({"nombre": n, "kb": int(os.path.getsize(p) / 1024) or 1})
    except Exception:
        pass
    return out

# ---------------- scripts inyectados (TODOS con return) ----------------
SEL_CTRL = ('button, a[href], [role="button"], [role="menuitem"], '
            '[role="menuitemradio"], [role="tab"], [role="option"], '
            '[role="switch"], [role="checkbox"], select')
VIS = 'function vis(e){ return e.offsetParent !== null; }\n'

JS_URL = "return location.href"
JS_TITULO = "return document.title"
JS_TEXTO = "return ((document.querySelector('main')||document.body).innerText||'').slice(0,6000)"
JS_COMPOSER = """
const eds = [...document.querySelectorAll('div[contenteditable="true"]')]
  .filter(e => e.offsetParent !== null);
return eds.length;
"""
JS_LOGIN = """
const t = (document.body && document.body.innerText) || "";
return /log in|sign in|iniciar sesi|continuar con/i.test(t);
"""
JS_LEER = """
const main = document.querySelector("main") || document.body;
const stop = !!document.querySelector(
  '[aria-label*="Stop"], [aria-label*="stop"], [aria-label*="Detener"], [aria-label*="detener"]');
return JSON.stringify({texto: (main.innerText || ""), escribiendo: stop});
"""
JS_ENVIAR = """
const eds = [...document.querySelectorAll('div[contenteditable="true"]')]
  .filter(e => e.offsetParent !== null);
if (!eds.length) return "sin-composer";
const ed = eds[eds.length - 1];
ed.focus();
document.execCommand("selectAll", false, null);
document.execCommand("insertText", false, %s);
ed.dispatchEvent(new KeyboardEvent("keydown",
  {key:"Enter", code:"Enter", keyCode:13, which:13, bubbles:true}));
return "enviado";
"""

# --- zona del composer: la barra de herramientas donde viven el selector
#     de modelo y el boton de adjuntar ---
JS_ZONA = VIS + """
function zona(){
  const eds = [...document.querySelectorAll('div[contenteditable="true"]')].filter(vis);
  if (!eds.length) return document.body;
  let p = eds[eds.length - 1];
  for (let i = 0; i < 6 && p.parentElement; i++) p = p.parentElement;
  return p;
}
"""
JS_ABRIR_MODELO = JS_ZONA + """
const re = /gpt|claude|sonnet|opus|haiku|gemini|llama|mistral|deepseek|grok|auto|r[aá]pid|fast|advanc|avanzad|thinking|razona|model/i;
function cand(raiz){
  return [...raiz.querySelectorAll('button, div[role="button"]')].filter(vis)
    .filter(b => re.test((b.innerText || "") + " " + (b.getAttribute("aria-label") || "")));
}
let bs = cand(zona());
if (!bs.length) bs = cand(document);
if (!bs.length) return JSON.stringify({ok:false});
const b = bs[bs.length - 1];
const etiqueta = ((b.innerText || b.getAttribute("aria-label") || "").trim().split("\\n")[0]).slice(0,60);
b.click();
return JSON.stringify({ok:true, etiqueta: etiqueta});
"""
JS_MENU = VIS + """
const it = [...document.querySelectorAll('[role="menuitem"], [role="menuitemradio"], [role="option"]')]
  .filter(vis)
  .map(e => ((e.innerText || "").trim().split("\\n")[0]).slice(0,60))
  .filter(t => t.length > 0);
return JSON.stringify([...new Set(it)]);
"""
JS_CLIC_MENU = VIS + """
const q = %s.toLowerCase();
const it = [...document.querySelectorAll('[role="menuitem"], [role="menuitemradio"], [role="option"]')].filter(vis);
const t = it.find(e => (e.innerText || "").toLowerCase().indexOf(q) >= 0);
if (!t) return "no-esta";
t.click();
return "elegido";
"""
JS_ESC = """
document.dispatchEvent(new KeyboardEvent("keydown",
  {key:"Escape", code:"Escape", keyCode:27, which:27, bubbles:true}));
return "esc";
"""

# --- archivos ---
JS_INPUTS = "return document.querySelectorAll('input[type=file]').length"
JS_CLIC_ADJUNTAR = JS_ZONA + """
const re = /adjunt|attach|upload|subir|archivo|file|clip|imagen|image|a[ñn]adir|add/i;
const bs = [...zona().querySelectorAll('button, div[role="button"], [aria-label]')].filter(vis);
const b = bs.find(x => re.test((x.getAttribute("aria-label") || "") + " " + (x.title || "")));
if (!b) return "sin-boton";
b.click();
return "clic";
"""
JS_DESTAPAR = """
const ins = [...document.querySelectorAll('input[type=file]')];
ins.forEach(i => {
  i.removeAttribute("hidden");
  i.style.display = "block"; i.style.visibility = "visible"; i.style.opacity = "1";
  i.style.position = "fixed"; i.style.left = "0px"; i.style.top = "0px";
  i.style.width = "80px"; i.style.height = "30px"; i.style.zIndex = "999999";
});
return ins.length;
"""
JS_PEGAR = VIS + """
const bin = atob(%s);
const arr = new Uint8Array(bin.length);
for (let i = 0; i < bin.length; i++) arr[i] = bin.charCodeAt(i);
const f = new File([arr], %s, {type: %s});
const eds = [...document.querySelectorAll('div[contenteditable="true"]')].filter(vis);
if (!eds.length) return "sin-composer";
const ed = eds[eds.length - 1];
ed.focus();
const dt = new DataTransfer();
dt.items.add(f);
ed.dispatchEvent(new ClipboardEvent("paste", {clipboardData: dt, bubbles: true, cancelable: true}));
return "pegado";
"""

# --- navegar la interfaz de Notion por texto (cuenta, ajustes, etc.) ---
JS_CONTROLES = VIS + """
const els = [...document.querySelectorAll('%s')].filter(vis);
const out = [];
els.forEach((e, i) => {
  const t = ((e.innerText || e.getAttribute("aria-label") || e.title || "").trim().split("\\n")[0]).slice(0,70);
  if (t) out.push({i: i, t: t});
});
return JSON.stringify(out.slice(0, 90));
""" % SEL_CTRL
JS_CLIC_I = VIS + """
const els = [...document.querySelectorAll('%s')].filter(vis);
const e = els[%%d];
if (!e) return "no-esta";
try { e.scrollIntoView({block:"center"}); } catch (x) {}
e.click();
return "clic: " + ((e.innerText || e.getAttribute("aria-label") || "").trim().split("\\n")[0]).slice(0,60);
""" % SEL_CTRL
JS_CLIC_T = VIS + """
const q = %%s.toLowerCase();
const els = [...document.querySelectorAll('%s')].filter(vis);
const e = els.find(x => ((x.innerText || x.getAttribute("aria-label") || "").toLowerCase().indexOf(q) >= 0));
if (!e) return "no-esta";
try { e.scrollIntoView({block:"center"}); } catch (x) {}
e.click();
return "clic: " + ((e.innerText || "").trim().split("\\n")[0]).slice(0,60);
""" % SEL_CTRL
JS_CORREO = """
const t = (document.body && document.body.innerText) || "";
const m = t.match(/[A-Za-z0-9._%%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}/);
return m ? m[0] : "";
"""

# ---------------- logica ----------------
def leer():
    try:
        d = json.loads(js(JS_LEER) or "{}")
        return {"texto": d.get("texto", "") or "", "escribiendo": bool(d.get("escribiendo"))}
    except Exception as e:
        pagina["detalle"] = "error leyendo: %s" % e
        return {"texto": "", "escribiendo": False}

def esperar_composer(segundos=180):
    t0 = time.time()
    while time.time() - t0 < segundos:
        try:
            if js(JS_COMPOSER):
                pagina["estado"] = "lista"
                return True
        except Exception as e:
            pagina["detalle"] = str(e)
        time.sleep(3)
    return False

def ir_al_destino(forzar=False):
    if _navegando[0]:
        return
    _navegando[0] = True
    def run():
        try:
            with m_lock:
                pagina["estado"] = "navegando"
                pagina["desde"] = time.time()
                destino = destino_actual()
                actual = ""
                try:
                    actual = js(JS_URL) or ""
                except Exception:
                    actual = ""
                if forzar or destino.split("?")[0] not in actual:
                    navegar(destino)
                pagina["estado"] = "cargando"
                if not esperar_composer(180):
                    try:
                        pagina["estado"] = "login" if js(JS_LOGIN) else "sin-composer"
                    except Exception:
                        pagina["estado"] = "sin-composer"
        except Exception as e:
            pagina["estado"] = "error"
            pagina["detalle"] = str(e)
        finally:
            _navegando[0] = False
    threading.Thread(target=run, daemon=True).start()

def ir_a_url(url):
    if _navegando[0]:
        return
    _navegando[0] = True
    def run():
        try:
            with m_lock:
                pagina["estado"] = "navegando"
                pagina["detalle"] = url
                navegar(url)
                time.sleep(2)
                pagina["estado"] = "otra-pagina"
                info = leer()
                cache["texto"] = info["texto"][-6000:]
                cache["cuando"] = time.time()
        except Exception as e:
            pagina["estado"] = "error"
            pagina["detalle"] = str(e)
        finally:
            _navegando[0] = False
    threading.Thread(target=run, daemon=True).start()

def asegurar_pagina():
    destino = destino_actual()
    actual = ""
    try:
        actual = js(JS_URL) or ""
    except Exception:
        actual = ""
    if destino.split("?")[0] not in actual:
        pagina["estado"] = "cargando"
        pagina["desde"] = time.time()
        navegar(destino)
    if js(JS_COMPOSER):
        pagina["estado"] = "lista"
        return
    if esperar_composer(180):
        return
    if js(JS_LOGIN):
        pagina["estado"] = "login"
        raise RuntimeError("Notion pide iniciar sesion en el navegador oculto: corre 'sh m.sh pantalla', entra con email+codigo y vuelve con 'sh m.sh ligero'")
    pagina["estado"] = "sin-composer"
    raise RuntimeError("no aparecio el cuadro de texto: el destino puede no ser un chat de Notion AI, o la pagina cargo demasiado lento")

def listo_para_actuar():
    if not js(JS_COMPOSER):
        raise RuntimeError("la pagina aun no esta lista (espera a ver 'pagina lista' arriba)")

def modelos():
    listo_para_actuar()
    d = json.loads(js(JS_ABRIR_MODELO) or "{}")
    if not d.get("ok"):
        return {"actual": modelo_actual(),
                "modelos": [],
                "nota": "no encontre el selector de modelo en esta pagina"}
    time.sleep(1.5)
    items = json.loads(js(JS_MENU) or "[]")
    js(JS_ESC)
    return {"actual": d.get("etiqueta") or modelo_actual(), "modelos": items}

def elegir_modelo(nombre):
    listo_para_actuar()
    d = json.loads(js(JS_ABRIR_MODELO) or "{}")
    if not d.get("ok"):
        raise RuntimeError("no encontre el selector de modelo en esta pagina")
    time.sleep(1.5)
    r = js(JS_CLIC_MENU % json.dumps(nombre))
    if r != "elegido":
        js(JS_ESC)
        raise RuntimeError("no encontre la opcion '%s' en el menu" % nombre)
    time.sleep(0.5)
    open(MODELO_FILE, "w").write(nombre + "\n")
    return nombre

def adjuntar(nombre):
    ruta = os.path.join(SUBIDAS, nombre)
    if not os.path.isfile(ruta):
        raise RuntimeError("ese archivo no esta subido")
    listo_para_actuar()
    via = None
    try:
        n = js(JS_INPUTS)
        if not n:
            js(JS_CLIC_ADJUNTAR)
            time.sleep(2)
            n = js(JS_INPUTS)
        if n:
            js(JS_DESTAPAR)
            el = cmd("WebDriver:FindElement", {"using": "css selector", "value": "input[type=file]"})
            eid = list(el.values())[0] if isinstance(el, dict) else el
            cmd("WebDriver:ElementSendKeys", {"id": eid, "text": ruta})
            via = "selector de archivos"
    except Exception as e:
        pagina["detalle"] = "input file: %s" % e
    if via is None:
        tam = os.path.getsize(ruta)
        if tam > 3 * 1024 * 1024:
            raise RuntimeError("no pude usar el selector de archivos de Notion y el archivo pasa de 3 MB para el plan B")
        datos = base64.b64encode(open(ruta, "rb").read()).decode("ascii")
        tipo = mimetypes.guess_type(nombre)[0] or "application/octet-stream"
        r = js(JS_PEGAR % (json.dumps(datos), json.dumps(nombre), json.dumps(tipo)))
        if r != "pegado":
            raise RuntimeError("no pude adjuntar el archivo (%s)" % r)
        via = "pegado en el cuadro de texto"
    time.sleep(1)
    return via

def extraer(actual, base, prompt):
    nuevo = actual[len(base):] if (base and actual.startswith(base)) else actual
    i = nuevo.rfind(prompt[:60])
    if i >= 0:
        return nuevo[i + len(prompt):].strip()
    return nuevo.strip()

def trabajar(job_id, texto):
    with m_lock:
        vivo["job"] = job_id
        vivo["texto"] = ""
        try:
            asegurar_pagina()
            base = leer()["texto"]
            r = js(JS_ENVIAR % json.dumps(texto))
            if r != "enviado":
                raise RuntimeError("no encontre el cuadro de texto de Notion AI (%s)" % r)
            anterior = ""
            estable = 0
            t0 = time.time()
            while time.time() - t0 < 300:
                time.sleep(2)
                info = leer()
                cand = extraer(info["texto"], base, texto)
                vivo["texto"] = cand
                cache["texto"] = info["texto"][-6000:]
                cache["cuando"] = time.time()
                if info["escribiendo"]:
                    anterior = cand
                    estable = 0
                    continue
                if cand and cand == anterior:
                    estable += 1
                    if estable >= 2:
                        jobs[job_id] = {"listo": True, "texto": cand, "error": None}
                        return
                else:
                    anterior = cand
                    estable = 0
            jobs[job_id] = {"listo": True, "texto": anterior, "error": "se acabo el tiempo; esto es lo ultimo visible"}
        except Exception as e:
            jobs[job_id] = {"listo": True, "texto": "", "error": str(e)}

def lector():
    # lee la pagina en 2do plano y cachea: el espejo nunca bloquea
    while True:
        time.sleep(5)
        if not m_lock.acquire(blocking=False):
            continue
        try:
            info = leer()
            if info["texto"].strip():
                cache["texto"] = info["texto"][-6000:]
                cache["cuando"] = time.time()
                cache["escribiendo"] = info["escribiendo"]
                if pagina["estado"] in ("iniciando", "cargando", "por-verificar"):
                    pagina["estado"] = "lista"
        except Exception:
            pass
        finally:
            m_lock.release()

HTML = os.path.join(BASE, "chat.html")

class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass
    def _json(self, obj, code=200):
        body = json.dumps(obj).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def _ok(self):
        if self.headers.get("X-Clave") == CLAVE:
            return True
        q = parse_qs(urlparse(self.path).query)
        return q.get("clave", [None])[0] == CLAVE
    def _accion(self, fn, seg=20):
        if not tomar(seg):
            self._json({"ocupado": True, "pagina": pagina["estado"],
                        "parcial": vivo.get("texto", "")})
            return
        try:
            self._json(fn())
        except Exception as e:
            self._json({"error": str(e), "pagina": pagina["estado"]})
        finally:
            m_lock.release()
    def do_GET(self):
        path = urlparse(self.path).path
        q = parse_qs(urlparse(self.path).query)
        if path == "/salud":
            ff = (os.system("pgrep -f marionette >/dev/null 2>&1") == 0)
            if _m is not None:
                m = "conectado (sesion activa)"
            elif m_lock.locked():
                m = "ocupado (trabajando)"
            else:
                m = "escuchando" if marionette_vivo() else "NO responde"
            self._json({"ok": True, "version": "1.7", "firefox_headless": ff,
                        "marionette": m, "destino": destino_actual(),
                        "modelo": modelo_actual(), "archivos": len(lista_subidas()),
                        "pagina": pagina["estado"], "detalle": pagina["detalle"],
                        "texto_en_cache": len(cache["texto"]),
                        "cache_hace_seg": int(time.time() - cache["cuando"]) if cache["cuando"] else None})
            return
        if path == "/" or path == "/chat.html":
            data = open(HTML, "rb").read()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        if not self._ok():
            self._json({"error": "clave mala"}, 403)
            return
        if path == "/estado":
            jid = int(q.get("id", ["0"])[0])
            job = jobs.get(jid, {"listo": False})
            if not job.get("listo") and vivo.get("job") == jid and vivo.get("texto"):
                job = dict(job)
                job["parcial"] = vivo["texto"]
            self._json(job)
            return
        if path == "/espejo":
            if vivo.get("texto") and m_lock.locked():
                self._json({"texto": vivo["texto"], "en_curso": True})
                return
            self._json({"texto": cache["texto"], "pagina": pagina["estado"],
                        "hace_seg": int(time.time() - cache["cuando"]) if cache["cuando"] else None})
            return
        if path == "/modelos":
            self._accion(modelos, 25)
            return
        if path == "/archivos":
            self._json({"archivos": lista_subidas(), "limite_mb": int(LIMITE / 1048576)})
            return
        if path == "/controles":
            self._accion(lambda: {"controles": json.loads(js(JS_CONTROLES) or "[]"),
                                  "titulo": js(JS_TITULO), "url": js(JS_URL)}, 25)
            return
        if path == "/pantalla-texto":
            if m_lock.acquire(blocking=False):
                try:
                    self._json({"texto": js(JS_TEXTO), "titulo": js(JS_TITULO),
                                "url": js(JS_URL), "pagina": pagina["estado"]})
                    return
                except Exception as e:
                    self._json({"error": str(e)})
                    return
                finally:
                    m_lock.release()
            self._json({"texto": cache["texto"], "pagina": pagina["estado"], "del_cache": True})
            return
        if path == "/cuenta":
            self._accion(lambda: {"correo": js(JS_CORREO), "titulo": js(JS_TITULO),
                                  "url": js(JS_URL)}, 20)
            return
        if path == "/prueba":
            if not m_lock.acquire(blocking=False):
                self._json({"ocupado": True, "pagina": pagina["estado"], "parcial": vivo.get("texto", "")})
                return
            try:
                r = {"ejecuta_script": js("return 2+2"),
                     "url_actual": js(JS_URL),
                     "titulo": js(JS_TITULO),
                     "cuadros_de_texto": js(JS_COMPOSER),
                     "parece_login": js(JS_LOGIN),
                     "inputs_de_archivo": js(JS_INPUTS),
                     "largo_texto": js("return ((document.querySelector('main')||document.body).innerText||'').length")}
            except Exception as e:
                r = {"error": str(e)}
            finally:
                m_lock.release()
            r["pagina"] = pagina["estado"]
            r["destino_configurado"] = destino_actual()
            self._json(r)
            return
        if path == "/destino":
            self._json({"destino": destino_actual(), "modelo": modelo_actual()})
            return
        if path == "/debug":
            if not m_lock.acquire(blocking=False):
                self._json({"ocupado": True, "parcial": vivo.get("texto", ""),
                            "pagina": pagina["estado"], "detalle": pagina["detalle"],
                            "destino_configurado": destino_actual()})
                return
            try:
                info = {"url_actual": js(JS_URL), "titulo": js(JS_TITULO),
                        "composer_encontrado": bool(js(JS_COMPOSER)),
                        "parece_pantalla_de_login": bool(js(JS_LOGIN))}
            except Exception as e:
                info = {"error": str(e)}
            finally:
                m_lock.release()
            info["pagina"] = pagina["estado"]
            info["destino_configurado"] = destino_actual()
            self._json(info)
            return
        if path == "/recargar":
            ir_al_destino(forzar=True)
            self._json({"navegando": True, "destino": destino_actual()})
            return
        self._json({"error": "ruta desconocida"}, 404)
    def do_POST(self):
        if not self._ok():
            self._json({"error": "clave mala"}, 403)
            return
        path = urlparse(self.path).path
        q = parse_qs(urlparse(self.path).query)
        # /subir recibe bytes crudos (el nombre va en la URL): sin multipart
        if path == "/subir":
            nombre = nombre_seguro(q.get("nombre", ["archivo"])[0])
            n = int(self.headers.get("Content-Length", "0") or 0)
            if n <= 0:
                self._json({"error": "archivo vacio"}, 400)
                return
            if n > LIMITE:
                self._json({"error": "el archivo pasa de %d MB" % int(LIMITE / 1048576)}, 400)
                return
            ruta = os.path.join(SUBIDAS, nombre)
            leidos = 0
            with open(ruta, "wb") as f:
                while leidos < n:
                    c = self.rfile.read(min(65536, n - leidos))
                    if not c:
                        break
                    f.write(c)
                    leidos += len(c)
            self._json({"ok": True, "nombre": nombre, "kb": int(leidos / 1024) or 1})
            return
        n = int(self.headers.get("Content-Length", "0") or 0)
        cuerpo = self.rfile.read(n).decode("utf-8", "replace").strip() if n else ""
        if path == "/preguntar":
            if not cuerpo:
                self._json({"error": "mensaje vacio"}, 400)
                return
            with cont_lock:
                contador[0] += 1
                jid = contador[0]
            jobs[jid] = {"listo": False}
            threading.Thread(target=trabajar, args=(jid, cuerpo), daemon=True).start()
            self._json({"id": jid})
            return
        if path == "/destino":
            if cuerpo and "notion" not in cuerpo.lower():
                self._json({"error": "el destino debe ser una pagina de Notion (notion.so/...)", "destino": destino_actual()}, 400)
                return
            open(DESTINO_FILE, "w").write(cuerpo + "\n")
            cache["texto"] = ""
            cache["cuando"] = 0
            ir_al_destino(forzar=True)
            self._json({"destino": cuerpo, "navegando": True})
            return
        if path == "/modelo":
            nombre = cuerpo or q.get("nombre", [""])[0]
            if not nombre:
                self._json({"error": "dime que modelo"}, 400)
                return
            self._accion(lambda: {"modelo": elegir_modelo(nombre)}, 25)
            return
        if path == "/adjuntar":
            nombre = nombre_seguro(cuerpo or q.get("nombre", [""])[0])
            self._accion(lambda: {"adjuntado": nombre, "via": adjuntar(nombre)}, 25)
            return
        if path == "/borrar-archivo":
            nombre = nombre_seguro(cuerpo or q.get("nombre", [""])[0])
            try:
                os.remove(os.path.join(SUBIDAS, nombre))
                self._json({"borrado": nombre})
            except Exception as e:
                self._json({"error": str(e)}, 400)
            return
        if path == "/ir":
            url = cuerpo or q.get("url", [""])[0]
            if "notion" not in url.lower():
                self._json({"error": "solo puedo abrir paginas de Notion"}, 400)
                return
            ir_a_url(url)
            self._json({"navegando": True, "url": url})
            return
        if path == "/clic":
            if "i" in q:
                idx = int(q["i"][0])
                fn = lambda: {"resultado": js(JS_CLIC_I % idx), "texto": (time.sleep(1.5), js(JS_TEXTO))[1]}
            else:
                txt = cuerpo or q.get("texto", [""])[0]
                fn = lambda: {"resultado": js(JS_CLIC_T % json.dumps(txt)), "texto": (time.sleep(1.5), js(JS_TEXTO))[1]}
            self._accion(fn, 25)
            return
        if path == "/volver":
            ir_al_destino(forzar=True)
            self._json({"navegando": True, "destino": destino_actual()})
            return
        self._json({"error": "ruta desconocida"}, 404)

if __name__ == "__main__":
    threading.Thread(target=lector, daemon=True).start()
    ir_al_destino()
    ThreadingHTTPServer(("0.0.0.0", PORT), H).serve_forever()
PYEOF
  oc exec -i "$POD" -- sh -c 'cat > /headless/data/chat/chat.html' <<'HTMLEOF'
<!doctype html>
<html lang="es">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Notion AI — modo ligero</title>
<style>
  :root { color-scheme: dark; }
  body { margin:0; font:15px/1.5 system-ui, sans-serif; background:#0f1115; color:#e8e8ea; display:flex; flex-direction:column; height:100vh; }
  header { padding:10px 14px; background:#171a21; display:flex; gap:8px; align-items:center; flex-wrap:wrap; }
  header b { margin-right:auto; }
  input, button, textarea, select { font:inherit; color:inherit; background:#22262f; border:1px solid #333947; border-radius:8px; padding:8px 10px; }
  button { background:#2f6fed; border-color:#2f6fed; cursor:pointer; }
  button.gris { background:#22262f; border-color:#333947; }
  button:disabled { opacity:.5; }
  #msgs { flex:1; overflow-y:auto; padding:14px; display:flex; flex-direction:column; gap:10px; }
  .m { max-width:85%; padding:10px 12px; border-radius:12px; white-space:pre-wrap; word-wrap:break-word; }
  .yo { align-self:flex-end; background:#2f6fed; }
  .ia { align-self:flex-start; background:#1d212b; border:1px solid #2a2f3a; }
  .parcial { opacity:.75; }
  .estado { align-self:center; color:#8b93a3; font-size:13px; }
  footer { padding:10px; background:#171a21; display:flex; gap:8px; }
  textarea { flex:1; resize:none; height:52px; }
  #cfg { display:none; width:100%; }
  #cfg input { flex:1; }
  #pill { font-size:12px; color:#8b93a3; }
  #espejo { display:none; flex:1; overflow-y:auto; margin:0; padding:14px; white-space:pre-wrap; word-wrap:break-word; font:13px/1.5 ui-monospace, Menlo, monospace; color:#c9d1d9; }
  #panel { display:none; flex:1; overflow-y:auto; padding:14px; }
  #panel h3 { margin:0 0 4px; font-size:16px; }
  .sub { color:#8b93a3; font-size:13px; margin:4px 0 10px; }
  .fila { display:flex; gap:8px; align-items:center; margin:6px 0; flex-wrap:wrap; }
  .opt { display:block; width:100%; text-align:left; margin:6px 0; background:#1d212b; border-color:#2a2f3a; }
  .opt.sel { background:#2f6fed; border-color:#2f6fed; }
  .chip { background:#1d212b; border:1px solid #2a2f3a; border-radius:8px; padding:6px 8px; font-size:13px; }
  pre.mini { background:#0b0d11; border:1px solid #222733; border-radius:8px; padding:10px; white-space:pre-wrap; word-wrap:break-word; font:12px/1.45 ui-monospace, monospace; max-height:38vh; overflow:auto; color:#c9d1d9; }
</style>
</head>
<body>
<header>
  <b>⚡ Notion AI</b>
  <span id="pill"></span>
  <button id="bmodelo" class="gris" type="button" title="Elegir IA">🤖</button>
  <button id="barch" class="gris" type="button" title="Archivos">📎</button>
  <button id="bespejo" class="gris" type="button" title="Espejo de la pagina">🪞</button>
  <button id="bcfg" class="gris" type="button" title="Ajustes y cuenta">⚙</button>
</header>
<div id="panel"></div>
<div id="msgs"></div>
<pre id="espejo"></pre>
<footer>
  <textarea id="t" placeholder="Escribe tu mensaje... (Enter envia, Shift+Enter salto)"></textarea>
  <button id="b">Enviar</button>
</footer>
<script>
var $ = function(id){ return document.getElementById(id); };
var msgs = $("msgs"), panel = $("panel");
var clave = localStorage.getItem("nl_clave") || "";
var burbuja = null, espejoOn = false;

function esc(s){ return String(s == null ? "" : s).replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;").replace(/"/g,"&quot;"); }
function add(cls, txt) {
  var d = document.createElement("div");
  d.className = "m " + cls; d.textContent = txt;
  msgs.appendChild(d); msgs.scrollTop = msgs.scrollHeight;
  return d;
}
function estado(txt) {
  var e = document.querySelector(".estado");
  if (!txt) { if (e) e.remove(); return; }
  if (!e) e = add("estado", "");
  e.textContent = txt;
}
function api(path, opts) {
  opts = opts || {};
  opts.headers = Object.assign({"X-Clave": clave}, opts.headers || {});
  return fetch(path, opts).then(function(r){ return r.json(); });
}
function verChat(){ panel.style.display="none"; $("espejo").style.display="none"; espejoOn=false; msgs.style.display="flex"; }
function verPanel(html){ panel.innerHTML=html; panel.style.display="block"; msgs.style.display="none"; $("espejo").style.display="none"; espejoOn=false; }

/* ---------- estado de la pagina ---------- */
var ETQ = {lista:"✓ pagina lista", cargando:"⏳ cargando Notion...", navegando:"⏳ abriendo...",
  login:"⚠ pide iniciar sesion", "sin-composer":"⚠ sin cuadro de chat", error:"⚠ error",
  iniciando:"⏳ iniciando...", "otra-pagina":"🔧 en configuracion"};
function tickSalud() {
  fetch("/salud").then(function(r){ return r.json(); }).then(function(d) {
    $("pill").textContent = (ETQ[d.pagina] || d.pagina || "") + (d.modelo ? " · " + d.modelo : "");
  }).catch(function(){});
  setTimeout(tickSalud, 6000);
}
tickSalud();

/* ---------- 🤖 elegir IA ---------- */
$("bmodelo").onclick = function() {
  verPanel('<h3>🤖 Elegir IA</h3><p class="sub">Abro el selector de modelo de Notion y te muestro las opciones reales.</p><div id="lista">leyendo el selector...</div><div class="fila"><button class="gris" data-a="chat">Volver al chat</button></div>');
  api("/modelos").then(function(d) {
    var l = $("lista"), h = "";
    if (d.error || d.ocupado) { l.textContent = "⚠ " + (d.error || "ocupado ahora mismo, prueba en unos segundos"); return; }
    if (d.actual) h += '<p class="sub">Ahora: <b>' + esc(d.actual) + '</b></p>';
    if (!d.modelos || !d.modelos.length) {
      h += '<p class="sub">' + esc(d.nota || "No encontre opciones de modelo en esta pagina.") + '</p>';
    } else {
      for (var i = 0; i < d.modelos.length; i++)
        h += '<button class="opt" data-m="' + esc(d.modelos[i]) + '">' + esc(d.modelos[i]) + '</button>';
    }
    l.innerHTML = h;
  });
};

/* ---------- 📎 archivos ---------- */
function listaArchivos() {
  api("/archivos").then(function(d) {
    var h = "", a = d.archivos || [];
    if (!a.length) h = '<p class="sub">Todavia no has subido nada.</p>';
    for (var i = 0; i < a.length; i++) {
      h += '<div class="fila"><span class="chip">' + esc(a[i].nombre) + ' · ' + a[i].kb + ' KB</span>' +
           '<button data-adj="' + esc(a[i].nombre) + '">Adjuntar al chat</button>' +
           '<button class="gris" data-del="' + esc(a[i].nombre) + '">🗑</button></div>';
    }
    $("lista").innerHTML = h;
  });
}
$("barch").onclick = function() {
  verPanel('<h3>📎 Archivos</h3><p class="sub">1) Subes el archivo (queda guardado en el servidor). 2) Lo adjuntas al chat. 3) Escribes tu mensaje y envias. Maximo 20 MB.</p>' +
    '<div class="fila"><input type="file" id="f" multiple></div><div id="lista">cargando...</div>' +
    '<div class="fila"><button class="gris" data-a="chat">Volver al chat</button></div>');
  $("f").onchange = function() {
    var fs = $("f").files, i = 0;
    (function next() {
      if (i >= fs.length) { $("f").value = ""; listaArchivos(); return; }
      var f = fs[i++];
      $("lista").textContent = "subiendo " + f.name + "...";
      fetch("/subir?nombre=" + encodeURIComponent(f.name), {method:"POST", headers:{"X-Clave": clave}, body: f})
        .then(function(r){ return r.json(); }).then(function(){ next(); }).catch(function(){ next(); });
    })();
  };
  listaArchivos();
};

/* ---------- ⚙ ajustes y cuenta ---------- */
var PANT = [["Cuenta","my-account"],["Notificaciones","my-notifications"],["Conexiones","my-connections"],["Espacio de trabajo","my-settings"]];
$("bcfg").onclick = function() {
  var h = '<h3>⚙ Ajustes</h3>' +
    '<div class="fila"><input id="clave" type="password" placeholder="clave" value="' + esc(clave) + '"></div>' +
    '<div class="fila"><input id="destino" placeholder="URL de tu chat de Notion AI" style="flex:1"></div>' +
    '<div class="fila"><button data-a="guardar">Guardar</button><button class="gris" data-a="recargar">Recargar pagina</button></div>' +
    '<h3 style="margin-top:16px">👤 Cuenta y configuracion de Notion</h3>' +
    '<p class="sub">Abro esas pantallas en el navegador oculto y te las muestro en texto. Puedes pulsar sus botones desde aqui. Al enviar un mensaje se vuelve solo al chat.</p><div class="fila">';
  for (var i = 0; i < PANT.length; i++) h += '<button class="gris" data-ir="' + PANT[i][1] + '">' + PANT[i][0] + '</button>';
  h += '</div><div class="fila"><button class="gris" data-a="ctrl">Ver botones de la pantalla</button><button class="gris" data-a="volver">Volver al chat de IA</button></div>' +
       '<div id="vista"></div><div class="fila"><button class="gris" data-a="chat">Cerrar ajustes</button></div>';
  verPanel(h);
  api("/destino").then(function(d){ $("destino").value = d.destino || ""; }).catch(function(){});
};
function verPantalla() {
  api("/pantalla-texto").then(function(d) {
    $("vista").innerHTML = '<p class="sub">' + esc(d.titulo || "") + '</p><pre class="mini">' + esc(d.texto || "(vacio)") + '</pre>';
  });
}
function verControles() {
  $("vista").innerHTML = '<p class="sub">leyendo botones...</p>';
  api("/controles").then(function(d) {
    if (d.error || d.ocupado) { $("vista").innerHTML = '<p class="sub">⚠ ' + esc(d.error || "ocupado") + '</p>'; return; }
    var h = '<p class="sub">' + esc(d.titulo || "") + ' — pulsa cualquiera:</p>', c = d.controles || [];
    for (var i = 0; i < c.length; i++) h += '<button class="opt" data-i="' + c[i].i + '">' + esc(c[i].t) + '</button>';
    if (!c.length) h += '<p class="sub">no encontre botones visibles</p>';
    $("vista").innerHTML = h;
  });
}

/* ---------- clicks dentro de los paneles ---------- */
panel.addEventListener("click", function(ev) {
  var t = ev.target;
  if (t.tagName !== "BUTTON") return;
  var m = t.getAttribute("data-m"), adj = t.getAttribute("data-del") , del = t.getAttribute("data-del");
  if (m) {
    t.textContent = "cambiando...";
    api("/modelo", {method:"POST", body:m}).then(function(r) {
      verChat();
      add("estado", r.error ? ("⚠ " + r.error) : ("IA cambiada a " + r.modelo + " ✓"));
    });
    return;
  }
  if (t.getAttribute("data-adj")) {
    var nombre = t.getAttribute("data-adj");
    t.textContent = "adjuntando...";
    api("/adjuntar", {method:"POST", body:nombre}).then(function(r) {
      verChat();
      add("estado", r.error ? ("⚠ " + r.error) : ("📎 " + nombre + " adjuntado (" + r.via + ") — ahora escribe tu mensaje"));
    });
    return;
  }
  if (del) { api("/borrar-archivo", {method:"POST", body:del}).then(listaArchivos); return; }
  var ir = t.getAttribute("data-ir");
  if (ir) {
    $("vista").innerHTML = '<p class="sub">abriendo... (unos segundos)</p>';
    api("/ir", {method:"POST", body:"https://www.notion.so/" + ir}).then(function() {
      setTimeout(verPantalla, 4000);
    });
    return;
  }
  var idx = t.getAttribute("data-i");
  if (idx !== null) {
    t.textContent = "pulsando...";
    api("/clic?i=" + idx, {method:"POST"}).then(function(r) {
      if (r.error || r.ocupado) { $("vista").innerHTML = '<p class="sub">⚠ ' + esc(r.error || "ocupado") + '</p>'; return; }
      $("vista").innerHTML = '<p class="sub">' + esc(r.resultado) + '</p><pre class="mini">' + esc(r.texto || "") + '</pre>';
      setTimeout(verControles, 1200);
    });
    return;
  }
  var a = t.getAttribute("data-a");
  if (a === "chat") { verChat(); }
  else if (a === "ctrl") { verControles(); }
  else if (a === "volver") { api("/volver", {method:"POST"}); verChat(); add("estado", "volviendo al chat de IA..."); }
  else if (a === "recargar") { api("/recargar"); add("estado", "recargando la pagina..."); verChat(); }
  else if (a === "guardar") {
    clave = $("clave").value.trim();
    localStorage.setItem("nl_clave", clave);
    var d = $("destino").value.trim();
    (d ? api("/destino", {method:"POST", body:d}) : Promise.resolve({})).then(function(r) {
      verChat();
      add("estado", r && r.error ? ("⚠ " + r.error) : "guardado ✓");
    });
  }
});

/* ---------- 🪞 espejo ---------- */
$("bespejo").onclick = function() {
  panel.style.display = "none";
  espejoOn = !espejoOn;
  $("espejo").style.display = espejoOn ? "block" : "none";
  msgs.style.display = espejoOn ? "none" : "flex";
  if (espejoOn) tickEspejo();
};
function tickEspejo() {
  if (!espejoOn) return;
  api("/espejo").then(function(d) {
    $("espejo").textContent = d.texto || "cargando Notion en el navegador oculto... (la primera vez tarda 1-2 min)";
  }).catch(function(){});
  setTimeout(tickEspejo, 4000);
}

/* ---------- enviar ---------- */
function enviar() {
  var t = $("t").value.trim();
  if (!t) return;
  $("t").value = "";
  verChat();
  add("yo", t);
  $("b").disabled = true;
  burbuja = null;
  estado("enviando...");
  api("/preguntar", {method:"POST", body:t}).then(function(r) {
    if (r.error) { estado(""); add("ia", "⚠ " + r.error); $("b").disabled = false; return; }
    estado("Notion AI esta pensando...");
    (function poll() {
      setTimeout(function() {
        api("/estado?id=" + r.id).then(function(s) {
          if (s.listo) {
            estado("");
            if (burbuja) { burbuja.remove(); burbuja = null; }
            add("ia", s.texto || "(vacio)");
            if (s.error) add("estado", "⚠ " + s.error);
            $("b").disabled = false;
            $("t").focus();
          } else {
            if (s.parcial) {
              estado("");
              if (!burbuja) burbuja = add("ia parcial", "");
              burbuja.textContent = s.parcial + " ▍";
              msgs.scrollTop = msgs.scrollHeight;
            }
            poll();
          }
        }).catch(function() { poll(); });
      }, 2500);
    })();
  }).catch(function(e) {
    estado(""); add("ia", "⚠ error de red: " + e); $("b").disabled = false;
  });
}
$("b").onclick = enviar;
$("t").addEventListener("keydown", function(e) {
  if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); enviar(); }
});
if (!clave) $("bcfg").click();
</script>
</body>
</html>
HTMLEOF

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
 ✅ MODO LIGERO ACTIVO (v1.7)
------------------------------------------------------------
 Abre en tu PC/telefono:  https://$RUTA/
 Clave (boton ⚙, se guarda sola): $CLAVE
------------------------------------------------------------
 NUEVO en la mini-web:
   🤖  Elegir IA  — lee el selector de modelo de Notion y
       cambia al que elijas (GPT, Claude, etc.)
   📎  Archivos   — subes desde el telefono (max 20 MB) y
       lo adjunta al chat; luego escribes y envias
   ⚙   Cuenta     — abre Cuenta / Notificaciones / Conexiones
       / Espacio de Notion en texto y puedes pulsar sus
       botones desde el movil
   🪞  Espejo     — la pagina en texto, en vivo
------------------------------------------------------------
 Espera a ver "✓ pagina lista" arriba antes de escribir.
 Autodiagnostico:  https://$RUTA/prueba?clave=$CLAVE
 Estado general:   https://$RUTA/salud
------------------------------------------------------------
 Si dice "pide iniciar sesion": sh modo.sh pantalla → entra
 con email+codigo → sh modo.sh ligero
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
DIS