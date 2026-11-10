#!/usr/bin/env bash
#=============================================================================
# Instalación / reparación de Nextcloud en Debian 13 (Apache + MariaDB + PHP)
# Práctica UD3 · Tarea 1 · Aplicaciones web · 2.º SMR
#
# Sirve en dos situaciones:
#   · Máquina limpia            -> instala Nextcloud completo.
#   · Nextcloud ya instalado    -> detecta lo que falta y lo completa
#     (paquetes, PHP, Apache, archivos del código, permisos, trusted_domains,
#      cron, upgrade pendiente...) SIN tocar tus datos ni tus contraseñas.
#
# Datos de la práctica (instalación nueva):
#   Código /var/www/nextcloud · Datos /var/www/nextcloud-data
#   BD nextcloud · usuario nextclouduser · admin adm-<primer apellido>
#
# Uso:  sudo bash instalar_nextcloud.sh
#
# Variables opcionales (para no responder preguntas):
#   APELLIDO, DB_PASS, ADMIN_PASS, INSTALAR_APCU=si|no, TZ_SERVIDOR, FORZAR=si
#
# Aviso: si la instancia tiene datos que importan, haz antes una copia o una
# instantánea de la máquina. El script guarda una copia de config.php.
#=============================================================================
set -euo pipefail

# ---------- Datos por defecto ---------------------------------------------
NC_DIR="/var/www/nextcloud"
NC_DATA="/var/www/nextcloud-data"
DB_NAME="nextcloud"
DB_USER="nextclouduser"
NC_URL="https://download.nextcloud.com/server/releases/latest.tar.bz2"
TZ_SERVIDOR="${TZ_SERVIDOR:-Europe/Madrid}"
INSTALAR_APCU="${INSTALAR_APCU:-no}"     # "si" añade caché de memoria (APCu)
CONFIG="${NC_DIR}/config/config.php"

# ---------- Utilidades -----------------------------------------------------
info()  { echo -e "\n\e[1;34m==>\e[0m \e[1m$*\e[0m"; }
ok()    { echo -e "\e[1;32m  ✔\e[0m $*"; }
aviso() { echo -e "\e[1;33m  !\e[0m $*"; }
error() { echo -e "\e[1;31m  ✘ $*\e[0m" >&2; exit 1; }

occ()     { sudo -E -u www-data php "${NC_DIR}/occ" "$@"; }
get_cfg() { occ config:system:get "$1" 2>/dev/null || true; }

instalado_en_config() { [[ -f "$CONFIG" ]] && grep -q "'installed' => true" "$CONFIG"; }
codigo_completo() {
    local f
    for f in occ index.php cron.php version.php lib/base.php 3rdparty/autoload.php core apps; do
        [[ -e "${NC_DIR}/${f}" ]] || return 1
    done
}

[[ $EUID -eq 0 ]] || error "Ejecuta el script como root: sudo bash $0"
. /etc/os-release
[[ "${ID:-}" == "debian" ]] || error "Pensado para Debian (detectado: ${ID:-desconocido})."
[[ "${VERSION_ID:-0}" -ge 12 ]] || aviso "Se esperaba Debian 13; versión detectada: ${VERSION_ID:-?}"

# ---------- Diagnóstico inicial -------------------------------------------
info "Diagnóstico del estado actual"
if instalado_en_config; then
    MODO="reparar"
    ok "Nextcloud ya está instalado (config.php con installed=true): modo REPARAR/COMPLETAR"
else
    MODO="nueva"
    ok "No hay instalación configurada: modo INSTALACIÓN NUEVA"
fi
codigo_completo && ok "Código de Nextcloud completo en ${NC_DIR}" \
                || aviso "Código de Nextcloud ausente o incompleto en ${NC_DIR} (se restaurará)"

# ---------- Preguntas (solo si es instalación nueva) ----------------------
if [[ "$MODO" == "nueva" ]]; then
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
fi

# ---------- 1. Paquetes ----------------------------------------------------
info "1/8 Comprobando e instalando paquetes (los ya instalados se saltan)"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y \
    apache2 mariadb-server \
    php libapache2-mod-php php-cli php-mysql php-gd php-curl php-mbstring \
    php-xml php-zip php-intl php-bcmath php-gmp php-bz2 php-imagick \
    bzip2 unzip curl wget rsync sudo cron ca-certificates
[[ "$INSTALAR_APCU" == "si" ]] && apt-get install -y php-apcu
systemctl enable --now apache2 mariadb cron
PHPV="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')"
ok "Servicios activos · PHP ${PHPV}"

# ---------- 2. Código de Nextcloud ----------------------------------------
info "2/8 Código de Nextcloud"
if codigo_completo; then
    ok "El código está completo: no se descarga nada"
else
    [[ -f "$CONFIG" ]] && cp -a "$CONFIG" "${CONFIG}.bak-$(date +%Y%m%d-%H%M%S)" \
        && ok "Copia de seguridad de config.php creada"
    TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
    wget -q --show-progress -O "${TMP}/nc.tar.bz2"        "$NC_URL"
    wget -q                 -O "${TMP}/nc.tar.bz2.sha256" "${NC_URL}.sha256"
    HASH_ESPERADO="$(awk '{print $1}' "${TMP}/nc.tar.bz2.sha256" | head -n1)"
    HASH_REAL="$(sha256sum "${TMP}/nc.tar.bz2" | awk '{print $1}')"
    [[ -n "$HASH_ESPERADO" && "$HASH_ESPERADO" == "$HASH_REAL" ]] \
        || error "La suma SHA-256 no coincide: descarga corrupta."
    ok "Suma SHA-256 verificada"
    tar -xjf "${TMP}/nc.tar.bz2" -C "$TMP"
    mkdir -p "$NC_DIR"
    # --ignore-existing: solo rellena lo que falta; no pisa config.php ni apps propias
    rsync -a --ignore-existing "${TMP}/nextcloud/" "${NC_DIR}/"
    ok "Código restaurado en ${NC_DIR}"
fi

# ---------- Datos de BD y carpeta de datos --------------------------------
if [[ "$MODO" == "reparar" ]]; then
    DB_NAME="$(get_cfg dbname)";        [[ -n "$DB_NAME" ]] || DB_NAME="nextcloud"
    DB_USER="$(get_cfg dbuser)";        [[ -n "$DB_USER" ]] || DB_USER="nextclouduser"
    DB_PASS="$(get_cfg dbpassword)"
    NC_DATA="$(get_cfg datadirectory)"; [[ -n "$NC_DATA" ]] || NC_DATA="/var/www/nextcloud-data"
fi

# ---------- 3. Base de datos ----------------------------------------------
info "3/8 Base de datos"
if [[ "$MODO" == "nueva" ]]; then
    TABLAS="$(mariadb -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${DB_NAME}'")"
    if (( TABLAS > 0 )); then
        aviso "La base '${DB_NAME}' tiene ${TABLAS} tablas de un intento anterior y Nextcloud no está instalado."
        if [[ "${FORZAR:-no}" != "si" ]]; then
            read -rp "¿Borrarla y empezar de cero? (s/N): " R || R="n"
            [[ "$R" =~ ^[sS]$ ]] || error "Cancelado. Revisa la base de datos o usa FORZAR=si."
        fi
        mariadb -e "DROP DATABASE \`${DB_NAME}\`"
    fi
    mariadb <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
ALTER USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL
    ok "Base '${DB_NAME}' y usuario '${DB_USER}' listos"
else
    if mariadb -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -e "SELECT 1" >/dev/null 2>&1; then
        ok "La base '${DB_NAME}' responde con el usuario '${DB_USER}' (no se modifica)"
    else
        aviso "No se pudo entrar en '${DB_NAME}' con '${DB_USER}'. Revisa dbname/dbuser/dbpassword en config.php"
        aviso "o restaura la base desde una copia. El script no cambia contraseñas de una instalación existente."
    fi
fi

# ---------- 4. Carpeta de datos y permisos --------------------------------
info "4/8 Carpeta de datos y permisos (puede tardar un poco; no está bloqueado)"
mkdir -p "$NC_DATA"
# Se agrupan los archivos en lotes (+) y solo se tocan los que no están ya bien:
# así es rápido incluso en una máquina virtual lenta y al repetir el script.
find "$NC_DIR" "$NC_DATA" \( ! -user www-data -o ! -group www-data \) -exec chown www-data:www-data {} +
find "$NC_DIR" -type d ! -perm 750 -exec chmod 750 {} +
find "$NC_DIR" -type f ! -perm 640 -exec chmod 640 {} +
chmod 750 "$NC_DATA"
chmod +x "${NC_DIR}/occ"
ok "Código: ${NC_DIR} · Datos: ${NC_DATA}"

# ---------- 5. PHP ---------------------------------------------------------
info "5/8 Ajustes de PHP"
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
ok "Ajustes aplicados"

# ---------- 6. Apache ------------------------------------------------------
info "6/8 Apache"
VHOST="/etc/apache2/sites-available/nextcloud.conf"
cat > "${VHOST}.nuevo" <<EOF
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
if [[ -f "$VHOST" ]] && ! cmp -s "$VHOST" "${VHOST}.nuevo"; then
    cp -a "$VHOST" "${VHOST}.bak-$(date +%Y%m%d-%H%M%S)"
fi
mv "${VHOST}.nuevo" "$VHOST"
a2enmod rewrite headers env dir mime setenvif >/dev/null
a2dissite 000-default >/dev/null 2>&1 || true
a2ensite nextcloud >/dev/null
apache2ctl configtest
systemctl restart apache2
ok "Sitio 'nextcloud' activo en el puerto 80"

# ---------- 7. Nextcloud ---------------------------------------------------
info "7/8 Nextcloud"
if [[ "$MODO" == "nueva" ]]; then
    [[ -f "$CONFIG" ]] && cp -a "$CONFIG" "${CONFIG}.bak-$(date +%Y%m%d-%H%M%S)"
    occ maintenance:install \
        --database "mysql" --database-name "$DB_NAME" \
        --database-user "$DB_USER" --database-pass "$DB_PASS" \
        --admin-user "$ADMIN_USER" --admin-pass "$ADMIN_PASS" \
        --data-dir "$NC_DATA"
    ok "Nextcloud instalado con la cuenta ${ADMIN_USER}"
else
    occ maintenance:mode --off >/dev/null 2>&1 || true
    if occ status --output=json 2>/dev/null | grep -Eq '"needsDbUpgrade": ?true'; then
        aviso "Hay una actualización pendiente de la base de datos: ejecutando occ upgrade"
        occ upgrade
    fi
    ok "Instalación existente comprobada"
fi

# --- trusted_domains: limpia entradas inválidas y garantiza localhost + IPv4
listar_dominios() {
    occ config:list system --output=json 2>/dev/null | php -r '
        $j = json_decode(stream_get_contents(STDIN), true);
        foreach (($j["system"]["trusted_domains"] ?? []) as $k => $v) echo $k."\t".$v."\n";'
}
while IFS=$'\t' read -r K V; do
    if [[ -z "$V" || "$V" == */* ]] || { [[ "$V" =~ ^[0-9a-fA-F:]+$ ]] && [[ "$V" == *:*:* ]]; }; then
        occ config:system:delete trusted_domains "$K" >/dev/null
        aviso "Eliminada entrada inválida de trusted_domains [${K}] = '${V}'"
    fi
done < <(listar_dominios)

anadir_dominio() {
    local valor="$1" k v idx=0
    while IFS=$'\t' read -r k v; do [[ "$v" == "$valor" ]] && return 0; done < <(listar_dominios)
    while occ config:system:get trusted_domains "$idx" >/dev/null 2>&1; do idx=$((idx+1)); done
    occ config:system:set trusted_domains "$idx" --value="$valor" >/dev/null
}
anadir_dominio "localhost"
for ip in $(hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' || true); do
    anadir_dominio "$ip"
done
ok "trusted_domains: $(listar_dominios | cut -f2 | paste -sd' ')"

# --- Resto de ajustes (solo si faltan o están mal)
[[ "$(get_cfg overwrite.cli.url)" =~ ^https?:// ]] \
    || occ config:system:set overwrite.cli.url --value="http://localhost"
[[ -n "$(get_cfg default_phone_region)" ]] \
    || occ config:system:set default_phone_region --value="ES"
[[ -n "$(get_cfg maintenance_window_start)" ]] \
    || occ config:system:set maintenance_window_start --type=integer --value=3
[[ "$INSTALAR_APCU" == "si" ]] \
    && occ config:system:set memcache.local --value='\OC\Memcache\APCu'

occ maintenance:update:htaccess || true
occ db:add-missing-indices      || true
occ maintenance:repair --include-expensive || true

# ---------- 8. Cron --------------------------------------------------------
info "8/8 Cron de Nextcloud"
occ background:cron
CRON_LINE="*/5 * * * * php -f ${NC_DIR}/cron.php"
( crontab -u www-data -l 2>/dev/null | grep -vF "cron.php" || true; echo "$CRON_LINE" ) \
    | crontab -u www-data -
ok "Cron de www-data programado cada 5 minutos"

# ---------- Resumen --------------------------------------------------------
info "Comprobaciones finales (captura C3)"
echo -e "\n\$ sudo -E -u www-data php ${NC_DIR}/occ status"
occ status
echo -e "\n\$ sudo crontab -u www-data -l"
crontab -u www-data -l

VERDE=$'\e[1;32m'; FIN=$'\e[0m'
cat <<RESUMEN

${VERDE}================ PROCESO COMPLETADO (${MODO}) ================${FIN}
  Dirección      : http://localhost   (o http://$(hostname -I | awk '{print $1}'))
  Código         : ${NC_DIR}
  Datos          : ${NC_DATA}
  Base de datos  : ${DB_NAME}  (usuario ${DB_USER})
  Config         : ${CONFIG}
${VERDE}==============================================================${FIN}
RESUMEN
[[ "$MODO" == "nueva" ]] && echo "  Administrador  : ${ADMIN_USER}  (guarda las contraseñas en un sitio seguro)"
exit 0
