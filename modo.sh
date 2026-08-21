#!/bin/sh
# ============================================================
#  modo.sh — interruptor de nav1: PANTALLA (VNC) <-> LIGERO (texto)
#  v1.3 EXPERIMENTAL
#    · el headless PRECARGA Notion apenas arranca (antes la pagina
#      quedaba en blanco hasta la primera pregunta y el espejo no
#      mostraba nada)
#    · el destino guardado se AUTOVALIDA: si no es de Notion se
#      resetea solo (sanaea el destino malo de pruebas anteriores)
#  v1.2 · respuesta en vivo (texto parcial) + boton Espejo 🪞
#  v1.1 · destino validado (solo URLs de Notion) + /debug
#  v1.0 · Firefox headless + Marionette + mini chat web de texto
#
#  Uso (terminal web de OpenShift, icono >_):
#    sh modo.sh ligero     → activa/actualiza el chat de texto
#    sh modo.sh pantalla   → vuelve al escritorio VNC de siempre
#    sh modo.sh estado     → que esta corriendo ahora
# ============================================================
set -eu

APP="${APP:-nav1}"
RES="${RES:-1024x600}"
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

  log "Instalando el puente en el volumen persistente (server.py + chat.html)..."
  oc exec -i "$POD" -- sh -c 'mkdir -p /headless/data/chat'
  oc exec -i "$POD" -- sh -c 'cat > /headless/data/chat/server.py' <<'PYEOF'
#!/usr/bin/env python3
# server.py — puente texto <-> Notion AI (Firefox headless + Marionette)
# Vive en /headless/data/chat/ (volumen persistente). Lo instala modo.sh.
# Solo usa la libreria estandar de Python.
import json, os, socket, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

BASE = "/headless/data/chat"
CLAVE = open(os.path.join(BASE, "clave.txt")).read().strip()
DESTINO_FILE = os.path.join(BASE, "destino.txt")
DESTINO_DEFAULT = "https://www.notion.so/chat"
PORT = int(os.environ.get("CHAT_PORT", "6902"))

jobs = {}
contador = [0]
cont_lock = threading.Lock()
m_lock = threading.Lock()   # Marionette NO es hilo-seguro: 1 pregunta a la vez
vivo = {"texto": "", "job": None}   # texto parcial de la respuesta en curso
_calentando = [False]

# ---------------- Marionette minimo (solo stdlib) ----------------
class Marionette:
    def __init__(self, port=2828):
        self.s = socket.create_connection(("127.0.0.1", port), timeout=30)
        self.s.settimeout(90)
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
    for _ in range(40):
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
            try:
                c.close()
            except Exception:
                pass
            _m = None
            time.sleep(2)
    raise RuntimeError("no pude conectar con Firefox headless: %s" % ultimo)

def js(script):
    return valor(conectar().cmd("WebDriver:ExecuteScript", {"script": script, "args": []}))

def destino_actual():
    # autovalida: si lo guardado no es de Notion, vuelve al default
    if os.path.exists(DESTINO_FILE):
        d = open(DESTINO_FILE).read().strip()
        if d and "notion" in d.lower():
            return d
    return DESTINO_DEFAULT

def lanzar_calentar():
    # precarga Notion en el headless sin bloquear al servidor
    if _calentando[0]:
        return
    _calentando[0] = True
    def run():
        try:
            with m_lock:
                destino = destino_actual()
                actual = ""
                try:
                    actual = js("location.href") or ""
                except Exception:
                    actual = ""
                if destino.split("?")[0] not in actual:
                    js("location.href = " + json.dumps(destino))
        except Exception:
            pass
        finally:
            _calentando[0] = False
    threading.Thread(target=run, daemon=True).start()

JS_COMPOSER = """
(() => {
  const eds = [...document.querySelectorAll('div[contenteditable="true"]')]
    .filter(e => e.offsetParent !== null);
  return eds.length > 0;
})()
"""

def asegurar_pagina():
    destino = destino_actual()
    actual = ""
    try:
        actual = js("location.href") or ""
    except Exception:
        actual = ""
    if destino.split("?")[0] not in actual:
        js("location.href = " + json.dumps(destino))
        t0 = time.time()
        while time.time() - t0 < 120:
            time.sleep(3)
            try:
                if js(JS_COMPOSER):
                    return
            except Exception:
                pass
        raise RuntimeError("la pagina no mostro el cuadro de texto a tiempo (login vencido o URL destino incorrecta)")

JS_ENVIAR = """
(() => {
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
})()
"""

JS_LEER = """
(() => {
  const main = document.querySelector("main") || document.body;
  const stop = !!document.querySelector(
    '[aria-label*="Stop"], [aria-label*="stop"], [aria-label*="Detener"], [aria-label*="detener"]');
  return JSON.stringify({texto: (main.innerText || ""), escribiendo: stop});
})()
"""

def leer():
    try:
        return json.loads(js(JS_LEER) or "{}")
    except Exception:
        return {"texto": "", "escribiendo": False}

def extraer(actual, base, prompt):
    if base and actual.startswith(base):
        nuevo = actual[len(base):]
    else:
        nuevo = actual
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
                raise RuntimeError("no encontre el cuadro de texto de Notion AI")
            anterior = ""
            estable = 0
            t0 = time.time()
            while time.time() - t0 < 300:
                time.sleep(2)
                info = leer()
                cand = extraer(info["texto"], base, texto)
                vivo["texto"] = cand
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
    def do_GET(self):
        path = urlparse(self.path).path
        if path == "/salud":
            self._json({"ok": True, "modo": "ligero"})
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
            q = parse_qs(urlparse(self.path).query)
            jid = int(q.get("id", ["0"])[0])
            job = jobs.get(jid, {"listo": False})
            if not job.get("listo") and vivo.get("job") == jid and vivo.get("texto"):
                job = dict(job)
                job["parcial"] = vivo["texto"]
            self._json(job)
            return
        if path == "/espejo":
            if m_lock.locked():
                self._json({"ocupado": True, "texto": vivo.get("texto", ""), "cargando": not vivo.get("texto")})
                return
            with m_lock:
                try:
                    info = leer()
                    txt = info.get("texto") or ""
                    if not txt.strip():
                        lanzar_calentar()
                        self._json({"ocupado": False, "texto": "", "cargando": True})
                        return
                    self._json({"ocupado": False, "texto": txt[-4000:], "escribiendo": info.get("escribiendo", False)})
                except Exception as e:
                    self._json({"ocupado": False, "texto": "", "error": str(e)})
            return
        if path == "/destino":
            self._json({"destino": destino_actual()})
            return
        if path == "/debug":
            with m_lock:
                try:
                    info = {
                        "url_actual": js("location.href"),
                        "titulo": js("document.title"),
                        "composer_encontrado": js(JS_COMPOSER),
                        "parece_pantalla_de_login": js("!!document.body && /log in|sign in|iniciar sesi|continuar con/i.test(document.body.innerText||'')"),
                    }
                except Exception as e:
                    info = {"error": str(e)}
            info["destino_configurado"] = destino_actual()
            self._json(info)
            return
        self._json({"error": "ruta desconocida"}, 404)
    def do_POST(self):
        if not self._ok():
            self._json({"error": "clave mala"}, 403)
            return
        path = urlparse(self.path).path
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
            self._json({"destino": cuerpo})
            return
        self._json({"error": "ruta desconocida"}, 404)

if __name__ == "__main__":
    lanzar_calentar()   # precarga Notion apenas arranca el servidor
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
  input, button, textarea { font:inherit; color:inherit; background:#22262f; border:1px solid #333947; border-radius:8px; padding:8px 10px; }
  button { background:#2f6fed; border-color:#2f6fed; cursor:pointer; }
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
  #espejo { display:none; flex:1; overflow-y:auto; margin:0; padding:14px; white-space:pre-wrap; word-wrap:break-word; font:13px/1.5 ui-monospace, Menlo, monospace; color:#c9d1d9; }
</style>
</head>
<body>
<header>
  <b>⚡ Notion AI — modo ligero</b>
  <button id="bespejo" type="button" title="Espejo: ver la pagina en texto, en vivo">🪞</button>
  <button id="bcfg" type="button">⚙</button>
</header>
<header id="cfg">
  <input id="clave" placeholder="clave" type="password">
  <input id="destino" placeholder="URL de tu pagina/chat de Notion (notion.so/...)">
  <button id="bg" type="button">Guardar</button>
</header>
<div id="msgs"></div>
<pre id="espejo"></pre>
<footer>
  <textarea id="t" placeholder="Escribe tu mensaje... (Enter envia, Shift+Enter salto)"></textarea>
  <button id="b">Enviar</button>
</footer>
<script>
var $ = function(id){ return document.getElementById(id); };
var msgs = $("msgs");
var clave = localStorage.getItem("nl_clave") || "";
$("clave").value = clave;
var burbuja = null;
var espejoOn = false;

function add(cls, txt) {
  var d = document.createElement("div");
  d.className = "m " + cls;
  d.textContent = txt;
  msgs.appendChild(d);
  msgs.scrollTop = msgs.scrollHeight;
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
$("bcfg").onclick = function() {
  var c = $("cfg");
  c.style.display = (c.style.display === "flex") ? "none" : "flex";
  api("/destino").then(function(d){ $("destino").value = d.destino || ""; }).catch(function(){});
};
$("bespejo").onclick = function() {
  espejoOn = !espejoOn;
  $("espejo").style.display = espejoOn ? "block" : "none";
  msgs.style.display = espejoOn ? "none" : "flex";
  if (espejoOn) tickEspejo();
};
function tickEspejo() {
  if (!espejoOn) return;
  api("/espejo").then(function(d) {
    $("espejo").textContent = d.texto || (d.error ? ("⚠ " + d.error) : "cargando Notion en el navegador oculto... (la primera vez tarda 1-2 min)");
  }).catch(function(){});
  setTimeout(tickEspejo, 4000);
}
$("bg").onclick = function() {
  clave = $("clave").value.trim();
  localStorage.setItem("nl_clave", clave);
  var d = $("destino").value.trim();
  var p = d ? api("/destino", {method:"POST", body:d}) : Promise.resolve();
  p.then(function(r){ if (r && r.error) { add("estado", "⚠ " + r.error); } else { add("estado", "guardado ✓"); } });
};
function enviar() {
  var t = $("t").value.trim();
  if (!t) return;
  $("t").value = "";
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
    estado("");
    add("ia", "⚠ error de red: " + e);
    $("b").disabled = false;
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
  oc exec -i "$POD" -- sh -s <<'INNER'
set -e
D=/headless/data
# 1. apagar vigilante + firefox de pantalla (el perfil queda libre)
pkill -f 'firefo\[x\]' 2>/dev/null || true
pkill -f 'vigilante' 2>/dev/null || true
pkill -f "$D/firefox/firefox" 2>/dev/null || true
sleep 2
# 2. clave del chat (se genera una sola vez)
if [ ! -s "$D/chat/clave.txt" ]; then
  head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$D/chat/clave.txt"
fi
# 3. firefox headless con marionette (MISMO perfil = mismo login)
MOZ_HEADLESS=1 nohup "$D/firefox/firefox" --headless --marionette --profile "$D/ff-notion" >/dev/null 2>&1 &
# 4. servidor del chat (reinicio limpio)
pkill -f 'chat/server.py' 2>/dev/null || true
sleep 1
nohup python3 "$D/chat/server.py" >/dev/null 2>&1 &
# 5. verificacion
sleep 2
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
 ✅ MODO LIGERO ACTIVO (v1.3 experimental)
------------------------------------------------------------
 Abre en tu PC/telefono:  https://$RUTA/
 Clave (te la pide una vez, boton ⚙): $CLAVE
------------------------------------------------------------
 · NUEVO: el headless PRECARGA Notion al arrancar (el espejo
   tarda 1-2 min la primera vez en llenarse — es normal).
 · La respuesta se va viendo MIENTRAS se genera.
 · Boton 🪞 = espejo de texto de la pagina (cada 4 s).
 · El DESTINO (boton ⚙) debe ser una pagina de NOTION;
   si quedo uno malo guardado, se resetea solo a
   https://www.notion.so/chat
 · Diagnostico: https://$RUTA/debug?clave=$CLAVE
------------------------------------------------------------
 Si algo falla: vuelve a la normalidad con
   sh modo.sh pantalla
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
DISPLAY=:1 nohup "$D/firefox/firefox" --width "$W" --height "$H" --profile "$D/ff-notion" "$FF_URL" >/dev/null 2>&1 &
nohup sh -c 'D="$HOME/data"; while true; do if ! pgrep -f "firefo[x]/firefox" >/dev/null 2>&1; then W=$(echo "$FF_RES" | cut -dx -f1); H=$(echo "$FF_RES" | cut -dx -f2); DISPLAY=:1 "$D/firefox/firefox" --width "$W" --height "$H" --profile "$D/ff-notion" "$FF_URL" >/dev/null 2>&1 & fi; sleep 15; done' >/dev/null 2>&1 &
echo "   [OK] escritorio VNC + vigilante activos otra vez"
INNER
  RUTA=$(oc get route "$APP" -o jsonpath='{.spec.host}')
  echo
  echo " ✅ MODO PANTALLA ACTIVO — tu URL de siempre:"
  echo "    https://$RUTA/?password=<tu-clave-VNC>"
  echo
  ;;

# ================== ESTADO ==================
estado|*)
  echo "== procesos en el pod =="
  oc exec -i "$POD" -- sh -c 'ps aux | grep -E "firefox|server.py" | grep -v grep || echo "   (nada de eso corriendo)"' 2>/dev/null || true
  echo
  echo "== rutas =="
  oc get route 2>/dev/null || true
  ;;
esac
