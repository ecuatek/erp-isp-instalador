#!/usr/bin/env bash
#
# ERP-ISP · Aprovisionamiento de un servidor nuevo
#
# Se ejecuta UNA VEZ sobre Ubuntu 24.04 LTS recien instalado, como root.
# Deja la maquina lista para recibir el primer despliegue.
#
#   sudo bash provision.sh
#
# Es idempotente: volver a ejecutarlo no rompe nada, aunque tampoco hace
# falta. Si algo falla a mitad de camino, se corrige y se vuelve a correr.
#
# Lo que NO hace, a proposito: configurar FreeRADIUS contra la base, cargar
# los clientes NAS y emitir el certificado TLS. Esos tres pasos dependen de
# datos del ISP y estan documentados en docs/INSTALACION.md.

set -euo pipefail

# ── Parametros ────────────────────────────────────────────────────────
# Lo unico que hay que ajustar antes de ejecutar.

APP_USER="${APP_USER:-erpisp}"
APP_DIR="${APP_DIR:-/var/www/erp-isp}"
APP_DOMAIN="${APP_DOMAIN:-erp.ejemplo.com}"
# De donde sale el codigo, y son DOS repositorios distintos.
#
# El ISP clona `erp-isp-dist`: la copia limpia, con historia propia de un
# commit por version. No clona el repositorio de trabajo porque `git
# clone` no entrega «el ERP» sino el repositorio ENTERO, con su `.git`
# dentro —todas las versiones de todos los archivos—, y entonces borrar
# del arbol lo que no debe viajar no sirve de nada.
#
# La instalacion de la PROPIA Ecuatek si necesita el completo: es la que
# emite las licencias y cobra los planes.
#
#   PERFIL=ecuatek sudo bash provision.sh
PERFIL="${PERFIL:-isp}"

# ── El puerto por el que se ENTRA, que no es el que escucha nginx ────
#
# Con un NAT delante, el ISP publica el 19943 y nginx escucha el 443. Ese
# numero tiene que estar en `APP_URL` **antes** del primer `npm run
# build`: los valores `VITE_*` se hornean dentro del JavaScript, asi que
# corregirlo despues obliga a recompilar y, mientras tanto, el WebSocket
# del chat marca a un puerto que no existe.
#
# 443 significa «sin puerto en la URL», que es el caso normal.
PUERTO_PUBLICO="${PUERTO_PUBLICO:-443}"

# ── Lo que hace falta para terminar SIN pasos a mano ────────────────
#
# Con estos dos, el guion clona, escribe el `.env`, despliega, emite el
# certificado, configura FreeRADIUS y crea el primer administrador. Sin
# ellos hace todo lo que puede y **dice exactamente que queda**: son
# datos del ISP, no valores que se puedan inventar.
ADMIN_EMAIL="${ADMIN_EMAIL:-}"
ADMIN_NOMBRE="${ADMIN_NOMBRE:-Administrador}"

# ── El correo del certificado NO es el del administrador ─────────────
#
# `ADMIN_EMAIL` es la persona del ISP que va a entrar al ERP. Los avisos
# de Let's Encrypt —«su certificado caduca en diez dias»— los quiere
# normalmente quien OPERA la plataforma, que es otra: si el ERP deja de
# renovar, el ISP se entera cuando el navegador deja de abrir.
#
# Son dos cosas y se deciden por separado, como el telefono de la ficha y
# el del canal de WhatsApp. Por omision el del ISP, que es mejor que
# ninguno.
CERTBOT_EMAIL="${CERTBOT_EMAIL:-$ADMIN_EMAIL}"

# ── Y si hay un proxy inverso delante ────────────────────────────────
#
# Las IP del proxy que termina el TLS y reenvia por HTTP, separadas por
# comas. Vacio —lo normal— significa que esta maquina habla directo con
# internet y nada de lo de abajo cambia.
#
# ── Por que UN parametro y no tres ─────────────────────────────────
# Porque «hay un proxy delante» no es una preferencia: es una forma de
# despliegue, y cambia tres cosas a la vez que antes habia que acertar
# por separado:
#
#   - **certbot no puede emitir** desde aqui: el 80 no llega a esta
#     maquina, llega al proxy. Se intentaba igual y fallaba.
#   - **`TRUSTED_PROXIES` tiene que llevar su IP**, o todas las
#     peticiones parecen venir de el y el tope por IP del login y del
#     endpoint de licencia castiga a todos los ISP a la vez.
#   - **nginx tiene que creerse `X-Forwarded-For`**, o su registro anota
#     el proxy en vez del visitante y deja de servir para diagnosticar.
#
# Las tres se olvidan por separado y ninguna falla de forma visible, que
# es exactamente la clase de hueco que un parametro cierra y tres no.
PROXY_DELANTE="${PROXY_DELANTE:-}"

# El TLS lo pone el proxy, asi que certbot aqui no tiene nada que hacer.
#
# Se fuerza en vez de dejarlo a quien ejecuta porque `${CERTBOT_EMAIL:-...}`
# cae al correo del administrador tambien con la cadena VACIA —`:-` no
# distingue «sin definir» de «definido en vacio»—, asi que pedir el
# administrador y saltar certbot era imposible de expresar.
if [[ -n "$PROXY_DELANTE" ]]; then
    CERTBOT_EMAIL=""
fi

if [[ "$PERFIL" == "ecuatek" ]]; then
    REPO_URL="${REPO_URL:-git@github.com:ecuatek/erp-isp.git}"
else
    REPO_URL="${REPO_URL:-git@github.com:ecuatek/erp-isp-dist.git}"
fi

DB_NAME="${DB_NAME:-radius}"
DB_USER="${DB_USER:-erpisp}"

# Con que disco corre la base: `ssd` o `mecanico`.
#
# Se pasa tal cual a `afinar-postgres.sh`, que es donde vive el valor por
# omision y la explicacion de por que no se detecta. Poner aqui otro
# defecto seria un segundo sitio donde decidir lo mismo.
DISCO="${DISCO:-}"

PHP_VERSION="8.3"
PG_VERSION="17"
NODE_VERSION="22"

# ── Comprobaciones previas ────────────────────────────────────────────

[[ $EUID -eq 0 ]] || { echo "Ejecutar como root: sudo bash $0"; exit 1; }

# ── El instalador es la CARPETA, no este archivo ──────────────────────
#
# `provision.sh` invoca a `afinar-postgres.sh` desde su propio directorio,
# porque el afinado de PostgreSQL vive en un solo sitio y tambien hay que
# poder correrlo suelto sobre una maquina que ya trabaja.
#
# Quien instala un ISP nuevo tiene una maquina limpia y todavia NO tiene
# el repositorio —eso lo clona este guion—, asi que es natural copiar un
# solo archivo. Y entonces esto moria a mitad del aprovisionamiento con un
# «No such file or directory» que no dice que falta ni de donde sacarlo,
# dejando la maquina con PostgreSQL instalado y sin afinar.
#
# Se comprueba al principio: lo que va a faltar se dice ANTES de empezar,
# no a los tres minutos.
AQUI="$(cd "$(dirname "$0")" && pwd)"

for COMPANERO in afinar-postgres.sh; do
    [[ -f "${AQUI}/${COMPANERO}" ]] && continue

    echo "Falta ${COMPANERO}, que este guion necesita a su lado."
    echo
    echo "El instalador es la carpeta deploy/ entera, no un archivo suelto."
    echo "Copiela completa y vuelva a ejecutar:"
    echo "    sudo bash <ruta>/deploy/provision.sh"
    exit 1
done

VERSION_UBUNTU="$(lsb_release -rs 2>/dev/null || echo desconocida)"
if [[ "$VERSION_UBUNTU" != "24.04" ]]; then
    echo "AVISO: este guion se probo en Ubuntu 24.04 y aqui hay $VERSION_UBUNTU."
    read -rp "Continuar de todas formas? [s/N] " respuesta
    [[ "$respuesta" == "s" ]] || exit 1
fi

RAM_MB="$(free -m | awk '/^Mem:/{print $2}')"
echo "==> Memoria detectada: ${RAM_MB} MB"

export DEBIAN_FRONTEND=noninteractive

# ── Repositorios ──────────────────────────────────────────────────────
# Las versiones que trae Ubuntu por defecto no siempre son las que este
# proyecto necesita, y cambiar de version mayor despues es mucho mas caro
# que agregar un repositorio ahora.

echo "==> Paquetes base"
apt-get update -qq
apt-get install -y -qq \
    ca-certificates curl gnupg lsb-release software-properties-common \
    git unzip acl ufw fail2ban

install -d -m 0755 /etc/apt/keyrings

echo "==> Repositorio de PHP ${PHP_VERSION}"
add-apt-repository -y ppa:ondrej/php >/dev/null

echo "==> Repositorio de PostgreSQL ${PG_VERSION}"
if [[ ! -f /etc/apt/keyrings/postgresql.gpg ]]; then
    curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
        | gpg --dearmor -o /etc/apt/keyrings/postgresql.gpg
    echo "deb [signed-by=/etc/apt/keyrings/postgresql.gpg] http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" \
        > /etc/apt/sources.list.d/pgdg.list
fi

echo "==> Repositorio de Node ${NODE_VERSION}"
if [[ ! -f /etc/apt/keyrings/nodesource.gpg ]]; then
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
        | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg
    echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_VERSION}.x nodistro main" \
        > /etc/apt/sources.list.d/nodesource.list
fi

echo "==> Repositorio de Docker"
# Solo para el puente de WhatsApp. Cuando se pase a la API oficial de Meta,
# Docker deja de hacer falta en este servidor.
if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    echo "deb [signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
        > /etc/apt/sources.list.d/docker.list
fi

apt-get update -qq

# ── Instalacion ───────────────────────────────────────────────────────

echo "==> PHP ${PHP_VERSION} y extensiones"
# pgsql: la base. redis: cache y colas. bcmath: importes sin errores de
# redondeo. gd: imagenes de los adjuntos del chat. soap y xml: haran falta
# para la facturacion electronica del SRI.
apt-get install -y -qq \
    php${PHP_VERSION}-cli php${PHP_VERSION}-fpm php${PHP_VERSION}-pgsql \
    php${PHP_VERSION}-redis php${PHP_VERSION}-mbstring php${PHP_VERSION}-xml \
    php${PHP_VERSION}-curl php${PHP_VERSION}-zip php${PHP_VERSION}-gd \
    php${PHP_VERSION}-bcmath php${PHP_VERSION}-intl php${PHP_VERSION}-soap \
    php${PHP_VERSION}-opcache

echo "==> PostgreSQL ${PG_VERSION}"
apt-get install -y -qq postgresql-${PG_VERSION} postgresql-client-${PG_VERSION}

echo "==> Redis, nginx, Node, FreeRADIUS, Docker"
apt-get install -y -qq redis-server nginx nodejs \
    freeradius freeradius-postgresql freeradius-utils \
    docker-ce docker-ce-cli containerd.io docker-compose-plugin \
    certbot python3-certbot-nginx

echo "==> Composer"
if [[ ! -x /usr/local/bin/composer ]]; then
    curl -fsSL https://getcomposer.org/installer -o /tmp/composer-setup.php
    php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer
    rm -f /tmp/composer-setup.php
fi

# ── Usuario de la aplicacion ──────────────────────────────────────────
# La aplicacion no corre como root ni como el usuario con el que uno entra
# por SSH: si alguien encuentra un agujero en el ERP, lo que alcanza es
# solo lo que este usuario puede tocar.

echo "==> Usuario ${APP_USER}"
id -u "$APP_USER" &>/dev/null || useradd -m -s /bin/bash "$APP_USER"
usermod -aG docker "$APP_USER"

install -d -o "$APP_USER" -g "$APP_USER" "$(dirname "$APP_DIR")"

# ── Donde caen los respaldos ──────────────────────────────────────────
#
# `respaldo:ejecutar` corre cada hora y escribe en lo que diga
# `respaldo_ruta_local`, cuyo valor por omision es este. El directorio no
# lo creaba nadie, asi que la tarea mas importante de la maquina nacia
# apuntando a una carpeta que no existe.
#
# Se crea AQUI y no al primer respaldo, porque crearlo sobre la marcha lo
# dejaria con el dueño de quien corriera primero — que es la trampa 23,
# la misma que dejo la sonda de disco sin poder escribir para siempre.
#
# **Es un punto de montaje en potencia.** Un ISP con un disco aparte para
# respaldos lo monta aqui, y entonces el dueño lo decide el montaje: por
# eso se comprueba y se corrige el dueño aunque el directorio ya exista.
# Un respaldo que no se puede escribir es el unico fallo que no se nota
# hasta que hace falta.
install -d -o "$APP_USER" -g "$APP_USER" -m 0750 /var/respaldos

# ── Y donde caen los ADJUNTOS ─────────────────────────────────────────
#
# El disco `adjuntos` del ERP apunta a `/data_erp/adjuntos`, y **no lo
# creaba nadie**. Ese disco lleva `'throw' => false`, asi que
# `Storage::put()` devuelve FALSO en vez de fallar (trampa 24): la
# primera foto que un tecnico suba desde el domicilio del cliente se
# pierde sin un solo error, y el ERP guarda la fila que la nombra.
#
# Se descubre semanas despues, abriendo una orden vieja para un reclamo.
#
# Va aqui por lo mismo que los respaldos: crearlo sobre la marcha lo
# dejaria con el dueño de quien escriba primero —la trampa 23— y ademas
# ni eso funciona, porque `/data_erp` es de root y el proceso web no
# puede crear dentro.
#
# **Es un punto de montaje en potencia**, y el mas probable de los dos:
# con 20.000 instalaciones son decenas de GB de fotos. Un ISP que monte
# un disco aparte lo hace aqui, y entonces el dueño lo decide el montaje,
# asi que se corrige aunque el directorio ya exista.
install -d -o "$APP_USER" -g "$APP_USER" -m 0750 /data_erp
install -d -o "$APP_USER" -g "$APP_USER" -m 0750 /data_erp/adjuntos

# ── Base de datos ─────────────────────────────────────────────────────

echo "==> Base de datos ${DB_NAME}"

DB_PASS_FILE="/root/.erp-isp-db-password"

if [[ ! -f "$DB_PASS_FILE" ]]; then
    # Generada aqui y guardada solo para root: una contrasena escrita en el
    # guion terminaria en el repositorio tarde o temprano.
    openssl rand -base64 32 | tr -d '/+=' | head -c 32 > "$DB_PASS_FILE"
    chmod 600 "$DB_PASS_FILE"
fi
DB_PASS="$(cat "$DB_PASS_FILE")"

EXISTE_ROL="$(sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='${DB_USER}'")"
if [[ "$EXISTE_ROL" != "1" ]]; then
    sudo -u postgres psql -c "CREATE ROLE ${DB_USER} LOGIN PASSWORD '${DB_PASS}'"
fi

EXISTE_BASE="$(sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'")"
if [[ "$EXISTE_BASE" != "1" ]]; then
    sudo -u postgres createdb -O "${DB_USER}" "${DB_NAME}"
fi

echo "==> Ajustes de PostgreSQL"
# El afinado vive en UN solo sitio y aqui se invoca.
#
# Tenerlo copiado aqui y en `afinar-postgres.sh` acabaria en dos versiones
# que dicen cosas distintas: alguien sube `work_mem` en una y el servidor
# nuevo sigue naciendo con la vieja, sin que nada falle. Y hace falta por
# separado porque a una maquina que ya trabaja no se le corre este guion
# entero para cambiar quince lineas de configuracion.
RAM_MB="$RAM_MB" PG_VERSION="$PG_VERSION" DISCO="$DISCO" \
    bash "$(dirname "$0")/afinar-postgres.sh"

echo "==> Redis"
# noeviction, no allkeys-lru, y la razon importa: en esta instalacion Redis
# guarda la cache Y las colas. Con una politica que expulsa claves cuando
# falta memoria, lo que se pierde puede ser un trabajo encolado — una
# suspension que nunca se aplica, un recibo que nunca se envia.
#
# Si la memoria llega a apretar, la solucion es una segunda instancia de
# Redis para la cache, no expulsar claves de la cola.
sed -i "s/^# *maxmemory .*/maxmemory $(( RAM_MB * 15 / 100 ))mb/" /etc/redis/redis.conf
sed -i "s/^# *maxmemory-policy .*/maxmemory-policy noeviction/" /etc/redis/redis.conf
grep -q "^maxmemory " /etc/redis/redis.conf || echo "maxmemory $(( RAM_MB * 15 / 100 ))mb" >> /etc/redis/redis.conf
grep -q "^maxmemory-policy " /etc/redis/redis.conf || echo "maxmemory-policy noeviction" >> /etc/redis/redis.conf
systemctl restart redis-server

# ── PHP-FPM ───────────────────────────────────────────────────────────

echo "==> PHP-FPM"
# Cada trabajador ocupa del orden de 100 MB. Se reserva un 35% de la
# memoria para ellos: el resto es para PostgreSQL, Redis, Horizon y el
# sistema. Sin este limite, un pico de trafico levanta trabajadores hasta
# agotar la memoria y el sistema empieza a usar swap, que es peor que
# rechazar peticiones.
MAX_CHILDREN=$(( RAM_MB * 35 / 100 / 100 ))
(( MAX_CHILDREN < 10 )) && MAX_CHILDREN=10

POOL="/etc/php/${PHP_VERSION}/fpm/pool.d/www.conf"

# ── Quien EJECUTA el PHP tiene que ser el dueño de los archivos ───────
#
# El pool de fabrica corre como `www-data`, y todo el ERP es de
# ${APP_USER}: el clon, `composer install`, Horizon, Reverb y el
# planificador. Con los dos usuarios distintos, el proceso web puede LEER
# —los directorios son 775— pero **no puede escribir nada**.
#
# Y eso no se nota al instalar, que es lo peor que tiene. `deploy.sh`
# termina con `artisan optimize`, que deja la configuracion, las rutas y
# las vistas ya compiladas por ${APP_USER}; el servidor web solo tiene que
# leerlas y el ERP funciona. Lo que revienta es lo que llegue DESPUES:
#
#   - limpiar la cache (`config:clear`) obliga a leer el `.env` y a
#     recompilar las vistas, y ahi el 500 es inmediato;
#   - una sesion en archivo, un logo, un certificado del SRI, un contrato
#     firmado, un PDF: todo lo que el operador SUBE;
#   - y un archivo que si consiga escribir queda de `www-data`, asi que
#     **la cola ya no puede tocarlo** — el fallo cambia de sitio.
#
# Sobre todo: **el error no se puede registrar**, porque el log tambien es
# suyo. Un 500 con `laravel.log` en cero manda a buscar a cualquier parte
# menos aqui. Paso en la primera instalacion real, el 22/9/2026.
#
# `listen.owner` y `listen.group` NO se tocan: ese es el socket por el que
# habla nginx, que si corre como `www-data`.
sed -i "s/^user = .*/user = ${APP_USER}/" "$POOL"
sed -i "s/^group = .*/group = ${APP_USER}/" "$POOL"

sed -i "s/^pm = .*/pm = dynamic/" "$POOL"
sed -i "s/^pm.max_children = .*/pm.max_children = ${MAX_CHILDREN}/" "$POOL"
sed -i "s/^pm.start_servers = .*/pm.start_servers = $(( MAX_CHILDREN / 4 ))/" "$POOL"
sed -i "s/^pm.min_spare_servers = .*/pm.min_spare_servers = $(( MAX_CHILDREN / 8 ))/" "$POOL"
sed -i "s/^pm.max_spare_servers = .*/pm.max_spare_servers = $(( MAX_CHILDREN / 2 ))/" "$POOL"

cat > /etc/php/${PHP_VERSION}/fpm/conf.d/99-erp-isp.ini <<'INI'
; Generado por provision.sh

memory_limit = 512M
upload_max_filesize = 32M
post_max_size = 32M
max_execution_time = 120

; OPcache: sin esto PHP recompila cada archivo en cada peticion.
opcache.enable = 1
opcache.memory_consumption = 256
opcache.max_accelerated_files = 20000
opcache.validate_timestamps = 0
INI

# validate_timestamps = 0 hace que PHP no revise si los archivos cambiaron:
# mas rapido, pero exige recargar php-fpm en cada despliegue. deploy.sh lo
# hace. Es la trampa que costo media hora el 6 de agosto de 2026.

systemctl restart php${PHP_VERSION}-fpm

# ── Comprobar el EFECTO, no que el `sed` no fallara ───────────────────
#
# Un `sed` que no casa con ninguna linea sale con exito. Si el pool de una
# version futura escribe `user=www-data` sin espacios, el cambio de arriba
# no haria nada y el aprovisionamiento seguiria diciendo «listo» — para
# que el 500 sin log aparezca semanas despues, en la maquina del cliente.
#
# Se mira el proceso que quedo corriendo, que es lo unico que no depende
# de como este escrito el archivo.
sleep 1
DUENO_FPM="$(ps -o user= -C "php-fpm${PHP_VERSION}" 2>/dev/null | sort -u | grep -v '^root$' | head -1)"

if [[ "$DUENO_FPM" != "$APP_USER" ]]; then
    echo "!!! PHP-FPM corre como '${DUENO_FPM:-desconocido}' y el ERP sera de ${APP_USER}."
    echo "    Asi el proceso web no puede escribir ni el log de sus propios errores."
    echo "    Revise 'user' y 'group' en ${POOL}"
    exit 1
fi

echo "    PHP-FPM corre como ${APP_USER}"

# ── nginx ─────────────────────────────────────────────────────────────

echo "==> nginx"

# ── Lo que certbot escribio NO se pisa ────────────────────────────────
#
# Esto era un `cat >` sin condicion, y el guion esta pensado para volver a
# ejecutarse. La segunda vez se llevaba por delante **todo lo que certbot
# habia añadido a este mismo archivo**: el `listen 443`, las rutas del
# certificado y la redireccion. El ERP se quedaba escuchando solo el 80,
# o sea inalcanzable por su direccion de siempre, y sin un solo error.
#
# Peor todavia si `APP_DOMAIN` no es el que ya estaba: el `server_name`
# pasa a ser otro, nginx deja de reconocer el dominio real y sirve el
# sitio por omision de la distribucion. Paso el 23/9/2026 al reejecutar
# el guion con el dominio de un EJEMPLO copiado.
#
# El certificado en si sobrevive —vive en /etc/letsencrypt— pero eso no
# consuela: lo que se pierde es la configuracion que lo usa, y la perdida
# es muda.
#
# Asi que el archivo se escribe una vez. Si ya esta, se comprueba que
# nombre sirve y **se avisa si no es el que se pidio**, en vez de
# corregirlo por las bravas: con un ERP en marcha, cambiar el
# `server_name` es una decision, no un efecto lateral de volver a correr
# el instalador.
# ── Lo que NO se hace: el `real_ip` de nginx ─────────────────────────
#
# Seria lo natural para que el registro de accesos anote al visitante y no
# al proxy, y se intento. **Rompe la aplicacion**, y asi:
#
#   `set_real_ip_from` + `real_ip_header X-Forwarded-For` reescriben
#   `REMOTE_ADDR` con la IP del CLIENTE antes de que PHP la vea. Entonces
#   la lista de confianza de Laravel —que espera ver la IP del PROXY— ya
#   no casa nunca, asi que **deja de creerse el `X-Forwarded-Proto`**: la
#   peticion se considera `http`, y los recursos de Vite salen con
#   `http://` en una pagina servida por `https`. El navegador bloquea el
#   contenido mixto, el JavaScript no carga, y con Inertia eso es una
#   **pagina en blanco**. Medido en ALTA-META el 11/10/2026: sin el
#   archivo los recursos salen `https`, con el archivo salen `http`.
#
# Y no hacia falta: **Laravel ya da la IP real del visitante**, porque lee
# `X-Forwarded-For` precisamente cuando `REMOTE_ADDR` es el proxy y casa
# con `TRUSTED_PROXIES`. Lo unico que el `real_ip` mejoraba era la linea
# del registro de nginx. Cambiar eso por una aplicacion que no arranca no
# es una mejora.
#
# Dos mecanismos correctos para el mismo problema se anulan — la trampa 49
# con otra cara: ahi eran dos optimizaciones que juntas abrian un agujero,
# aqui son dos formas de saber quien llama que juntas no saben ninguna.
PROXY_CONF="/etc/nginx/conf.d/erp-isp-proxy.conf"

if [[ -f "$PROXY_CONF" ]]; then
    # Se BORRA, no se deja: una instalacion que recibio la version con
    # `real_ip` se quedaria con la pagina en blanco para siempre, y el
    # sintoma no apunta a un archivo que nadie recuerda haber puesto.
    rm -f "$PROXY_CONF"
    echo "    ${PROXY_CONF} eliminado: rompia el esquema de las URL"
fi

SITIO="/etc/nginx/sites-available/erp-isp"

if [[ -f "$SITIO" ]]; then
    NOMBRE_ACTUAL="$(sed -n 's/^[[:space:]]*server_name[[:space:]]*\([^;]*\);.*/\1/p' "$SITIO" | head -1 | tr -d ' ')"

    if [[ "$NOMBRE_ACTUAL" == "$APP_DOMAIN" ]]; then
        echo "    ya configurado para ${APP_DOMAIN}, no se toca"
    else
        echo "!!! ${SITIO} responde por '${NOMBRE_ACTUAL}' y se pidio '${APP_DOMAIN}'."
        echo "    NO se reescribe: dentro puede estar la configuracion TLS que"
        echo "    puso certbot, y perderla deja el ERP inalcanzable sin ningun"
        echo "    error. Si el cambio de dominio es a proposito:"
        echo "      sudo rm ${SITIO} && vuelva a ejecutar este guion"
        echo "      sudo certbot --nginx -d ${APP_DOMAIN}"
        exit 1
    fi
else

cat > "$SITIO" <<NGINX
server {
    listen 80;
    server_name ${APP_DOMAIN};
    root ${APP_DIR}/public;

    index index.php;
    charset utf-8;

    client_max_body_size 32M;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    # Reverb: el navegador se conecta por el mismo dominio y nginx lo
    # pasa al puerto interno. Asi el 8090 no queda expuesto a internet.
    location /app {
        proxy_pass http://127.0.0.1:8090;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_read_timeout 3600s;
    }

    location ~ \.php\$ {
        fastcgi_pass unix:/run/php/php${PHP_VERSION}-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$realpath_root\$fastcgi_script_name;
        include fastcgi_params;
    }

    location ~ /\.(?!well-known).* { deny all; }

    access_log /var/log/nginx/erp-isp-access.log;
    error_log  /var/log/nginx/erp-isp-error.log;
}
NGINX

    echo "    ${SITIO} escrito para ${APP_DOMAIN}"
fi

ln -sf "$SITIO" /etc/nginx/sites-enabled/erp-isp
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl reload nginx

# ── Servicios de la aplicacion ────────────────────────────────────────

echo "==> Horizon y Reverb como servicios"

cat > /etc/systemd/system/horizon.service <<UNIT
[Unit]
Description=Laravel Horizon - procesador de trabajos en segundo plano
After=network.target postgresql.service redis-server.service

[Service]
Type=simple
User=${APP_USER}
Restart=always
RestartSec=3
ExecStart=/usr/bin/php${PHP_VERSION} ${APP_DIR}/artisan horizon
# Horizon termina ordenadamente: deja que los trabajos en curso acaben.
ExecStop=/usr/bin/php${PHP_VERSION} ${APP_DIR}/artisan horizon:terminate

[Install]
WantedBy=multi-user.target
UNIT

cat > /etc/systemd/system/reverb.service <<UNIT
[Unit]
Description=Laravel Reverb - WebSockets
After=network.target

[Service]
Type=simple
User=${APP_USER}
Restart=always
RestartSec=3
# El 8090 y no el 8080: nginx suele ocupar el 8080.
ExecStart=/usr/bin/php${PHP_VERSION} ${APP_DIR}/artisan reverb:start --host=127.0.0.1 --port=8090

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable horizon reverb >/dev/null

# Se habilitan pero no se arrancan: todavia no hay codigo desplegado.

# ── Permisos de despliegue ────────────────────────────────────────────
# deploy.sh corre como ${APP_USER} y necesita recargar servicios. En lugar
# de darle sudo completo, se le permiten solo esos comandos.

# ── Y FreeRADIUS, que es la regla que faltaba ────────────────────────
#
# El ERP reinicia FreeRADIUS solo cuando el operador cambia un NAS:
# FreeRADIUS lee los clientes de la base UNA VEZ al arrancar y responde
# al HUP con «No files changed», asi que sin reinicio el equipo nuevo no
# existe para el.
#
# `RadiusRecargaService` estaba escrito, con su pantalla y su mensaje de
# error — y esta regla nunca se concedio. El ERP contestaba «ejecuta en
# el servidor: sudo systemctl restart freeradius» en TODAS las
# instalaciones: todo construido menos la puerta.
#
# Son DOS comandos: `disponible()` prueba con `is-active` si el sudo
# funciona antes de intentar nada, asi que sin esa regla el ERP se
# declara incapaz sin haberlo intentado.
#
# ── Y aqui dentro NO van acentos graves ──────────────────────────────
#
# Este heredoc va SIN entrecomillar porque necesita expandir
# `${APP_USER}`, y entonces el shell lee los acentos graves como
# sustitucion de comandos. Estos mismos comentarios estaban dentro y el
# aprovisionamiento imprimia «RadiusRecargaService: command not found»
# tres veces — las reglas salian bien, pero un instalador que grita
# errores falsos enseña a ignorar los de verdad.
cat > /etc/sudoers.d/erp-isp-deploy <<SUDO
${APP_USER} ALL=(root) NOPASSWD: /usr/bin/systemctl reload php${PHP_VERSION}-fpm
${APP_USER} ALL=(root) NOPASSWD: /usr/bin/systemctl restart horizon
${APP_USER} ALL=(root) NOPASSWD: /usr/bin/systemctl restart reverb
${APP_USER} ALL=(root) NOPASSWD: /usr/bin/systemctl reload nginx

# El ERP reinicia FreeRADIUS al cambiar un NAS: los clientes se leen de
# la base una sola vez, al arrancar. Son dos reglas porque antes de
# reiniciar comprueba con is-active si puede.
${APP_USER} ALL=(root) NOPASSWD: /usr/bin/systemctl restart freeradius
${APP_USER} ALL=(root) NOPASSWD: /usr/bin/systemctl is-active freeradius
SUDO
chmod 440 /etc/sudoers.d/erp-isp-deploy

# ── Cortafuegos ───────────────────────────────────────────────────────

echo "==> Cortafuegos"
ufw allow OpenSSH >/dev/null
ufw allow 'Nginx Full' >/dev/null
# RADIUS NO se abre a todo internet: solo a los equipos del ISP. Los
# permisos concretos se agregan a mano, con la IP de cada BRAS:
#
#   ufw allow from <ip-del-bras> to any port 1812,1813 proto udp
#
ufw --force enable >/dev/null

# ── Tareas programadas ────────────────────────────────────────────────

echo "==> Planificador de Laravel"
CRON="* * * * * cd ${APP_DIR} && /usr/bin/php${PHP_VERSION} artisan schedule:run >> /dev/null 2>&1"

# ── Por que esto no es una linea sola ────────────────────────────────
#
# Lo era:
#
#   (crontab -l 2>/dev/null | grep -Fv "schedule:run"; echo "$CRON") | crontab -
#
# y con `set -e` mas `pipefail` hacia DOS cosas, las dos calladas:
#
#   1. `crontab -l` sale con codigo 1 cuando el usuario no tiene crontab
#      —o sea, SIEMPRE en una instalacion nueva—, asi que la subshell
#      moria antes del `echo` y se instalaba un crontab **vacio**;
#   2. y el guion entero se paraba ahi, sin llegar a imprimir el resumen
#      con la contrasena de la base y los pasos que faltan.
#
# Lo segundo lo delataba; lo primero no lo habria notado nadie: el ERP
# arranca, funciona, y falla SEMANAS despues, cuando se acaban las
# particiones creadas por adelantado. Sin cron no corre el nocturno, no
# se emiten los cargos del mes y no se crea ninguna particion.
#
# Ahora se lee lo que haya —o vacio— y se escribe aparte, sin tuberias
# que puedan tumbar el guion.
ACTUAL="$(crontab -u "$APP_USER" -l 2>/dev/null || true)"
NUEVO="$(printf '%s\n' "$ACTUAL" | grep -Fv "artisan schedule:run" || true)"

printf '%s\n%s\n' "$NUEVO" "$CRON" | sed '/^$/d' | crontab -u "$APP_USER" -

# ── Y se comprueba el EFECTO ─────────────────────────────────────────
#
# No que `crontab` no fallara: que la linea este. Es la unica pieza del
# sistema que no vive en el repositorio, y la unica cuya ausencia no se
# nota hasta que es tarde.
if crontab -u "$APP_USER" -l 2>/dev/null | grep -q "artisan schedule:run"; then
    echo "    planificador instalado para ${APP_USER}"
else
    echo "!!! El planificador NO quedo instalado en el crontab de ${APP_USER}."
    echo "    Sin el, el ERP arranca y funciona, y falla semanas despues:"
    echo "    no corre el nocturno, no se emiten los cargos del mes y no se"
    echo "    crea ninguna particion nueva."
    echo "    Instalelo a mano:  sudo crontab -u ${APP_USER} -e"
    echo "    ${CRON}"
    exit 1
fi

# ── Instalar el ERP ───────────────────────────────────────────────────
#
# Hasta aqui el guion dejaba la MAQUINA lista y una lista de seis pasos
# para hacer a mano. Eso no es una instalacion automatizada: es un manual
# ejecutable, y cada paso manual es un paso que alguna instalacion hara
# distinto — o no hara.
#
# Lo unico que de verdad necesita a una persona es dar de alta la llave en
# el repositorio, porque el permiso lo concede alguien con acceso a
# GitHub. Todo lo demas se hace aqui.
#
# Y es RE-EJECUTABLE: cada paso comprueba si ya esta hecho. Ese es el
# diseño que permite parar en la llave y continuar despues con el mismo
# comando, en vez de tener que acordarse de por donde iba.

echo "==> Instalando el ERP"

SSH_DIR="/home/${APP_USER}/.ssh"
LLAVE="${SSH_DIR}/id_ed25519"

install -d -o "$APP_USER" -g "$APP_USER" -m 0700 "$SSH_DIR"

if [[ ! -f "$LLAVE" ]]; then
    sudo -u "$APP_USER" ssh-keygen -q -t ed25519 -N '' \
        -C "${APP_USER}@$(hostname)" -f "$LLAVE"
    echo "    llave de despliegue generada"
fi

# Sin esto el primer `git clone` se queda esperando un «yes» que nadie va
# a teclear, y un aprovisionamiento desatendido se cuelga sin decir por
# que.
if ! sudo -u "$APP_USER" grep -q '^github.com' "${SSH_DIR}/known_hosts" 2>/dev/null; then
    sudo -u "$APP_USER" bash -c "ssh-keyscan github.com >> '${SSH_DIR}/known_hosts' 2>/dev/null"
fi

if [[ ! -d "$APP_DIR/.git" ]]; then
    if sudo -u "$APP_USER" git clone --quiet "$REPO_URL" "$APP_DIR"; then
        echo "    codigo clonado"
    else
        # La direccion de SSH no se puede abrir en un navegador, y este es
        # el UNICO momento en que el instalador le pide algo a una
        # persona: darle un `git@github.com:...` la obliga a traducirlo a
        # mano justo cuando lo que quiere es terminar.
        PANEL_LLAVES="${REPO_URL/git@github.com:/https://github.com/}"
        PANEL_LLAVES="${PANEL_LLAVES%.git}/settings/keys"

        cat <<LLAVE_FALTA

════════════════════════════════════════════════════════════════════
Falta un solo paso, y lo tiene que dar una persona con acceso al
repositorio: autorizar a esta maquina.

Agregue esta llave como DEPLOY KEY, sin marcar «Allow write
access» — el ISP solo lee:

    ${PANEL_LLAVES}

$(cat "${LLAVE}.pub")

Y vuelva a ejecutar este mismo guion. Lo que ya esta hecho no se
repite; continua desde aqui.
════════════════════════════════════════════════════════════════════
LLAVE_FALTA
        exit 1
    fi
fi

# ── El .env ───────────────────────────────────────────────────────────
#
# Se escribia a mano copiando `.env.example` y pegando la contraseña de un
# archivo. Cuatro valores que se pueden equivocar, y dos de ellos
# —`DB_PORT` y el puerto de `APP_URL`— no fallan de forma visible: el ERP
# arranca y algo deja de funcionar en otro sitio.

if [[ ! -f "$APP_DIR/.env" ]]; then
    if [[ "$PUERTO_PUBLICO" == "443" ]]; then
        APP_URL="https://${APP_DOMAIN}"
    else
        APP_URL="https://${APP_DOMAIN}:${PUERTO_PUBLICO}"
    fi

    # ── El PUERTO se responde, no se deja como pregunta ──────────────
    #
    # `.env.example` trae `DB_PORT=5432   # COMPROBAR con pg_lsclusters`,
    # que es correcto para quien instala a mano y una pregunta sin
    # contestar para quien no. Y aqui SI se sabe: es el del cluster que
    # se acaba de afinar.
    #
    # Se lee del propio `postgresql.conf` y no se clava, porque una
    # maquina con dos versiones conviviendo no usa el 5432 — y
    # equivocarlo no falla al arrancar: falla cuando FreeRADIUS intenta
    # autenticar, que es en otro momento y en otro sitio.
    DB_PUERTO="$(sed -n 's/^[[:space:]]*port[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' \
        "/etc/postgresql/${PG_VERSION}/main/postgresql.conf" 2>/dev/null | head -1)"
    DB_PUERTO="${DB_PUERTO:-5432}"

    # Con python y no con `sed`: la contraseña se genera al azar y puede
    # llevar cualquier caracter, incluidos los que rompen una sustitucion
    # —y cada uno la rompe de una forma distinta.
    EJEMPLO="$APP_DIR/.env.example" DESTINO="$APP_DIR/.env" \
    V_APP_URL="$APP_URL" V_DB_NAME="$DB_NAME" V_DB_USER="$DB_USER" \
    V_DB_PASS="$DB_PASS" V_DB_PORT="$DB_PUERTO" V_PROXIES="$PROXY_DELANTE" python3 <<'PY'
import os, pathlib, re

texto = pathlib.Path(os.environ['EJEMPLO']).read_text()

valores = {
    'APP_URL':     os.environ['V_APP_URL'],
    'DB_HOST':     '127.0.0.1',
    'DB_PORT':     os.environ['V_DB_PORT'],
    'DB_DATABASE': os.environ['V_DB_NAME'],
    'DB_USERNAME': os.environ['V_DB_USER'],
    'DB_PASSWORD': os.environ['V_DB_PASS'],
}

# Con un proxy delante hay que decirle al ERP en quien confiar, o todas
# las peticiones parecen venir de el: el tope por IP del login y del
# endpoint de licencia castigaria a todos los ISP a la vez.
if os.environ.get('V_PROXIES'):
    valores['TRUSTED_PROXIES'] = os.environ['V_PROXIES']

for clave, valor in valores.items():
    # Entre comillas SIEMPRE: una contraseña puede llevar un `#`, y a
    # partir de ahi Laravel lee el resto de la linea como comentario —o
    # sea, media contraseña, sin que nada falle al arrancar.
    #
    # Y se comprueba el EFECTO, no que `re.sub` no fallara: sobre una
    # clave que no esta en `.env.example` no sustituye nada y devuelve el
    # texto igual, **sin error**. El ERP arrancaria con ese ajuste sin
    # poner, y el sintoma saldria lejos — el dia que alguien se pregunte
    # por que el ERP no confia en su proxy.
    texto, cuantas = re.subn(rf'(?m)^{clave}=.*$', f'{clave}="{valor}"', texto)

    if cuantas == 0:
        texto = texto.rstrip('\n') + f'\n{clave}="{valor}"\n'

pathlib.Path(os.environ['DESTINO']).write_text(texto)
PY

    chown "$APP_USER:$APP_USER" "$APP_DIR/.env"
    chmod 600 "$APP_DIR/.env"
    echo "    .env escrito (${APP_URL}, base en el puerto ${DB_PUERTO})"
fi

# ── El primer despliegue ──────────────────────────────────────────────

echo "==> Primer despliegue"
# `--creara-admin` le dice al despliegue que no avise de que no hay
# usuarios: lo va a crear este mismo guion unos pasos mas abajo, y las dos
# frases juntas se contradicen en la misma pantalla.
#
# Va como ARGUMENTO y no por el entorno: `sudo` lo limpia por omision y
# conservarlo depende de la politica de sudoers de cada maquina. `argv` no
# lo filtra nadie.
BANDERAS=(--primera-vez)
[[ -n "$ADMIN_EMAIL" ]] && BANDERAS+=(--creara-admin)

sudo -u "$APP_USER" bash "$APP_DIR/deploy/deploy.sh" "${BANDERAS[@]}"

# ── El certificado ────────────────────────────────────────────────────
#
# Falla si el dominio todavia no apunta aqui, o si el 80 no llega desde
# fuera. Eso NO aborta la instalacion: el ERP funciona y el certificado se
# emite despues con una linea. Abortar aqui obligaria a repetirlo todo por
# algo que se arregla en el DNS.

if [[ -n "$CERTBOT_EMAIL" ]] && ! certbot certificates 2>/dev/null | grep -q "$APP_DOMAIN"; then
    echo "==> Certificado TLS"
    if certbot --nginx -d "$APP_DOMAIN" -m "$CERTBOT_EMAIL" \
            --agree-tos --non-interactive --redirect >/dev/null 2>&1; then
        echo "    emitido para ${APP_DOMAIN} (avisos a ${CERTBOT_EMAIL})"
    else
        echo "    no se pudo emitir (el dominio tiene que apuntar aqui y el 80"
        echo "    llegar desde fuera). Cuando lo este:"
        echo "      sudo certbot --nginx -d ${APP_DOMAIN}"
    fi
fi

# ── FreeRADIUS ────────────────────────────────────────────────────────
# Despues del despliegue, porque lee del `.env`.

bash "$APP_DIR/deploy/configurar-freeradius.sh"

# ── El primer usuario ─────────────────────────────────────────────────
#
# Una instalacion sin usuarios esta terminada y **no se puede usar**:
# nadie puede entrar, y no hay ninguna pantalla desde la que arreglarlo.

if [[ -n "$ADMIN_EMAIL" ]]; then
    ADMIN_PASS="$(openssl rand -base64 18)"

    if sudo -u "$APP_USER" "/usr/bin/php${PHP_VERSION}" "$APP_DIR/artisan" usuarios:crear-administrador \
            --nombre="$ADMIN_NOMBRE" --email="$ADMIN_EMAIL" \
            --password="$ADMIN_PASS" --sin-interaccion >/dev/null 2>&1; then
        echo "==> Administrador ${ADMIN_EMAIL} creado"
    else
        ADMIN_PASS=""
        echo "==> El administrador ya existia (o no se pudo crear)"
    fi
fi

# ── La cuenta con la que Ecuatek da soporte ──────────────────────────
#
# Quien instala ya tiene root en esta maquina, asi que esta cuenta no
# anade ni un permiso: anade RASTRO. Sin ella, quien entra a arreglar
# algo lo hace por SSH y no queda en ninguna parte del ERP; con ella,
# cada accion va a la auditoria con su usuario, su IP y su hora.
#
# Nace SUSPENDIDA y con clave propia de esta instalacion. Se activa con
# un comando cuando hace falta entrar, y el ISP la ve en su lista de
# usuarios y puede suspenderla cuando quiera.
SOPORTE_SALIDA="$(sudo -u "$APP_USER" "/usr/bin/php${PHP_VERSION}" "$APP_DIR/artisan" \
    usuarios:soporte-ecuatek 2>&1 || true)"

SOPORTE_CLAVE="$(printf '%s\n' "$SOPORTE_SALIDA" | sed -n 's/^ *Clave *: *//p')"

if [[ -n "$SOPORTE_CLAVE" ]]; then
    echo "==> Cuenta de soporte de Ecuatek creada (suspendida)"
else
    echo "==> La cuenta de soporte de Ecuatek ya existia: no se toco"
fi

# ── Resumen ───────────────────────────────────────────────────────────

cat <<FIN

════════════════════════════════════════════════════════════════════
El ERP esta instalado y funcionando.

  Direccion                : https://${APP_DOMAIN}$( [[ "$PUERTO_PUBLICO" == "443" ]] || echo ":${PUERTO_PUBLICO}" )
  Usuario de la aplicacion : ${APP_USER}
  Carpeta                  : ${APP_DIR}
  Base de datos            : ${DB_NAME} (usuario ${DB_USER})
  Contrasena de la base    : ${DB_PASS_FILE}
  Trabajadores PHP-FPM     : ${MAX_CHILDREN}
FIN

if [[ -n "${ADMIN_PASS:-}" ]]; then
    cat <<FIN

  Entre con:
    ${ADMIN_EMAIL}
    ${ADMIN_PASS}

  Cambiela al entrar: esta impresa aqui y en el registro de la terminal.
FIN
fi

if [[ -n "${SOPORTE_CLAVE:-}" ]]; then
    cat <<FIN

  ── Soporte de Ecuatek ────────────────────────────────────────────
  La cuenta soporte@ecuatek.net quedo creada y SUSPENDIDA, con clave
  propia de esta instalacion:

    ${SOPORTE_CLAVE}

  Anotela donde Ecuatek guarde sus credenciales: no se vuelve a
  mostrar y no se guarda en ningun sitio.

  Para poder entrar con ella, el dia que haga falta:
    sudo -u ${APP_USER} php${PHP_VERSION} ${APP_DIR}/artisan usuarios:soporte-ecuatek --activar

  El ISP la ve en Sistema -> Usuarios y puede suspenderla cuando
  quiera. Reejecutar el aprovisionamiento NO la reactiva.
FIN
fi

if [[ -z "$ADMIN_EMAIL" ]]; then
    cat <<FIN

FALTA: crear el primer usuario, o nadie puede entrar.

    sudo -u ${APP_USER} php${PHP_VERSION} ${APP_DIR}/artisan usuarios:crear-administrador

  (O vuelva a ejecutar este guion con ADMIN_EMAIL=... y lo hace solo.)
FIN
fi

cat <<FIN

Lo que queda depende de datos que solo tiene el ISP, y se hace DESDE EL
ERP, no por SSH:

  · Empresas -> Editar   RUC, direccion y telefono. De ahi salen todos
                         los papeles: factura, contrato, orden de trabajo.
  · Empresas -> Marca    Logo y color. Tambien el icono de la app en el
                         celular del tecnico y el chat de la web.
  · Empresas -> Envios   Telegram para las alertas, con su aviso de
                         prueba: un canal que nadie probo falla el dia
                         que hace falta.
  · Red -> Equipos       Los NAS. El ERP reinicia FreeRADIUS solo.

Y una sola cosa por SSH, porque depende de las IP de los BRAS:

    sudo ufw allow from <ip-del-bras> to any port 1812,1813 proto udp

Como esta la maquina, cuando quiera:

    sudo -u ${APP_USER} php${PHP_VERSION} ${APP_DIR}/artisan sistema:revisar
════════════════════════════════════════════════════════════════════

FIN
