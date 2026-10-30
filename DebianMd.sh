#!/usr/bin/env bash
# =============================================================================
#  Instalación automática de Moodle 5.3 en Debian 13 (Apache + MariaDB + PHP)
#  Práctica UD2-P1 · Aplicaciones Web · 2.º SMR
#
#  Uso:   sudo bash instalar_moodle.sh
#
#  Todo se puede preconfigurar con variables de entorno; lo que falte se
#  pregunta por teclado. Ejemplo sin preguntas:
#    sudo NOMBRE="Ana" APELLIDOS="Gómez Pérez" \
#         DB_PASS='xxxx' ADMIN_PASS='Yyyy-1234!' bash instalar_moodle.sh
#  Otras variables opcionales: SITE_URL, ADMIN_EMAIL, ADMIN_USER, DB_NAME,
#  DB_USER, SITE_FULLNAME, TIMEZONE, MOODLE_TGZ_URL, APELLIDO1.
# =============================================================================
set -Eeuo pipefail
trap 'echo -e "\n\e[31m[ERROR] Falló la línea $LINENO. Revisa el mensaje anterior.\e[0m" >&2' ERR

# ---------- Datos de la práctica (sobrescribibles por entorno) ----------------
MOODLE_DIR="/var/www/moodle"
DATA_DIR="/var/www/moodledata"
SITE_URL="${SITE_URL:-http://localhost}"
DB_NAME="${DB_NAME:-moodle}"
DB_USER="${DB_USER:-moodleuser}"
DB_PREFIX="mdl_"
ADMIN_USER="${ADMIN_USER:-admin}"
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@example.com}"
SITE_FULLNAME="${SITE_FULLNAME:-Aula Virtual Academia Valdeorras}"
TIMEZONE="${TIMEZONE:-Europe/Madrid}"
LANG_MOODLE="es"
MOODLE_BRANCH="503"   # 5.3  -> stable503 / MOODLE_503_STABLE
MOODLE_TGZ_URL="${MOODLE_TGZ_URL:-https://download.moodle.org/download.php/direct/stable${MOODLE_BRANCH}/moodle-latest-${MOODLE_BRANCH}.tgz}"
MOODLE_GIT_URL="https://github.com/moodle/moodle.git"
CRED_FILE="/root/moodle-credenciales.txt"
MIN_FREE_MB=2000

# ---------- Utilidades --------------------------------------------------------
info() { echo -e "\n\e[1;34m==> $*\e[0m"; }
ok()   { echo -e "\e[32m    OK: $*\e[0m"; }
warn() { echo -e "\e[33m    AVISO: $*\e[0m"; }
die()  { echo -e "\e[31m[ERROR] $*\e[0m" >&2; exit 1; }

genpass() { # contraseña aleatoria que cumple la política de Moodle (may, min, núm, símbolo)
  local r; r="$(head -c 300 /dev/urandom | tr -dc 'A-Za-z0-9' | cut -c1-14)"
  echo "${r}aZ9-"
}

sin_tildes() { # minúsculas, sin tildes ni espacios
  echo "$1" | iconv -f utf-8 -t ascii//TRANSLIT 2>/dev/null \
    | tr -d "'\`^~\"" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9'
}

preguntar() { # preguntar VAR "texto" [secreto]
  local var="$1" txt="$2" sec="${3:-}" val
  if [[ -n "${!var:-}" ]]; then return; fi
  if [[ ! -t 0 ]]; then die "Falta la variable $var y no hay terminal para preguntarla."; fi
  if [[ -n "$sec" ]]; then read -r -s -p "$txt: " val; echo; else read -r -p "$txt: " val; fi
  [[ -n "$val" ]] || die "El valor de $var no puede estar vacío."
  printf -v "$var" '%s' "$val"
}

# ---------- Comprobaciones previas -------------------------------------------
[[ $EUID -eq 0 ]] || die "Ejecuta el script como root: sudo bash $0"
if [[ -r /etc/os-release ]]; then
  . /etc/os-release
  [[ "${ID:-}" == "debian" ]] || die "Este script es para Debian (detectado: ${ID:-desconocido})."
  [[ "${VERSION_ID:-0}" -ge 13 ]] || warn "Se esperaba Debian 13; con otra versión PHP/MariaDB pueden no cumplir los requisitos."
fi

info "Comprobación previa: Internet y espacio en disco (lista de comprobación 5.1)"
curl -fsI --max-time 15 https://download.moodle.org >/dev/null || die "Sin conexión a download.moodle.org."
mkdir -p /var/www
FREE_MB="$(df -Pm /var/www | awk 'NR==2{print $4}')"
[[ "${FREE_MB:-0}" -ge "$MIN_FREE_MB" ]] || die "Espacio libre insuficiente: ${FREE_MB} MB (mínimo ${MIN_FREE_MB} MB)."
ok "Internet disponible y ${FREE_MB} MB libres"

info "Datos de la instalación"
preguntar NOMBRE    "Tu nombre"
preguntar APELLIDOS "Tus apellidos (completos)"
if [[ -z "${APELLIDO1:-}" ]]; then APELLIDO1="${APELLIDOS%% *}"; fi
SHORTNAME="AVAV-$(sin_tildes "$APELLIDO1")"
[[ "$SHORTNAME" != "AVAV-" ]] || die "No se pudo generar el nombre corto del sitio."

GENERADA_DB=0; GENERADA_ADMIN=0
if [[ -z "${DB_PASS:-}" ]];    then DB_PASS="$(genpass)";    GENERADA_DB=1; fi
if [[ -z "${ADMIN_PASS:-}" ]]; then ADMIN_PASS="$(genpass)"; GENERADA_ADMIN=1; fi
[[ "$DB_PASS" != *"'"* && "$DB_PASS" != *'\'* ]] || die "DB_PASS no puede contener ' ni \\."
ok "Nombre corto del sitio: $SHORTNAME"

# ---------- Paso 1. Paquetes --------------------------------------------------
info "Paso 1: instalando Apache, MariaDB y PHP"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y apache2 mariadb-server mariadb-client \
  php php-cli libapache2-mod-php php-mysql php-xml php-curl php-zip php-gd \
  php-intl php-mbstring php-soap php-opcache php-ldap php-bcmath \
  unzip curl git ca-certificates cron graphicsmagick ghostscript \
  composer
ok "$(php -v | head -n1)"
ok "$(mariadb --version)"
PHPVER="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')"

# ---------- Paso 2. PHP: max_input_vars = 5000 --------------------------------
info "Paso 2: ajustando PHP (max_input_vars=5000)"
for sapi in apache2 cli; do
  d="/etc/php/${PHPVER}/${sapi}/conf.d"
  [[ -d "$d" ]] || continue
  cat > "$d/99-moodle.ini" <<'EOF'
; Ajustes para Moodle
max_input_vars = 5000
upload_max_filesize = 100M
post_max_size = 100M
memory_limit = 256M
EOF
done
ok "php -i: $(php -i | grep -E '^max_input_vars' | head -n1)"

# ---------- Paso 7 (doc). Base de datos: mínimo privilegio --------------------
info "Creando la base de datos '$DB_NAME' y el usuario '$DB_USER' (mínimo privilegio)"
systemctl enable --now mariadb
mariadb <<EOF
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
ALTER USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
REVOKE ALL PRIVILEGES, GRANT OPTION FROM '${DB_USER}'@'localhost';
GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, CREATE TEMPORARY TABLES,
      DROP, INDEX, ALTER ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
EOF
ok "Base de datos lista"

# ---------- Paso 3. Descargar Moodle -----------------------------------------
info "Paso 3: descargando Moodle 5.3 en $MOODLE_DIR"
if [[ -f "$MOODLE_DIR/config.php" ]]; then
  warn "$MOODLE_DIR/config.php ya existe: se salta la descarga (¿instalación previa?)."
else
  rm -rf "$MOODLE_DIR"
  TMP="$(mktemp -d)"
  if curl -fL --retry 3 -o "$TMP/moodle.tgz" "$MOODLE_TGZ_URL" && tar -tzf "$TMP/moodle.tgz" >/dev/null 2>&1; then
    tar -xzf "$TMP/moodle.tgz" -C /var/www
  else
    warn "No se pudo usar el .tgz; descargando desde GitHub (rama MOODLE_${MOODLE_BRANCH}_STABLE)"
    git clone --depth 1 -b "MOODLE_${MOODLE_BRANCH}_STABLE" "$MOODLE_GIT_URL" "$MOODLE_DIR"
    rm -rf "$MOODLE_DIR/.git"
  fi
  rm -rf "$TMP"
fi
[[ -d "$MOODLE_DIR/public" ]] || die "No se encontró $MOODLE_DIR/public: la descarga no es Moodle 5.x."
ok "Código de Moodle en $MOODLE_DIR"

# ---------- Paso 4. Permisos del código (root, solo lectura para Apache) ------
info "Paso 4: permisos del código"
chown -R root:root "$MOODLE_DIR"
chmod -R 0755 "$MOODLE_DIR"

# ---------- Paso 5 + 10. Apache: public + router ------------------------------
info "Paso 5 y 10: configurando Apache (DocumentRoot = $MOODLE_DIR/public + router)"
SITE="/etc/apache2/sites-available/000-default.conf"
sed -i -E "s#^([[:space:]]*DocumentRoot[[:space:]]+).*#\1${MOODLE_DIR}/public#" "$SITE"
if ! grep -q "FallbackResource /r.php" "$SITE"; then
  sed -i "/DocumentRoot/a\\
\\
\\t<Directory ${MOODLE_DIR}/public>\\
\\t\\tAllowOverride None\\
\\t\\tRequire all granted\\
\\t\\tDirectoryIndex index.php\\
\\t\\tFallbackResource /r.php\\
\\t\\tRewriteEngine On\\
\\t\\tRewriteCond %{REQUEST_FILENAME} !-f\\
\\t\\tRewriteCond %{REQUEST_FILENAME} !-d\\
\\t\\tRewriteRule ^ /r.php [L]\\
\\t</Directory>" "$SITE"
fi
a2enmod rewrite >/dev/null
apache2ctl configtest
systemctl enable apache2
systemctl restart apache2
ok "Apache reiniciado"

# ---------- Paso 6. Carpeta de datos -----------------------------------------
info "Paso 6: creando $DATA_DIR"
mkdir -p "$DATA_DIR"
chown www-data:www-data "$DATA_DIR"
chmod 0770 "$DATA_DIR"

# ---------- Paso 10a. Composer (antes del instalador) -------------------------
info "Paso 10: librerías de la API (composer install)"
(cd "$MOODLE_DIR" && COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --classmap-authoritative --no-interaction)

# ---------- Paso 8. Instalador (modo comando, sin navegador) ------------------
CLI_DIR="$MOODLE_DIR/admin/cli"
[[ -f "$CLI_DIR/install.php" ]] || CLI_DIR="$MOODLE_DIR/public/admin/cli"

if [[ -f "$MOODLE_DIR/config.php" ]]; then
  warn "config.php ya existe: se omite el instalador."
else
  info "Paso 8: ejecutando el instalador de Moodle (puede tardar varios minutos)"
  chown www-data "$MOODLE_DIR"      # solo la carpeta, para que pueda crear config.php
  sudo -u www-data /usr/bin/php "$CLI_DIR/install.php" \
    --lang="$LANG_MOODLE" \
    --wwwroot="$SITE_URL" \
    --dataroot="$DATA_DIR" \
    --dbtype=mariadb --dbhost=localhost \
    --dbname="$DB_NAME" --dbuser="$DB_USER" --dbpass="$DB_PASS" \
    --prefix="$DB_PREFIX" \
    --fullname="$SITE_FULLNAME" --shortname="$SHORTNAME" \
    --adminuser="$ADMIN_USER" --adminpass="$ADMIN_PASS" --adminemail="$ADMIN_EMAIL" \
    --agree-license --non-interactive
fi

# Nombre y apellidos reales del administrador + zona horaria
# (el usuario de la BD tiene permisos mínimos, pero UPDATE sí lo tiene; se usa root vía socket)
mariadb "$DB_NAME" -e "UPDATE ${DB_PREFIX}user SET firstname='${NOMBRE//\'/\'\'}', lastname='${APELLIDOS//\'/\'\'}' WHERE username='${ADMIN_USER}';"
sudo -u www-data /usr/bin/php "$CLI_DIR/cfg.php" --name=timezone --set="$TIMEZONE"
sudo -u www-data /usr/bin/php "$CLI_DIR/cfg.php" --name=forcetimezone --set="$TIMEZONE"
ok "Moodle instalado"

# ---------- Paso 10b. routerconfigured en config.php --------------------------
info "Router de Moodle: routerconfigured en config.php"
if ! grep -q 'routerconfigured' "$MOODLE_DIR/config.php"; then
  sed -i "/require_once(__DIR__ . '\/lib\/setup.php');/i \$CFG->routerconfigured = true;\n" "$MOODLE_DIR/config.php"
fi
grep -n 'routerconfigured' "$MOODLE_DIR/config.php" || die "No se pudo añadir routerconfigured a config.php."

# ---------- Paquete de idioma gallego (mejor esfuerzo) ------------------------
info "Instalando paquete de idioma gallego (gl)"
set +e
VERSION_PHP="$(sed -n "s/^\$release *= *'\([0-9]*\.[0-9]*\).*/\1/p" "$MOODLE_DIR/public/version.php" "$MOODLE_DIR/version.php" 2>/dev/null | head -n1)"
VERSION_PHP="${VERSION_PHP:-5.3}"
LTMP="$(mktemp -d)"
if curl -fsSL -o "$LTMP/gl.zip" "https://download.moodle.org/download.php/direct/langpack/${VERSION_PHP}/gl.zip" \
   && mkdir -p "$DATA_DIR/lang" && unzip -qo "$LTMP/gl.zip" -d "$DATA_DIR/lang"; then
  chown -R www-data:www-data "$DATA_DIR/lang"
  ok "Idioma gallego instalado"
else
  warn "No se pudo instalar 'gl'. Hazlo a mano: Administración del sitio → General → Idioma → Paquetes de idioma."
fi
rm -rf "$LTMP"
set -e

# ---------- Paso 9. Cron y permisos finales ----------------------------------
info "Paso 9: cron de www-data y código de nuevo como root"
CRON_LINE="* * * * * /usr/bin/php ${MOODLE_DIR}/admin/cli/cron.php >/dev/null 2>&1"
[[ -f "$MOODLE_DIR/admin/cli/cron.php" ]] || CRON_LINE="* * * * * /usr/bin/php ${MOODLE_DIR}/public/admin/cli/cron.php >/dev/null 2>&1"
( crontab -u www-data -l 2>/dev/null | grep -v 'admin/cli/cron.php' || true; echo "$CRON_LINE" ) | crontab -u www-data -
systemctl enable --now cron

chown -R root:root "$MOODLE_DIR"
chmod -R 0755 "$MOODLE_DIR"
chown -R www-data:www-data "$DATA_DIR"

sudo -u www-data /usr/bin/php "$CLI_DIR/purge_caches.php" 2>/dev/null || true
systemctl restart apache2

# ---------- Credenciales ------------------------------------------------------
umask 077
cat > "$CRED_FILE" <<EOF
Moodle - credenciales (guárdalas en un sitio seguro y borra este fichero)
Sitio ............ ${SITE_URL}
Nombre corto ..... ${SHORTNAME}
Admin ............ ${ADMIN_USER} / ${ADMIN_PASS}
Base de datos .... ${DB_NAME} / ${DB_USER} / ${DB_PASS}
EOF

# ---------- Comprobaciones finales -------------------------------------------
info "Comprobaciones finales"
HTTP="$(curl -s -o /dev/null -w '%{http_code}' -L "$SITE_URL/" || true)"
ok "GET $SITE_URL/ -> HTTP $HTTP"
echo; echo "--- C3: crontab de www-data y dueños de las carpetas ---"
crontab -u www-data -l
ls -ld "$MOODLE_DIR" "$DATA_DIR"

cat <<EOF

=============================================================================
 Moodle 5.3 instalado.
   URL ............ ${SITE_URL}
   Usuario ........ ${ADMIN_USER}
   Contraseña ..... ${ADMIN_PASS}$([[ $GENERADA_ADMIN -eq 1 ]] && echo " (generada)")  (también en ${CRED_FILE})
   BD ............. ${DB_NAME} / ${DB_USER} / ${DB_PASS}$([[ $GENERADA_DB -eq 1 ]] && echo " (generada)")

 Pendiente en el navegador (para las capturas):
   - C2: página principal con la sesión de admin iniciada.
   - C4: Administración → Informes → Estado del sistema (router en OK).
   - Estado del sistema / Servidor → Entorno / Notificaciones.
=============================================================================
EOF