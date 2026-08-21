# Navegador remoto ultra-ligero

Scripts para tener un navegador moderno (compatible con Notion) accesible desde cualquier navegador web, con el mínimo consumo de RAM/CPU/disco. Todo se usa por URL: copias una línea y listo.

## Contenido

| Archivo | Dónde corre | Qué hace |
|---|---|---|
| `openshift-nav.sh` | Terminal web de **Red Hat Developer Sandbox** (OpenShift) | Redepliega todo optimizado: IceWM + Firefox **actual** en ventana única 1024x600x16 (1 proceso, sin caché RAM, login y navegación normales), límites anti-OOM, ruta pública, y **auto-verifica** qué navegador quedó corriendo (versión + proceso real). Idempotente. |
| `openshift/Dockerfile` | **Build** dentro del sandbox | Imagen propia con Firefox actualizado horneado (las builds corren como root aunque los pods no). Sobrevive reinicios del pod. |
| `navegador-remoto.sh` | **VM real** con root (Alpine 3.20+ / Debian 12+, x86_64 o ARM64) | Stack mínimo desde cero: Xvfb + Chromium kiosko + x11vnc + noVNC, sin escritorio, zram, servicio con auto-reinicio, verificación y prueba de rendimiento de 60 s. Idempotente. |
| `diagnostico.sh` | Terminal web de OpenShift | Recoge en un solo bloque: pods, consumo, ruta, navegadores instalados (viejos vs nuevo), procesos corriendo y memoria. |

## Uso rápido

### OpenShift Sandbox (terminal web, icono `>_`)

```bash
curl -fsSL https://raw.githubusercontent.com/hunterhunters371-prog/navegador-remoto/main/openshift-nav.sh -o os.sh && sh os.sh
```

Con tu propia contraseña:

```bash
curl -fsSL https://raw.githubusercontent.com/hunterhunters371-prog/navegador-remoto/main/openshift-nav.sh -o os.sh && VNC_PASSWORD='TuClave' sh os.sh
```

Diagnóstico (si algo falla, esto lo dice todo):

```bash
curl -fsSL https://raw.githubusercontent.com/hunterhunters371-prog/navegador-remoto/main/diagnostico.sh -o d.sh && sh d.sh
```

### Nivel 2 — tu propia imagen (Firefox horneado, sobrevive reinicios)

```bash
oc new-build https://github.com/hunterhunters371-prog/navegador-remoto --name navimg --context-dir=openshift
oc start-build navimg --follow
oc new-app navimg --name nav2 -e VNC_PW=miclave -e VNC_RESOLUTION=1024x600 -e VNC_COL_DEPTH=16
oc set resources deployment nav2 --requests=cpu=250m,memory=512Mi --limits=cpu=1,memory=2Gi
oc create route edge nav2 --service nav2 --port 6901 --insecure-policy Redirect
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

## Preguntas frecuentes

**¿Se puede rootear el sandbox de OpenShift?**
No: los pods corren con usuario aleatorio sin privilegios (regla del clúster). Pero las *builds* de imagen sí corren como root — por eso existe `openshift/Dockerfile`: controlas todo lo que va dentro de tu propia imagen. Para root verdadero necesitas una VM real (y ahí corre `navegador-remoto.sh`).

**¿Cómo distingo el navegador nuevo del viejo?**
La ventana que se abre sola cargando Notion = Firefox nuevo. Iconos del escritorio / ventana con menús = el viejo de la imagen de 2023.

**¿Si el pod se reinicia?**
Vuelve a correr el comando de OpenShift (es idempotente). Con la imagen propia (Nivel 2) ni siquiera hace falta reinstalar el navegador.

## Requisitos mínimos reales

- VM real: ~700 MB RAM libres y ~900 MB de disco (un navegador moderno no cabe en 500 MB de disco).
- Sandbox: nada — el script se encarga de todo.

## Seguridad

- No almacenes secretos en estos scripts; la contraseña por defecto es solo un marcador — cámbiala siempre con `VNC_PASSWORD`.
- El VNC crudo solo escucha en localhost; tu puerta de entrada es el puerto web con contraseña.
