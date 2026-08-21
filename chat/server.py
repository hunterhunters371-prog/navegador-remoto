#!/usr/bin/env python3
# server.py v1.7 - puente de texto <-> Notion AI (Firefox headless + Marionette)
# Solo stdlib. Vive en /headless/data/chat/ dentro del pod; lo instala modo.sh
#
# NUEVO en v1.7:
#   - /modelos y /modelo   -> elegir la IA (selector de modelo de Notion)
#   - /subir /archivos /adjuntar /borrar-archivo -> archivos desde el movil
#   - /ir /clic /controles /pantalla-texto /cuenta /volver -> usar la
#     configuracion de cuenta de Notion (y cualquier pantalla) por texto
import base64, json, mimetypes, os, re, socket, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

BASE = "/headless/data/chat"
SUBIDAS = "/headless/data/subidas"
CLAVE = open(os.path.join(BASE, "clave.txt")).read().strip()
DESTINO_FILE = os.path.join(BASE, "destino.txt")
MODELO_FILE = os.path.join(BASE, "modelo.txt")
NOTION = "https://www." + "notion" + ".so/"
DESTINO_DEFAULT = "https://www.notion.so/chat"
if "{" in DESTINO_DEFAULT:                 # red de seguridad
    DESTINO_DEFAULT = NOTION
LIMITE = 20 * 1024 * 1024                  # 20 MB por archivo
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

# OJO (arreglo de v1.6): el script se ejecuta como CUERPO de funcion -> necesita return
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

# --- zona del composer: la barra donde viven el selector de modelo y el clip ---
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
const re = /gpt|claude|sonnet|opus|haiku|gemini|llama|mistral|deepseek|grok|auto|r[a\u00e1]pid|fast|advanc|avanzad|thinking|razona|model/i;
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
const re = /adjunt|attach|upload|subir|archivo|file|clip|imagen|image|a[\u00f1n]adir|add/i;
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

# --- usar la interfaz de Notion por texto (cuenta, ajustes, cualquier pantalla) ---
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
return "pulsado: " + ((e.innerText || e.getAttribute("aria-label") || "").trim().split("\\n")[0]).slice(0,60);
""" % SEL_CTRL
JS_CLIC_T = VIS + """
const q = %%s.toLowerCase();
const els = [...document.querySelectorAll('%s')].filter(vis);
const e = els.find(x => ((x.innerText || x.getAttribute("aria-label") || "").toLowerCase().indexOf(q) >= 0));
if (!e) return "no-esta";
try { e.scrollIntoView({block:"center"}); } catch (x) {}
e.click();
return "pulsado: " + ((e.innerText || "").trim().split("\\n")[0]).slice(0,60);
""" % SEL_CTRL
JS_CORREO = """
const t = (document.body && document.body.innerText) || "";
const m = t.match(/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}/);
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
        return {"actual": modelo_actual(), "modelos": [],
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
        if os.path.getsize(ruta) > 3 * 1024 * 1024:
            raise RuntimeError("no pude usar el selector de archivos de Notion y el archivo pasa de 3 MB para el plan B")
        datos = base64.b64encode(open(ruta, "rb").read()).decode("ascii")
        tipo = mimetypes.guess_type(nombre)[0] or "application/octet-stream"
        r = js(JS_PEGAR % (json.dumps(datos), json.dumps(nombre), json.dumps(tipo)))
        if r != "pegado":
            raise RuntimeError("no pude adjuntar el archivo (%s)" % r)
        via = "pegado en el cuadro de texto"
    time.sleep(1)
    return via

def clic_indice(idx):
    r = js(JS_CLIC_I % idx)
    time.sleep(1.5)
    return {"resultado": r, "texto": js(JS_TEXTO)}

def clic_texto(txt):
    r = js(JS_CLIC_T % json.dumps(txt))
    time.sleep(1.5)
    return {"resultado": r, "texto": js(JS_TEXTO)}

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
        # /subir recibe los bytes crudos (el nombre va en la URL): sin multipart
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
                self._json({"error": "el destino debe ser una pagina de Notion", "destino": destino_actual()}, 400)
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
                self._accion(lambda: clic_indice(idx), 25)
            else:
                txt = cuerpo or q.get("texto", [""])[0]
                self._accion(lambda: clic_texto(txt), 25)
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
# MARCA-FIN-SERVER v1.7
