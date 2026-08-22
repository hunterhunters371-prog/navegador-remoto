#!/usr/bin/env python3
# server.py v1.9 - puente de texto <-> Notion AI (Firefox headless + Marionette)
# Solo stdlib. Vive en /headless/data/chat/ dentro del pod; lo instala modo.sh
#
# NUEVO en v1.9 (pedido del usuario, sin costo de optimizacion):
#   - /chats (GET) -> historial de chats de IA leyendo el PANEL LATERAL ya
#     cargado (cero navegaciones). Devuelve [{t, h, chat}], url absoluta, y
#     "actual" para marcar el chat abierto. Cambiar de chat = POST /destino
#     de siempre (navegacion unica inmediata, existe desde v1.5).
#   - /nuevo-chat (POST) -> clic en "Nuevo chat", guarda la URL nueva como
#     destino y espera el composer (12 s tope). Chat vacio = el mas liviano.
#   - /bajables y /descargar -> bajar archivos del pod (Downloads/ y subidas/)
#     al telefono por la propia mini-web (sin 0x0.st ni servicios externos).
#   - /salud trae "cuenta" (nombre del workspace; lo lee el lector en 2do
#     plano. /salud sigue sin tocar Marionette: nunca se cuelga).
# v1.8.2:
#   - El selector de modelo existia pero mi lista no conocia "Kimi K3" ->
#     JS_ABRIR_MODELO ahora reconoce kimi/qwen/glm/minimax ademas de los de antes.
#   - JS_LOGIN daba falso positivo en chats cuyo TEXTO habla de "iniciar sesion":
#     ahora, si hay un composer visible (contenteditable), NO es login. Punto.
#   - lector() con ritmo adaptativo: 5 s mientras la pagina carga, 15 s cuando
#     ya esta lista (leer 67 mil caracteres cada 5 s quemaba CPU del pod gratis).
# v1.8.1 (arreglo del login, con evidencia del pod):
#   - /entrar fallaba con "no encontre el boton Continuar": la pagina de login
#     de Notion no usa <button>Continuar</button>. Ahora: Enter REAL dentro del
#     campo de correo (ElementSendKeys \uE007 = envia el form nativo) y, de
#     respaldo, clic ampliado (button + [role=button] + submit; NUNCA Google/
#     Apple/SSO). Si nada funciona, el error LISTA los botones visibles reales.
#   - JS_LOGIN tambien lee document.title (la pagina de login dice "Iniciar
#     sesion" solo en el titulo) -> el arranque ya no se cuelga 180 s.
#   - /entrar y /codigo devuelven "pantalla" (texto visible) para diagnosticar.
# v1.8:
#   - /sesion (GET)  -> estado de la sesion de Notion (correo visto, parece_login)
#   - /entrar (POST correo) -> abre el login de Notion y pide el codigo al correo
#   - /codigo (POST codigo) -> escribe el codigo recibido y completa la entrada
#   - /salir  (POST) -> cierra la sesion (notion.so/logout; plan B: cookies +
#     localStorage) y resetea destino.txt a la portada
#   REGLA DE ORO: el login es SOLO correo + codigo. NUNCA "Continuar con
#   Google" (la IP del datacenter hace que Google bloquee la cuenta).
# v1.7:
#   - /modelos y /modelo   -> elegir la IA (selector de modelo de Notion)
#   - /subir /archivos /adjuntar /borrar-archivo -> archivos desde el movil
#   - /ir /clic /controles /pantalla-texto /cuenta /volver -> usar la
#     configuracion de cuenta de Notion (y cualquier pantalla) por texto
import base64, json, mimetypes, os, re, socket, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

BASE = "/headless/data/chat"
SUBIDAS = "/headless/data/subidas"
DESCARGAS = "/headless/data/Downloads"
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
cache = {"texto": "", "cuando": 0, "escribiendo": False, "cuenta": ""}
pagina = {"estado": "iniciando", "desde": time.time(), "detalle": ""}
_navegando = [False]
nom_tick = [0]

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

def lista_dir(ruta):
    out = []
    try:
        for n in sorted(os.listdir(ruta)):
            p = os.path.join(ruta, n)
            if os.path.isfile(p):
                out.append({"nombre": n, "kb": int(os.path.getsize(p) / 1024) or 1})
    except Exception:
        pass
    return out

def lista_subidas():
    return lista_dir(SUBIDAS)

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
// un chat con composer visible NUNCA es la pantalla de login (v1.8.2:
// el texto de un chat puede hablar de "iniciar sesion" y engañar al regex)
const hayComposer = [...document.querySelectorAll('div[contenteditable="true"]')]
  .some(e => e.offsetParent !== null);
if (hayComposer) return false;
const t = ((document.body && document.body.innerText) || "") + " " + (document.title || "");
return /log in|sign in|iniciar sesi|inicia sesi|continuar con|continue with|continua con/i.test(t);
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
const re = /gpt|claude|sonnet|opus|haiku|gemini|llama|mistral|deepseek|grok|kimi|qwen|glm|minimax|auto|r[a\u00e1]pid|fast|advanc|avanzad|thinking|razona|model/i;
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
JS_NOMBRE = """
const sw = document.querySelector('.notion-sidebar-switcher');
if (sw && (sw.innerText || '').trim())
  return (sw.innerText || '').trim().split('\\n')[0].slice(0, 40);
const b = [...document.querySelectorAll('div[role="button"], button')]
  .find(x => /espacio|workspace|cuenta|account/i.test(x.getAttribute('aria-label') || ''));
if (b) return (b.getAttribute('aria-label') || '').trim().slice(0, 40);
return '';
"""

# --- historial de chats: el panel lateral YA esta cargado; solo se lee ---
JS_CHATS = VIS + """
const esItem = /chat\\?|[0-9a-f]{32}/;
const nav = document.querySelector('nav') || document.body;
let as = [...nav.querySelectorAll('a[href]')].filter(vis);
if (!as.length) as = [...document.querySelectorAll('a[href]')].filter(vis);
const out = [];
for (const a of as) {
  const h0 = a.getAttribute('href') || '';
  if (!h0 || h0.indexOf('javascript') === 0) continue;
  const h = new URL(h0, location.origin).href;
  if (!esItem.test(h)) continue;
  const t = ((a.innerText || '').trim().split('\\n')[0]).slice(0, 70);
  if (!t) continue;
  out.push({t: t, h: h, chat: h.indexOf('chat') >= 0});
}
const vistos = new Set();
const limpio = out.filter(x => !vistos.has(x.h) && vistos.add(x.h));
return JSON.stringify({chats: limpio.slice(0, 40), actual: location.href});
"""

# --- sesion de Notion (correo + codigo; el boton de Google queda PROHIBIDO) ---
SEL_EMAIL = ('input[autocomplete="email"], input[type="email"], input[name="email"], '
             'input[placeholder*="correo" i], input[placeholder*="email" i], '
             'input:not([type=hidden]):not([type=checkbox]):not([type=radio])')
SEL_CODIGO = ('input[autocomplete="one-time-code"], input[inputmode="numeric"], '
              'input[type="tel"], input[name="code"], '
              'input[placeholder*="codigo" i], input[placeholder*="code" i]')
JS_CLIC_ENTRAR = VIS + """
// NUNCA Google/Apple/SSO. Si no encuentra el boton de envio, devuelve
// la lista real de botones visibles para diagnosticar sin adivinar.
const PROH = /google|apple|microsoft|saml|sso|facebook/i;
const OK = /^(continuar|continue|siguiente|next|enviar|send|log in|iniciar sesi[o\u00f3]n|inicia sesi[o\u00f3]n|continuar con correo|continue with email)$/i;
const bs = [...document.querySelectorAll('button, [role="button"], input[type="submit"]')].filter(vis);
const lista = bs.map(x => ((x.innerText || x.value || x.getAttribute("aria-label") || "").trim().split("\\n")[0]).slice(0,40)).filter(t => t.length > 0);
const b = bs.find(x => {
  const t = ((x.innerText || x.value || x.getAttribute("aria-label") || "").trim().split("\\n")[0]);
  return OK.test(t) && !PROH.test(t);
});
if (!b) return "no-esta: " + JSON.stringify(lista.slice(0, 12));
b.click();
return "clic: " + ((b.innerText || b.value || "").trim().split("\\n")[0]).slice(0, 40);
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
            if js(JS_LOGIN):
                # sin sesion no hay composer: salir YA para no bloquear /entrar
                pagina["estado"] = "login"
                return False
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
        raise RuntimeError("Notion pide iniciar sesion: en la mini-web toca ⚙ y usa 'Sesion de Notion' (correo + codigo; NUNCA Google)")
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

# ---------------- sesion: entrar / codigo / salir ----------------
def buscar(selector, seg=15):
    t0 = time.time()
    while time.time() - t0 < seg:
        try:
            el = cmd("WebDriver:FindElement", {"using": "css selector", "value": selector})
            return list(el.values())[0] if isinstance(el, dict) else el
        except Exception:
            time.sleep(1)
    raise RuntimeError("no aparecio el campo en la pagina (%s)" % selector)

def hay_campo(selector, seg=4):
    t0 = time.time()
    while time.time() - t0 < seg:
        try:
            cmd("WebDriver:FindElement", {"using": "css selector", "value": selector})
            return True
        except Exception:
            time.sleep(1)
    return False

def pantalla_corta():
    try:
        return (js(JS_TEXTO) or "")[:300]
    except Exception:
        return ""

def estado_sesion():
    return {"url": js(JS_URL) or "", "titulo": js(JS_TITULO) or "",
            "correo": js(JS_CORREO) or "", "parece_login": bool(js(JS_LOGIN)),
            "pagina": pagina["estado"]}

def entrar(correo):
    correo = (correo or "").strip()
    if not re.match(r"^[^@\s]+@[^@\s]+\.[^@\s]+$", correo):
        raise RuntimeError("ese correo no parece valido")
    navegar(NOTION + "login")
    pagina["estado"] = "login"
    pagina["detalle"] = "pidiendo codigo para %s" % correo
    eid = buscar(SEL_EMAIL, 18)
    cmd("WebDriver:ElementSendKeys", {"id": eid, "text": correo})
    time.sleep(1)
    # via 1: Enter real dentro del campo -> envia el formulario nativo
    try:
        cmd("WebDriver:ElementSendKeys", {"id": eid, "text": ""})
    except Exception:
        pass
    time.sleep(4)
    if hay_campo(SEL_CODIGO, 3):
        return {"correo": correo, "url": js(JS_URL) or "", "via": "enter",
                "pantalla": pantalla_corta()}
    # via 2: clic al boton de envio (sin depender de su texto exacto)
    r = js(JS_CLIC_ENTRAR) or ""
    time.sleep(4)
    if hay_campo(SEL_CODIGO, 3) or r.startswith("clic:"):
        return {"correo": correo, "url": js(JS_URL) or "", "via": r,
                "pantalla": pantalla_corta()}
    raise RuntimeError("escribi el correo pero el envio no avanzo. Botones visibles: %s | pantalla: %s"
                       % (r, pantalla_corta()))

def entrar_codigo(codigo):
    codigo = re.sub(r"\s+", "", codigo or "")
    if not codigo:
        raise RuntimeError("codigo vacio")
    eid = buscar(SEL_CODIGO, 12)
    cmd("WebDriver:ElementSendKeys", {"id": eid, "text": codigo})
    time.sleep(1)
    try:
        cmd("WebDriver:ElementSendKeys", {"id": eid, "text": ""})
    except Exception:
        pass
    time.sleep(3)
    url = js(JS_URL) or ""
    if "login" in url or js(JS_LOGIN):
        js(JS_CLIC_ENTRAR)
        time.sleep(4)
        url = js(JS_URL) or ""
    if "login" in url and js(JS_LOGIN):
        raise RuntimeError("el codigo no fue aceptado (¿mal copiado o expirado?) — pide otro con Enviar codigo. Pantalla: %s" % pantalla_corta())
    pagina["estado"] = "otra-pagina"
    pagina["detalle"] = "sesion iniciada"
    navegar(NOTION)
    time.sleep(3)
    cache["texto"] = ""
    cache["cuando"] = 0
    return {"url": js(JS_URL) or "", "pantalla": pantalla_corta()}

def salir():
    try:
        navegar(NOTION + "logout")
        time.sleep(5)
    except Exception:
        pass
    url = ""
    try:
        url = js(JS_URL) or ""
    except Exception:
        pass
    if "login" not in url:
        # plan B: borrar cookies y almacenamiento local estando en el dominio
        try:
            js("try{localStorage.clear();sessionStorage.clear();}catch(e){} return 'ok'")
            cmd("WebDriver:DeleteCookies", {})
        except Exception:
            pass
        try:
            navegar(NOTION + "login")
            time.sleep(4)
        except Exception:
            pass
    try:
        open(DESTINO_FILE, "w").write(NOTION + "\n")
    except Exception:
        pass
    cache["texto"] = ""
    cache["cuando"] = 0
    cache["cuenta"] = ""
    pagina["estado"] = "login"
    pagina["detalle"] = "sesion cerrada"
    return {"url": js(JS_URL) or "", "parece_login": bool(js(JS_LOGIN))}

# ---------------- chats: historial / cambiar / nuevo (v1.9) ----------------
def nuevo_chat():
    r = js(JS_CLIC_T % json.dumps("nuevo chat"))
    if r == "no-esta":
        r = js(JS_CLIC_T % json.dumps("new chat"))
    if r == "no-esta":
        raise RuntimeError("no encontre el boton 'Nuevo chat' en esta pantalla")
    time.sleep(3)
    url = js(JS_URL) or ""
    if "notion" in url:
        open(DESTINO_FILE, "w").write(url + "\n")
    cache["texto"] = ""
    cache["cuando"] = 0
    pagina["estado"] = "cargando"
    pagina["desde"] = time.time()
    esperar_composer(12)
    return {"url": destino_actual(), "titulo": js(JS_TITULO) or "",
            "pagina": pagina["estado"], "pulsado": r}

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
    # lee la pagina en 2do plano y cachea: el espejo nunca bloquea.
    # ritmo adaptativo (v1.8.2): rapido durante la carga, calmado al estar lista
    while True:
        time.sleep(5 if pagina["estado"] in ("iniciando", "cargando", "navegando") else 15)
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
            nom_tick[0] += 1
            if nom_tick[0] % 8 == 0:
                nm = js(JS_NOMBRE)   # nombre del workspace para la cabecera
                if nm:
                    cache["cuenta"] = nm
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
            self._json({"ok": True, "version": "1.9", "firefox_headless": ff,
                        "marionette": m, "destino": destino_actual(),
                        "modelo": modelo_actual(), "archivos": len(lista_subidas()),
                        "pagina": pagina["estado"], "detalle": pagina["detalle"],
                        "cuenta": cache["cuenta"],
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
        if path == "/bajables":
            self._json({"descargas": lista_dir(DESCARGAS), "subidas": lista_dir(SUBIDAS)})
            return
        if path == "/descargar":
            nombre = nombre_seguro(q.get("nombre", [""])[0])
            base = DESCARGAS if q.get("de", [""])[0] == "descargas" else SUBIDAS
            ruta = os.path.join(base, nombre)
            if not nombre or not os.path.isfile(ruta):
                self._json({"error": "no existe ese archivo"}, 404)
                return
            tam = os.path.getsize(ruta)
            tipo = mimetypes.guess_type(nombre)[0] or "application/octet-stream"
            self.send_response(200)
            self.send_header("Content-Type", tipo)
            self.send_header("Content-Length", str(tam))
            self.send_header("Content-Disposition",
                             "attachment; filename*=UTF-8''" + nombre.replace(" ", "%20"))
            self.end_headers()
            with open(ruta, "rb") as f:
                while True:
                    trozo = f.read(65536)
                    if not trozo:
                        break
                    self.wfile.write(trozo)
            return
        if path == "/chats":
            self._accion(lambda: json.loads(js(JS_CHATS) or "{}"), 20)
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
        if path == "/sesion":
            self._accion(estado_sesion, 20)
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
        if path == "/entrar":
            self._accion(lambda: entrar(cuerpo or q.get("correo", [""])[0]), 30)
            return
        if path == "/codigo":
            self._accion(lambda: entrar_codigo(cuerpo or q.get("codigo", [""])[0]), 30)
            return
        if path == "/salir":
            self._accion(salir, 30)
            return
        if path == "/nuevo-chat":
            self._accion(nuevo_chat, 30)
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
# MARCA-FIN-SERVER v1.9
