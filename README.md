# Navegador remoto ultra-ligero

Scripts para tener un navegador moderno (compatible con Notion) accesible desde cualquier navegador web, con el mínimo consumo de RAM/CPU/disco.

## Contenido

| Script | Dónde corre | Qué hace |
|---|---|---|
| `openshift-nav.sh` | Terminal web de **Red Hat Developer Sandbox** (OpenShift) | Redepliega todo optimizado: IceWM + Firefox actual en modo kiosko (1 proceso, sin caché RAM, 1280x720x16), límites anti-OOM, ruta pública. Idempotente. |
| `navegador-remoto.sh` | **VM real** con root (Alpine 3.20+ / Debian 12+, x86_64 o ARM64) | Instala el stack mínimo desde cero: Xvfb + Chromium kiosko + x11vnc + noVNC, sin escritorio, con zram, servicio con auto-reinicio, verificación y prueba de rendimiento de 60 s. Idempotente. |

## Uso rápido

### OpenShift Sandbox (terminal web, icono `>_`)

```bash
curl -fsSL https://raw.githubusercontent.com/hunterhunters371-prog/navegador-remoto/main/openshift-nav.sh -o os.sh && sh os.sh
```

Con tu propia contraseña:

```bash
curl -fsSL https://raw.githubusercontent.com/hunterhunters371-prog/navegador-remoto/main/openshift-nav.sh -o os.sh && VNC_PASSWORD='TuClave' sh os.sh
```

### VM real con root (Alpine/Debian, por SSH)

```bash
curl -fsSL https://raw.githubusercontent.com/hunterhunters371-prog/navegador-remoto/main/navegador-remoto.sh -o rb.sh && sudo sh rb.sh
```

Alpine (usa wget):

```bash
wget -q https://raw.githubusercontent.com/hunterhunters371-prog/navegador-remoto/main/navegador-remoto.sh -O rb.sh && sudo sh rb.sh
```

Con tu propia contraseña y otra página de inicio:

```bash
sudo VNC_PASSWORD='TuClave' HOME_URL='https://tupagina.com' sh rb.sh
```

## Notas

- Ambos scripts son **idempotentes**: puedes ejecutarlos varias veces sin romper nada; reconfiguran y relanzan.
- Si el pod de OpenShift se reinicia (sandbox efímero), basta con volver a correr el comando de OpenShift.
- Requisitos mínimos reales para la VM: ~700 MB RAM libres y ~900 MB de disco (un navegador moderno no cabe en 500 MB de disco).
- No almacenes secretos en estos scripts; la contraseña por defecto es solo un marcador — cámbiala siempre con `VNC_PASSWORD`.
