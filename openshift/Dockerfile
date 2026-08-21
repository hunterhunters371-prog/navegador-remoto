# Imagen propia para OpenShift Developer Sandbox ("Nivel 2")
#
# Por qué existe: el sandbox NO da root en ejecución (UID aleatorio),
# pero las BUILDS de imágenes sí corren como root. Con este Dockerfile
# horneamos el Firefox actualizado de los repositorios de Rocky 9
# dentro de la imagen: adiós al navegador viejo de fábrica, incluso
# tras reinicios del pod.
#
# Uso (terminal web de OpenShift):
#   oc new-build https://github.com/hunterhunters371-prog/navegador-remoto --name navimg --context-dir=openshift
#   oc start-build navimg --follow
#   oc new-app navimg --name nav2 -e VNC_PW=miclave -e VNC_RESOLUTION=1280x720 -e VNC_COL_DEPTH=16
#   oc set resources deployment nav2 --requests=cpu=250m,memory=512Mi --limits=cpu=1,memory=2Gi
#   oc create route edge nav2 --service nav2 --port 6901 --insecure-policy Redirect
#
FROM docker.io/consol/rocky-icewm-vnc

USER 0
RUN dnf -y update firefox 2>/dev/null || dnf -y install firefox \
 && dnf clean all \
 && rm -rf /var/cache/dnf /var/cache/yum

# La imagen base usa nss_wrapper: OpenShift la ejecuta igual con su UID aleatorio.
USER 1000
