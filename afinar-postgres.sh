#!/usr/bin/env bash
#
# ERP-ISP · Afinado de PostgreSQL
#
#   sudo bash deploy/afinar-postgres.sh
#
# Escribe `conf.d/erp-isp.conf` segun la memoria de la maquina y reinicia
# PostgreSQL. **No hace nada mas**: ni instala paquetes, ni crea usuarios,
# ni toca nginx, ni el cortafuegos.
#
# ── Por que existe separado de provision.sh ──────────────────────────
# `provision.sh` esta pensado para un servidor RECIEN INSTALADO y se corre
# una vez. En una maquina que ya trabaja —la de build, o un ISP al que hay
# que reafinar porque le subieron la RAM— correrlo entero es un riesgo que
# no hace falta correr: pisaria configuracion viva para cambiar quince
# lineas.
#
# ── Y por que provision.sh lo INVOCA en vez de tener su copia ────────
# Porque el mismo afinado en dos archivos acaba diciendo cosas distintas:
# alguien sube `work_mem` aqui y el servidor nuevo sigue naciendo con el
# viejo, sin que nada falle. Un solo sitio, dos formas de llamarlo.
#
# Variables, todas opcionales:
#   PG_VERSION  version de PostgreSQL          (por omision: la instalada)
#   DISCO       `ssd` o `mecanico`             (por omision: ssd)
#   RAM_MB      memoria a repartir             (por omision: la detectada)

set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "Ejecutar como root: sudo bash $0"; exit 1; }

# ── Parametros ────────────────────────────────────────────────────────

RAM_MB="${RAM_MB:-$(free -m | awk '/^Mem:/{print $2}')}"

# La version instalada, para no clavarla: un ISP puede ir por delante.
if [[ -z "${PG_VERSION:-}" ]]; then
    PG_VERSION="$(ls -1 /etc/postgresql 2>/dev/null | sort -V | tail -1)"
fi

[[ -n "$PG_VERSION" ]] || { echo "No encuentro PostgreSQL en /etc/postgresql"; exit 1; }

DESTINO="/etc/postgresql/${PG_VERSION}/main/conf.d"

[[ -d "$DESTINO" ]] || { echo "No existe $DESTINO"; exit 1; }

# Con que disco corre la base: `ssd` o `mecanico`.
#
# Decide `random_page_cost`, que es lo que el planificador usa para elegir
# entre recorrer la tabla entera o entrar por un indice. Con el valor de
# disco mecanico (4) **prefiere el recorrido completo**, y a 100.000
# abonados esa es la decision equivocada: explica indices que estan y no
# sirven.
#
# NO se detecta. `lsblk ROTA` miente en una maquina virtual —que es donde
# corre casi todo ISP— y sobre LVM. Una deteccion que acierta por
# accidente es peor que una eleccion explicita.
DISCO="${DISCO:-ssd}"

# El costo de una lectura aleatoria frente a una secuencial, y cuantas
# lecturas puede pedir a la vez. En un SSD la diferencia entre las dos es
# minima; el valor de fabrica (4) describe un disco que tiene que mover un
# cabezal.
if [[ "$DISCO" == "mecanico" ]]; then
    COSTO_ALEATORIO="4"
    LECTURAS_A_LA_VEZ="2"
else
    COSTO_ALEATORIO="1.1"
    LECTURAS_A_LA_VEZ="200"
fi

echo "==> PostgreSQL ${PG_VERSION} · ${RAM_MB} MB de RAM · disco ${DISCO}"

# ── Lo que habia antes ────────────────────────────────────────────────
# Se guarda con fecha: un afinado que no se puede deshacer obliga a
# recordar los valores anteriores, y nadie los recuerda.

if [[ -f "${DESTINO}/erp-isp.conf" ]]; then
    RESPALDO="${DESTINO}/erp-isp.conf.$(date +%Y%m%d%H%M%S).bak"
    cp "${DESTINO}/erp-isp.conf" "$RESPALDO"
    echo "    lo anterior queda en $(basename "$RESPALDO")"
fi

# Debian y Ubuntu incluyen conf.d desde postgresql.conf, asi que estos
# valores sobreviven a las actualizaciones del paquete.
cat > "${DESTINO}/erp-isp.conf" <<CONF
# Generado por deploy/afinar-postgres.sh · $(date +%Y-%m-%d)
# Ajustar si cambia la memoria de la maquina.

shared_buffers = $(( RAM_MB / 4 ))MB
effective_cache_size = $(( RAM_MB * 60 / 100 ))MB

# OJO al par de abajo: \`work_mem\` es por OPERACION, no por conexion, asi
# que una consulta con tres ordenamientos usa tres veces esto. Con 200
# conexiones el peor caso teorico son 19 GB. No aprieta hoy porque el ERP
# no abre 200 —unos 56 trabajadores de PHP-FPM en 16 GB, mas los de la
# cola— y las consultas de pantalla ordenan poco; los informes pesados son
# los que habria que subir de uno en uno con \`SET LOCAL\`, no a todos.
work_mem = 32MB
maintenance_work_mem = $(( RAM_MB / 16 ))MB

max_connections = 200

wal_compression = on
checkpoint_timeout = 15min
max_wal_size = 8GB

# Disco declarado: ${DISCO}
random_page_cost = ${COSTO_ALEATORIO}
effective_io_concurrency = ${LECTURAS_A_LA_VEZ}

# El compilador JIT ayuda a una consulta analitica que dura segundos y
# estorba a las miles de consultas cortas que hace un ERP: compilar cuesta
# mas que ejecutar. Se apaga para el trabajo interactivo.
jit = off

# El accounting de RADIUS genera muchas filas muertas por los interim
# updates: autovacuum tiene que ir mas seguido que por defecto.
autovacuum_vacuum_scale_factor = 0.05
autovacuum_analyze_scale_factor = 0.02
CONF

# ── Comprobar ANTES de reiniciar ──────────────────────────────────────
# Un valor mal escrito deja a PostgreSQL sin arrancar, y con el se cae el
# ERP entero. `postgres -C` lee la configuracion sin levantar el servicio.

if ! sudo -u postgres /usr/lib/postgresql/${PG_VERSION}/bin/postgres \
        -C shared_buffers -D "/etc/postgresql/${PG_VERSION}/main" >/dev/null 2>&1; then
    echo "!!! La configuracion nueva no se puede leer. NO se reinicia."
    if [[ -n "${RESPALDO:-}" ]]; then
        cp "$RESPALDO" "${DESTINO}/erp-isp.conf"
        echo "    se restauro la anterior."
    else
        rm -f "${DESTINO}/erp-isp.conf"
        echo "    se quito el archivo nuevo."
    fi
    exit 1
fi

# ── Reiniciar SOLO el cluster afinado ─────────────────────────────────
# `systemctl restart postgresql` reinicia TODOS los que haya instalados.
# En una maquina con dos versiones conviviendo eso tira abajo una que
# nadie pidio tocar, y con ella lo que dependa de ella.

echo "==> Reiniciando PostgreSQL ${PG_VERSION}"
systemctl restart "postgresql@${PG_VERSION}-main"

sleep 2

# ── Comprobar el EFECTO, y contra el cluster QUE SE AFINO ─────────────
#
# `psql` sin puerto va al cluster POR OMISION, que no tiene por que ser
# este: con una 14 y una 17 conviviendo, la primera version de esta
# comprobacion leyo la 14 —a la que nadie toco— y dijo «Listo» con los
# valores de fabrica mientras la 17 estaba perfectamente afinada.
#
# Y no basta con imprimirlos: hay que COMPARARLOS con lo que se escribio.
# Un listado que el operador tiene que leer y juzgar no es una
# comprobacion, es un informe.

# ── Solo los DIGITOS, y por que ──────────────────────────────────────
#
# Esto era `awk -F'[ =]+'`, que separa por espacios y por igual pero **no
# por tabuladores** — y la linea de un `postgresql.conf` recien instalado
# es literalmente:
#
#     port = 5432\t\t\t\t# (change requires restart)
#
# Asi que el puerto salia como «5432<tabs>#» y el `psql -p` de abajo
# fallaba siempre, con un mensaje que decia «PostgreSQL no responde en el
# puerto 5432                #» y mandaba a mirar el journal de un
# servicio que estaba perfectamente.
#
# No se noto al escribirlo porque en la maquina de build conviven dos
# versiones y el puerto se pasa siempre a mano; en una instalacion limpia
# —la de CADA ISP— corta el aprovisionamiento en seco.
#
# `sed` con `\([0-9]\+\)` se queda con el numero y con nada mas: da
# igual si lo que sigue son espacios, tabuladores o un comentario.
PUERTO="$(sed -n 's/^[[:space:]]*port[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' \
    "/etc/postgresql/${PG_VERSION}/main/postgresql.conf" 2>/dev/null | head -1)"
PUERTO="${PUERTO:-5432}"

consultar() {
    sudo -u postgres psql -p "$PUERTO" -tAc "SHOW $1" 2>/dev/null | tr -d '[:space:]'
}

if [[ -z "$(consultar 'server_version')" ]]; then
    echo "!!! PostgreSQL ${PG_VERSION} no responde en el puerto ${PUERTO}. Revise:"
    echo "    journalctl -u postgresql@${PG_VERSION}-main -n 50"
    exit 1
fi

echo
echo "    cluster ${PG_VERSION}, puerto ${PUERTO}"

DISTINTOS=0

# ── Los tamaños se comparan en BYTES ──────────────────────────────────
# PostgreSQL normaliza la unidad al contestar: con 16 GB de RAM,
# `shared_buffers` sale como «4GB» y no como «4096MB». Comparar el texto
# daria una falsa alarma justo en la maquina mas comun, y una guarda que
# grita sin motivo se acaba ignorando. `pg_size_bytes` deja los dos lados
# en la misma unidad.
comparar_tamano() {
    local AJUSTE="$1" QUIERO="$2"
    local IGUALES

    IGUALES="$(sudo -u postgres psql -p "$PUERTO" -tAc \
        "SELECT pg_size_bytes(current_setting('${AJUSTE}')) = pg_size_bytes('${QUIERO}')" \
        2>/dev/null | tr -d '[:space:]')"

    if [[ "$IGUALES" == "t" ]]; then
        printf '    %-26s %s\n' "$AJUSTE" "$(consultar "$AJUSTE")"
    else
        printf '    %-26s %s   <-- se escribio %s\n' "$AJUSTE" "$(consultar "$AJUSTE")" "$QUIERO"
        DISTINTOS=$((DISTINTOS + 1))
    fi
}

comparar_valor() {
    local AJUSTE="$1" QUIERO="$2" TIENE
    TIENE="$(consultar "$AJUSTE")"

    if [[ "$TIENE" == "$QUIERO" ]]; then
        printf '    %-26s %s\n' "$AJUSTE" "$TIENE"
    else
        printf '    %-26s %s   <-- se escribio %s\n' "$AJUSTE" "$TIENE" "$QUIERO"
        DISTINTOS=$((DISTINTOS + 1))
    fi
}

comparar_tamano shared_buffers       "$(( RAM_MB / 4 ))MB"
comparar_tamano effective_cache_size "$(( RAM_MB * 60 / 100 ))MB"
comparar_tamano work_mem             "32MB"
comparar_tamano max_wal_size         "8GB"

comparar_valor random_page_cost         "$COSTO_ALEATORIO"
comparar_valor effective_io_concurrency "$LECTURAS_A_LA_VEZ"
comparar_valor jit                      "off"

REVISADOS=7

if [[ $DISTINTOS -gt 0 ]]; then
    echo
    echo "!!! ${DISTINTOS} ajuste(s) no quedaron aplicados."
    echo "    Lo habitual es que postgresql.conf no incluya conf.d:"
    echo "    grep -n \"include_dir\" /etc/postgresql/${PG_VERSION}/main/postgresql.conf"
    exit 1
fi

echo
echo "Listo: los ${REVISADOS} ajustes comprobados estan aplicados."
