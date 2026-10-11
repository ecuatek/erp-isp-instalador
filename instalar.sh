#!/usr/bin/env bash
#
# ERP-ISP · Instalador
#
#   curl -fsSL https://raw.githubusercontent.com/ecuatek/erp-isp-instalador/main/instalar.sh \
#     | sudo APP_DOMAIN=<dominio> ADMIN_EMAIL=<correo> bash
#
# Trae el aprovisionamiento y lo ejecuta. Nada mas: todo lo que hace de
# verdad esta en `provision.sh`, y este guion existe solo para que ese
# llegue a una maquina que todavia no tiene credenciales de nada.
#
# ── Por que hace falta un guion para traer otro ──────────────────────
#
# El ERP vive en un repositorio PRIVADO, y una maquina recien instalada
# no tiene ninguna llave. `provision.sh` genera la suya y clona — pero
# para generarla ya tiene que estar ahi.
#
# Hasta ahora eso se resolvia mandandole al ISP la carpeta `deploy/` por
# algun medio, lo que no estaba escrito en ninguna parte y convertia «una
# sola instruccion» en algo que no se podia alcanzar. Ahora la entrega
# tiene nombre y direccion.
#
# Aqui NO hay nada secreto: instala paquetes del sistema y clona un
# repositorio que sin llave no se abre.
#
# ── Y por que no se copia a mano al repositorio publico ──────────────
#
# Porque dos copias del mismo guion acaban diciendo cosas distintas:
# alguien corrige `provision.sh` aqui y el ISP sigue instalando con el de
# hace tres meses, sin que nada falle. Lo sube `publicar-version.sh`,
# junto con la version, para que no se pueda olvidar.
#
# Variables (las mismas que provision.sh):
#   APP_DOMAIN       por donde se entra al ERP          (obligatoria)
#   PUERTO_PUBLICO   el puerto publico, si hay NAT      (por omision 443)
#   ADMIN_EMAIL      correo del primer administrador y del certificado
#   PERFIL           `isp` (por omision) o `ecuatek`
#   PROXY_DELANTE    IP del proxy inverso que termina el TLS, si hay uno.
#                    Con esto, certbot no se intenta —el 80 llega al
#                    proxy, no aqui—, el ERP confia en esa IP para leer
#                    `X-Forwarded-For`, y nginx anota al visitante en vez
#                    del proxy. Vacio es el caso normal.

set -euo pipefail

[[ $EUID -eq 0 ]] || {
    echo "Hay que ejecutarlo como root. Con la linea de arriba:"
    echo "    curl -fsSL <url> | sudo APP_DOMAIN=... bash"
    exit 1
}

ORIGEN="${ORIGEN:-https://raw.githubusercontent.com/ecuatek/erp-isp-instalador/main}"

# ── Si el repositorio del instalador es PRIVADO ──────────────────────
#
# Entonces hace falta un token de lectura, y la instruccion lo lleva
# dentro:
#
#   curl -fsSL -H "Authorization: token <TOKEN>" <url>/instalar.sh \
#     | sudo INSTALADOR_TOKEN=<TOKEN> APP_DOMAIN=... bash
#
# Va DOS veces a proposito: la primera la usa el `curl` de fuera para
# traer este guion, y la segunda es la que este necesita para traer los
# otros dos. Una sola no alcanza a las dos mitades.
#
# Con el repositorio publico no se pone nada y la instruccion queda
# limpia. Lo que hay dentro son dos guiones que instalan paquetes de
# Ubuntu y clonan un repositorio que sin llave no se abre: no hay
# credenciales ni logica del negocio.
#
# Y si se usa token, que se sepa lo que cuesta: caduca, hay que rotarlo,
# y queda en el historial de la terminal y a la vista en `ps` mientras
# corre.
CABECERA=()

if [[ -n "${INSTALADOR_TOKEN:-}" ]]; then
    CABECERA=(-H "Authorization: token ${INSTALADOR_TOKEN}")
fi

# Los dos guiones tienen que caer JUNTOS: `provision.sh` invoca a
# `afinar-postgres.sh` desde su propio directorio.
CARPETA="$(mktemp -d /tmp/erp-isp-instalador.XXXXXX)"
trap 'rm -rf "$CARPETA"' EXIT

echo "==> Trayendo el instalador"

for GUION in provision.sh afinar-postgres.sh; do
    if ! curl -fsSL "${CABECERA[@]}" "${ORIGEN}/${GUION}" -o "${CARPETA}/${GUION}"; then
        echo "!!! No se pudo descargar ${GUION} de ${ORIGEN}"

        if [[ -z "${INSTALADOR_TOKEN:-}" ]]; then
            echo "    Si el repositorio del instalador es privado, falta el token:"
            echo "      ... | sudo INSTALADOR_TOKEN=<token> APP_DOMAIN=... bash"
        else
            echo "    Compruebe que el token siga vigente y tenga lectura del repositorio."
        fi

        echo "    Y que esta maquina tenga salida a internet."
        exit 1
    fi

    # ── Se comprueba lo DESCARGADO, no que curl no fallara ───────────
    #
    # Un proxy corporativo o un portal cautivo contestan 200 con una
    # pagina HTML, y `curl -f` la da por buena. Entonces `bash` ejecuta
    # un documento web: los errores que produce no se parecen a nada y
    # mandan a buscar muy lejos.
    if ! head -1 "${CARPETA}/${GUION}" | grep -q '^#!/usr/bin/env bash'; then
        echo "!!! Lo descargado como ${GUION} no es un guion de shell."
        echo "    Suele ser un proxy o un portal cautivo contestando por el."
        exit 1
    fi

    echo "    ${GUION}"
done

echo

# ── Ni `exec`, ni el stdin de la tuberia ─────────────────────────────
#
# `exec` reemplaza el proceso, asi que el `trap` de limpieza NO se
# ejecuta y la carpeta temporal se queda. Y este guion llega por una
# tuberia: dejarle ese stdin a `provision.sh` significa que cualquier
# cosa que intente leer de la entrada recibe lo que sobro del `curl`,
# que es un final de archivo — o peor, medio guion.
#
# El codigo de salida se propaga porque es lo que distingue «hay que dar
# de alta la llave» de «termino».
bash "${CARPETA}/provision.sh" < /dev/null
