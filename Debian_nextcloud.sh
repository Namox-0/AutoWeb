#!/usr/bin/env bash
#=============================================================================
# Instalación completa de Nextcloud en Debian 13 (Apache + MariaDB + PHP)
# Práctica UD3 · Tarea 1 · Aplicaciones web · 2.º SMR
#
# Datos de la práctica:
#   Código de Nextcloud : /var/www/nextcloud
#   Carpeta de datos    : /var/www/nextcloud-data
#   Base de datos       : nextcloud
#   Usuario de BD       : nextclouduser
#   Cuenta de admin     : adm-<primer apellido en minúsculas y sin tildes>
#
# Uso:  sudo bash instalar_nextcloud.sh
#
# Variables opcionales (para ejecutarlo sin preguntas):
#   APELLIDO, DB_PASS, ADMIN_PASS, INSTALAR_APCU=si|no, TZ_SERVIDOR
#=============================================================================
set -euo pipefail

# ---------- Datos fijos ----------------------------------------------------
NC_DIR="/var/www/nextcloud"
NC_DATA="/var/www/nextcloud-data"
DB_NAME="nextcloud"
DB_USER="nextclouduser"
NC_URL="https://download.nextcloud.com/server/releases/latest.tar.bz2"
TZ_SERVIDOR="${TZ_SERVIDOR:-Europe/Madrid}"
INSTALAR_APCU="${INSTALAR_APCU:-no}"   # "si" añade caché de memoria (APCu)

# ---------- Utilidades -----------------------------------------------------
info()  { echo -e "\n\e[1;34m==>\e[0m \e[1m$*\e[0m"; }
ok()    { echo -e "\e[1;32m  ✔\e[0m $*"; }
error() { echo -e "\e[1;31m  ✘ $*\e[0m" >&2; exit 1; }

[[ $EUID -eq 0 ]] || error "Ejecuta el script como root: sudo bash $0"

. /etc/os-release
if [[ "${ID:-}" != "debian" ]]; then
    error "Este script está pensado para Debian (detectado: ${ID:-desconocido})."
fi
[[ "${VERSION_ID:-0}" -ge 12 ]] || echo "Aviso: se esperaba Debian 13; versión detectada: ${VERSION_ID:-?}"

# ---------- Datos que pide al usuario -------------------------------------
if [[ -z "${APELLIDO:-}" ]]; then
    read -rp "Tu primer apellido (minúsculas y sin tildes, p. ej. gomez): " APELLIDO
fi
APELLIDO="$(echo "$APELLIDO" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
[[ "$APELLIDO" =~ ^[a-z]+$ ]] || error "El apellido solo puede llevar letras minúsculas sin tildes."
ADMIN_USER="adm-${APELLIDO}"

pedir_clave() {   # $1 = texto, $2 = nombre de la variable
    local p1 p2
    while true; do
        read -rsp "$1: " p1; echo
        read -rsp "Repite la contraseña: " p2; echo
        [[ -n "$p1" && "$p1" == "$p2" ]] && break
        echo "No coinciden o están vacías. Inténtalo de nuevo."
    done
    printf -v "$2" '%s' "$p1"
}

[[ -n "${DB_PASS:-}"    ]] || pedir_clave "Contraseña para ${DB_USER} (base de datos)" DB_PASS
[[ -n "${ADMIN_PASS:-}" ]] || pedir_clave "Contraseña para la cuenta ${ADMIN_USER}"    ADMIN_PASS

# ---------- 1. Paquetes ----------------------------------------------------
info "1/8 Instalando Apache, MariaDB, PHP y dependencias"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y \
    apache2 mariadb-server \
    php libapache2-mod-php php-cli php-mysql php-gd php-curl php-mbstring \
    php-xml php-zip php-intl php-bcmath php-gmp php-bz2 php-imagick \
    bzip2 unzip curl wget sudo cron ca-certificates
if [[ "$INSTALAR_APCU" == "si" ]]; then
    apt-get install -y php-apcu
fi
systemctl enable --now apache2 mariadb cron
PHPV="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')"
ok "PHP ${PHPV} instalado"

# ---------- 2. Base de datos ----------------------------------------------
info "2/8 Creando la base de datos y el usuario"
mariadb <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
ALTER USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL
ok "Base de datos '${DB_NAME}' y usuario '${DB_USER}' listos"

# ---------- 3. Descarga del código ----------------------------------------
info "3/8 Descargando Nextcloud (última versión estable)"
if [[ -f "${NC_DIR}/occ" ]]; then
    error "Ya existe ${NC_DIR}. Si quieres reinstalar, elimínalo antes (y ${NC_DATA}, y la base de datos)."
fi
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
wget -q --show-progress -O "${TMP}/nextcloud.tar.bz2"        "$NC_URL"
wget -q                 -O "${TMP}/nextcloud.tar.bz2.sha256" "${NC_URL}.sha256"
HASH_ESPERADO="$(awk '{print $1}' "${TMP}/nextcloud.tar.bz2.sha256" | head -n1)"
HASH_REAL="$(sha256sum "${TMP}/nextcloud.tar.bz2" | awk '{print $1}')"
[[ -n "$HASH_ESPERADO" && "$HASH_ESPERADO" == "$HASH_REAL" ]] \
    || error "La suma SHA-256 no coincide (esperada: ${HASH_ESPERADO:-vacía}, real: ${HASH_REAL}): descarga corrupta."
ok "Suma SHA-256 verificada"
tar -xjf "${TMP}/nextcloud.tar.bz2" -C /var/www/
ok "Código extraído en ${NC_DIR}"

# ---------- 4. Carpeta de datos y permisos --------------------------------
info "4/8 Creando la carpeta de datos y ajustando permisos"
mkdir -p "$NC_DATA"
chown -R www-data:www-data "$NC_DIR" "$NC_DATA"
find "$NC_DIR"  -type d -exec chmod 750 {} \;
find "$NC_DIR"  -type f -exec chmod 640 {} \;
chmod 750 "$NC_DATA"
chmod +x "${NC_DIR}/occ"
ok "Datos en ${NC_DATA} (fuera del directorio web)"

# ---------- 5. Configuración de PHP ---------------------------------------
info "5/8 Ajustando PHP"
PHP_INI="; Ajustes recomendados para Nextcloud
memory_limit = 512M
upload_max_filesize = 512M
post_max_size = 512M
max_execution_time = 360
max_input_time = 360
date.timezone = ${TZ_SERVIDOR}
output_buffering = 0
opcache.enable = 1
opcache.interned_strings_buffer = 16
opcache.max_accelerated_files = 10000
opcache.memory_consumption = 128
opcache.save_comments = 1
opcache.revalidate_freq = 60
apc.enable_cli = 1"
for sapi in apache2 cli; do
    echo "$PHP_INI" > "/etc/php/${PHPV}/${sapi}/conf.d/90-nextcloud.ini"
done
ok "Ajustes aplicados a /etc/php/${PHPV}/{apache2,cli}/conf.d/90-nextcloud.ini"

# ---------- 6. Apache ------------------------------------------------------
info "6/8 Configurando Apache"
cat > /etc/apache2/sites-available/nextcloud.conf <<EOF
<VirtualHost *:80>
    ServerName localhost
    DocumentRoot ${NC_DIR}

    <Directory ${NC_DIR}/>
        Require all granted
        AllowOverride All
        Options FollowSymLinks MultiViews

        <IfModule mod_dav.c>
            Dav off
        </IfModule>
    </Directory>

    <IfModule mod_headers.c>
        Header always set Strict-Transport-Security "max-age=15552000; includeSubDomains" env=HTTPS
    </IfModule>

    ErrorLog  \${APACHE_LOG_DIR}/nextcloud_error.log
    CustomLog \${APACHE_LOG_DIR}/nextcloud_access.log combined
</VirtualHost>
EOF
a2enmod rewrite headers env dir mime setenvif >/dev/null
a2dissite 000-default >/dev/null 2>&1 || true
a2ensite nextcloud >/dev/null
apache2ctl configtest
systemctl restart apache2
ok "Sitio 'nextcloud' activo en el puerto 80"

# ---------- 7. Instalación de Nextcloud -----------------------------------
info "7/8 Instalando Nextcloud con occ (puede tardar un minuto)"
occ() { sudo -E -u www-data php "${NC_DIR}/occ" "$@"; }

occ maintenance:install \
    --database "mysql" \
    --database-name "$DB_NAME" \
    --database-user "$DB_USER" \
    --database-pass "$DB_PASS" \
    --admin-user "$ADMIN_USER" \
    --admin-pass "$ADMIN_PASS" \
    --data-dir "$NC_DATA"

# Dominios de confianza: localhost + IPs y nombre de la máquina
occ config:system:set trusted_domains 0 --value="localhost"
i=1
for ip in $(hostname -I 2>/dev/null); do
    occ config:system:set trusted_domains "$i" --value="$ip"
    i=$((i+1))
done
occ config:system:set trusted_domains "$i" --value="$(hostname)"

occ config:system:set overwrite.cli.url --value="http://localhost"
occ config:system:set default_phone_region --value="ES"
occ config:system:set maintenance_window_start --type=integer --value=3
if [[ "$INSTALAR_APCU" == "si" ]]; then
    occ config:system:set memcache.local --value='\OC\Memcache\APCu'
fi
occ maintenance:update:htaccess || true
occ db:add-missing-indices      || true
occ maintenance:repair --include-expensive || true
ok "Nextcloud instalado con la cuenta ${ADMIN_USER}"

# ---------- 8. Tareas programadas (cron) ----------------------------------
info "8/8 Programando el cron de Nextcloud"
occ background:cron
CRON_LINE="*/5 * * * * php -f ${NC_DIR}/cron.php"
( crontab -u www-data -l 2>/dev/null | grep -vF "cron.php" ; echo "$CRON_LINE" ) \
    | crontab -u www-data -
ok "Cron de www-data programado cada 5 minutos"

# ---------- Resumen --------------------------------------------------------
info "Comprobaciones finales (para la captura C3)"
echo -e "\n\$ sudo -E -u www-data php ${NC_DIR}/occ status"
occ status
echo -e "\n\$ sudo crontab -u www-data -l"
crontab -u www-data -l

VERDE=$'\e[1;32m'; FIN=$'\e[0m'
cat <<RESUMEN

${VERDE}================ INSTALACIÓN COMPLETADA ================${FIN}
  Dirección      : http://localhost   (o http://$(hostname -I | awk '{print $1}'))
  Administrador  : ${ADMIN_USER}
  Código         : ${NC_DIR}
  Datos          : ${NC_DATA}
  Base de datos  : ${DB_NAME}  (usuario ${DB_USER})
  Config         : ${NC_DIR}/config/config.php
${VERDE}========================================================${FIN}
Guarda las contraseñas en un sitio seguro.
RESUMEN
