#!/bin/bash
set -e

UNATTENDED="${UNATTENDED:-0}"
TIMEZONE="${TIMEZONE:-Europe/Rome}"
ENABLE_ROOT_SSH_PASSWORD="${ENABLE_ROOT_SSH_PASSWORD:-1}"
POSTGRES_VERSION="${POSTGRES_VERSION:-${PG_VERSION:-}}"
POSTGRES_DATA_DIR="${POSTGRES_DATA_DIR:-${DATA_DIR:-}}"

# Verifica che lo script venga eseguito come root
if [ "$EUID" -ne 0 ]; then
  echo "Errore: Lo script deve essere eseguito come root"
  exit 1
fi

# Funzione per mostrare un messaggio informativo
show_info() {
  if [ "$UNATTENDED" = "1" ] || [ ! -t 1 ] || ! command -v whiptail >/dev/null 2>&1; then
    echo "[$1] $2"
    return
  fi
  whiptail --title "$1" --infobox "$2" 6 80
  sleep 1.5
}

# Funzione per mostrare un errore
show_error() {
  local message="$1"
  echo "$message" >&2
  if [ "$UNATTENDED" = "1" ] || [ ! -t 1 ] || ! command -v whiptail >/dev/null 2>&1; then
    exit 1
  fi
  whiptail --title "Errore Critico" --msgbox "$message" 20 80 1
  exit 1
}

# Imposta o aggiunge un parametro in postgresql.conf
set_postgresql_conf() {
  local key="$1"
  local value="$2"
  local file="$3"

  if grep -Eq "^[#[:space:]]*${key}[[:space:]]*=" "$file"; then
    sed -ri "s|^[#[:space:]]*${key}[[:space:]]*=.*|${key} = ${value}|" "$file"
  else
    echo "${key} = ${value}" >> "$file"
  fi
}

# Aggiunge una riga a pg_hba.conf solo se non esiste già
ensure_pg_hba_line() {
  local line="$1"
  local file="$2"

  grep -Fqx "$line" "$file" || echo "$line" >> "$file"
}

configure_timezone_and_ssh() {
  show_info "Sistema" "Configurazione timezone ${TIMEZONE} e accesso SSH root/password..."
  if [ -f "/usr/share/zoneinfo/${TIMEZONE}" ]; then
    ln -snf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime
    echo "${TIMEZONE}" > /etc/timezone
    timedatectl set-timezone "${TIMEZONE}" >/dev/null 2>&1 || true
  fi

  if [ "${ENABLE_ROOT_SSH_PASSWORD}" = "1" ] && [ -f /etc/ssh/sshd_config ]; then
    if grep -Eq '^[#[:space:]]*PermitRootLogin[[:space:]]+' /etc/ssh/sshd_config; then
      sed -ri 's|^[#[:space:]]*PermitRootLogin[[:space:]]+.*|PermitRootLogin yes|' /etc/ssh/sshd_config
    else
      echo 'PermitRootLogin yes' >> /etc/ssh/sshd_config
    fi
    if grep -Eq '^[#[:space:]]*PasswordAuthentication[[:space:]]+' /etc/ssh/sshd_config; then
      sed -ri 's|^[#[:space:]]*PasswordAuthentication[[:space:]]+.*|PasswordAuthentication yes|' /etc/ssh/sshd_config
    else
      echo 'PasswordAuthentication yes' >> /etc/ssh/sshd_config
    fi
    systemctl enable ssh >/dev/null 2>&1 || systemctl enable sshd >/dev/null 2>&1 || true
    systemctl restart ssh >/dev/null 2>&1 || systemctl restart sshd >/dev/null 2>&1 || true
  fi
}

# Imposta la lingua di sistema della VM su Italiano (it_IT.UTF-8) e genera il
# locale, che servira' anche come collate/ctype del cluster PostgreSQL.
configure_locale() {
  show_info "Lingua Sistema" "Configurazione lingua VM su Italiano (it_IT.UTF-8)..."

  # Assicura che il pacchetto locales sia presente (su immagini minime manca)
  command -v locale-gen >/dev/null 2>&1 || apt install -y locales > /dev/null 2>&1 || show_error "Installazione pacchetto locales fallita"

  # Abilita it_IT.UTF-8 in /etc/locale.gen (decommenta o aggiunge)
  if [ -f /etc/locale.gen ] && grep -Eq '^[#[:space:]]*it_IT\.UTF-8[[:space:]]+UTF-8' /etc/locale.gen; then
    sed -ri 's|^[#[:space:]]*(it_IT\.UTF-8[[:space:]]+UTF-8)|\1|' /etc/locale.gen
  else
    echo 'it_IT.UTF-8 UTF-8' >> /etc/locale.gen
  fi

  locale-gen > /dev/null 2>&1 || show_error "Generazione del locale it_IT.UTF-8 fallita"

  # Imposta la lingua di default del sistema (persistente)
  update-locale LANG=it_IT.UTF-8 LANGUAGE=it_IT:it > /dev/null 2>&1 || true

  # Esporta per la sessione corrente cosi' i cluster creati ora ereditano la locale
  export LANG=it_IT.UTF-8 LANGUAGE=it_IT:it LC_ALL=it_IT.UTF-8
}

# Funzione per ottenere la versione di PostgreSQL da installare
get_postgres_version() {
  if [ -n "${POSTGRES_VERSION}" ]; then
    case "${POSTGRES_VERSION}" in
      16|18) echo "${POSTGRES_VERSION}"; return ;;
      *) show_error "POSTGRES_VERSION deve essere 16 o 18." ;;
    esac
  fi
  if [ "$UNATTENDED" = "1" ] || [ ! -t 1 ]; then
    echo "16"
    return
  fi
  local PG_VERSION
  PG_VERSION=$(whiptail --title "Versione PostgreSQL" --menu \
    "Seleziona la versione di PostgreSQL da installare:" 20 80 10 \
    "16" "PostgreSQL 16" \
    "18" "PostgreSQL 18" 3>&1 1>&2 2>&3)

  if [ $? -ne 0 ]; then
    show_error "Installazione annullata dall'utente."
  fi

  echo "$PG_VERSION"
}

# Funzione per ottenere il data directory PostgreSQL
get_postgres_datadir() {
  local version="$1"
  local default_dir="/zucchetti/PostgreSQL/${version}/data"
  local alt_dir="/metriks/PostgreSQL/${version}/data"
  local DATA_DIR

  if [ -n "${POSTGRES_DATA_DIR}" ]; then
    DATA_DIR="${POSTGRES_DATA_DIR}"
  elif [ "$UNATTENDED" = "1" ] || [ ! -t 1 ]; then
    DATA_DIR="${default_dir}"
  else
  DATA_DIR=$(whiptail --title "Data Directory PostgreSQL" --inputbox \
"Inserisci il data directory COMPLETO per PostgreSQL ${version}.

Esempi:
- ${default_dir}
- ${alt_dir}

Nota:
- inserisci il percorso assoluto della cartella dati
- il percorso può essere personalizzato
- se premi Invio senza modificare, verrà usato l'esempio predefinito" 18 90 "${default_dir}" 3>&1 1>&2 2>&3)

  if [ $? -ne 0 ]; then
    show_error "Installazione annullata dall'utente durante la scelta del data directory."
  fi
  fi

  DATA_DIR="$(echo "$DATA_DIR" | xargs)"

  [ -n "$DATA_DIR" ] || show_error "Il data directory non può essere vuoto."
  [[ "$DATA_DIR" = /* ]] || show_error "Il data directory deve essere un percorso assoluto."
  [ "$DATA_DIR" != "/" ] || show_error "Il data directory non può essere '/'."

  echo "$DATA_DIR"
}

# Funzione per stampare i log in caso di errore
print_pg_logs() {
  show_info "Diagnostica" "Stampa dei log per diagnostica..."
  echo "=== Ultimi log di sistema ==="
  journalctl -u postgresql@"${PG_VERSION}-main" -n 20 --since "5 minutes ago" || true
  echo -e "\n=== Contenuto log PostgreSQL ==="
  if [ -d "/var/log/postgresql" ]; then
    ls -la /var/log/postgresql/
  fi
  echo -e "\n=== Ultimo errore dal log principale ==="
  if [ -f "/var/log/postgresql/postgresql-${PG_VERSION}-main.log" ]; then
    grep -i "error" "/var/log/postgresql/postgresql-${PG_VERSION}-main.log" | tail -n 10 || true
  fi
}

# Funzione principale
main() {
  # Verifica e installazione di whiptail
  if ! command -v whiptail &> /dev/null; then
    apt update -y > /dev/null 2>&1
    apt install -y whiptail > /dev/null 2>&1 || show_error "Installazione di whiptail fallita"
  fi

  # Selezione versione PostgreSQL
  PG_VERSION=$(get_postgres_version)

  # Scelta interattiva data directory
  DATA_DIR=$(get_postgres_datadir "$PG_VERSION")
  PG_BASE_DIR="$(dirname "$DATA_DIR")"
  CONF_DIR="/etc/postgresql/${PG_VERSION}/main"
  BACKUP_SCRIPT="${PG_BASE_DIR}/backup.sh"
  BACKUP_DIR="${PG_BASE_DIR}/backup"

  # Inizio configurazione
  show_info "Configurazione" "Inizio configurazione PostgreSQL ${PG_VERSION}"
  show_info "Data Directory" "Verrà utilizzato il data directory:\n${DATA_DIR}"

  # 1. Creazione directory necessarie
  show_info "Creazione Directory" "Creazione delle directory necessarie..."
  mkdir -p "${DATA_DIR}" 2>/dev/null
  mkdir -p "${BACKUP_DIR}"
  mkdir -p "$(dirname "${BACKUP_SCRIPT}")"

  # 2. Installazione pacchetti necessari
  show_info "Installazione Pacchetti" "Installazione dei pacchetti richiesti..."
  apt update -y > /dev/null 2>&1 || show_error "Aggiornamento del sistema fallito"
  apt install -y sudo rsync curl gnupg cron lsb-release gzip cloud-utils ncdu locales postgresql-common postgresql-client-common tzdata openssh-server > /dev/null 2>&1 || show_error "Installazione pacchetti di base fallita"
  configure_timezone_and_ssh
  configure_locale

  # 3. Aggiunta repository PostgreSQL ufficiale
  show_info "Repository PostgreSQL" "Aggiunta del repository ufficiale..."
  DISTRO_CODENAME=$(lsb_release -cs)
  echo "deb http://apt.postgresql.org/pub/repos/apt ${DISTRO_CODENAME}-pgdg main" > /etc/apt/sources.list.d/pgdg.list || show_error "Impossibile creare il file sources.list.d/pgdg.list"

  # Scaricamento e installazione chiave GPG
  curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor -o /etc/apt/trusted.gpg.d/postgresql.gpg > /dev/null 2>&1 || show_error "Impossibile importare la chiave GPG di PostgreSQL"

  # Aggiornamento pacchetti dopo aggiunta repository
  apt update -y > /dev/null 2>&1 || show_error "Aggiornamento del sistema dopo aggiunta repository fallito"

  # 4. Installazione PostgreSQL
  show_info "Installazione PostgreSQL" "Installazione di PostgreSQL ${PG_VERSION}..."
  apt install -y postgresql-${PG_VERSION} > /dev/null 2>&1 || show_error "Installazione di PostgreSQL ${PG_VERSION} fallita"
  systemctl enable postgresql > /dev/null 2>&1 || true

  # Forza la locale italiana sul cluster: collate/ctype = it_IT.UTF-8.
  # L'installazione del pacchetto crea un cluster "main" con la locale di
  # sistema; su installazione pulita (nessun dato) lo rimuoviamo e ricreiamo
  # esplicitamente in italiano per garantire collate/ctype corretti.
  show_info "Locale Cluster" "Impostazione collate/ctype del cluster su it_IT.UTF-8..."
  pg_dropcluster "${PG_VERSION}" main --stop > /dev/null 2>&1 || true
  pg_createcluster --locale it_IT.UTF-8 "${PG_VERSION}" main > /dev/null 2>&1 || show_error "Creazione del cluster ${PG_VERSION}/main (it_IT.UTF-8) fallita"

  # 5. Fermare tutti i processi di PostgreSQL
  show_info "Ferma Processi" "Arresto forzato dei processi PostgreSQL..."
  systemctl stop postgresql@"${PG_VERSION}-main" || true

  # Termina eventuali processi residui
  if pgrep -u postgres > /dev/null; then
    show_info "Uccidi Processi" "Uccisione processi PostgreSQL residui..."
    pkill -u postgres -f "postmaster" || true
    pkill -u postgres -f "postgres" || true
    sleep 3
  fi

  # 6. Modifica home directory utente postgres
  show_info "Configurazione Utente" "Aggiornamento home directory utente postgres..."
  if ! id "postgres" &>/dev/null; then
    show_error "Utente 'postgres' non trovato. Verifica l'installazione di PostgreSQL."
  fi

  if pgrep -u postgres > /dev/null; then
    show_error "Ci sono ancora processi attivi dell'utente 'postgres'. Riprovare dopo averli terminati manualmente."
  fi

  # Modifica home directory
  usermod -d "${PG_BASE_DIR}" postgres || show_error "Fallita modifica home directory utente postgres"

  # 7. Spostamento dati PostgreSQL
  show_info "Spostamento Dati" "Spostamento dei dati in ${DATA_DIR}..."
  systemctl stop postgresql@"${PG_VERSION}-main" || true

  if [ -d "/var/lib/postgresql/${PG_VERSION}/main" ] && [ "$(readlink -f /var/lib/postgresql/${PG_VERSION}/main 2>/dev/null)" != "${DATA_DIR}" ]; then
    rsync -a /var/lib/postgresql/${PG_VERSION}/main/ "${DATA_DIR}/" > /dev/null 2>&1 || show_error "Copia dei dati PostgreSQL fallita"
  elif [ ! -f "${DATA_DIR}/PG_VERSION" ]; then
    sudo -u postgres /usr/lib/postgresql/${PG_VERSION}/bin/initdb --locale=it_IT.UTF-8 -D "${DATA_DIR}" > /dev/null 2>&1 || show_error "Initdb del nuovo data directory fallito"
  fi

  # Garantire che la directory appartenga a postgres
  chown -R postgres:postgres "${DATA_DIR}"
  chmod 700 "${DATA_DIR}"

  # Rimozione eventuale directory o symlink esistente
  rm -rf /var/lib/postgresql/${PG_VERSION}/main

  # Creazione symlink per il data directory (critico per systemd)
  ln -s "${DATA_DIR}" "/var/lib/postgresql/${PG_VERSION}/main"
  chown -h postgres:postgres "/var/lib/postgresql/${PG_VERSION}/main"

  # Modifica il file di configurazione per il nuovo path
  set_postgresql_conf "data_directory" "'${DATA_DIR}'" "${CONF_DIR}/postgresql.conf"

  # 8. Configurazione directory runtime e log
  show_info "Directory Runtime" "Creazione directory per socket e PID..."

  # Creazione directory /run/postgresql
  mkdir -p /run/postgresql
  chown postgres:postgres /run/postgresql
  chmod 755 /run/postgresql

  # Rimozione file di lock residui
  find "${DATA_DIR}" -name postmaster.pid -exec rm -f {} \; 2>/dev/null || true

  # 9. Configurazione systemd per PostgreSQL
  show_info "Configurazione systemd" "Aggiornamento configurazione systemd..."

  # Creazione directory per override
  mkdir -p /etc/systemd/system/postgresql@.service.d/

  # File di override per systemd
  cat > /etc/systemd/system/postgresql@.service.d/override.conf <<EOF
[Service]
Environment=PGDATA=${DATA_DIR}
ExecStartPre=/bin/mkdir -p /run/postgresql
ExecStartPre=/bin/chown -R postgres:postgres /run/postgresql
ExecStartPre=/bin/chmod 755 /run/postgresql
EOF

  # Ricarica systemd
  systemctl daemon-reload

  # 10. Configurazione directory log
  show_info "Directory Log" "Configurazione directory log..."
  LOG_DIR="${DATA_DIR}/pg_log"
  mkdir -p "$LOG_DIR"
  chown postgres:postgres "$LOG_DIR"
  chmod 700 "$LOG_DIR"

  # Aggiornamento configurazione log
  set_postgresql_conf "log_directory" "'pg_log'" "${CONF_DIR}/postgresql.conf"
  set_postgresql_conf "logging_collector" "on" "${CONF_DIR}/postgresql.conf"
  set_postgresql_conf "log_destination" "'stderr'" "${CONF_DIR}/postgresql.conf"
  set_postgresql_conf "log_filename" "'postgresql-%Y-%m-%d_%H%M%S.log'" "${CONF_DIR}/postgresql.conf"

  # 11. Configurazione iniziale PostgreSQL
  show_info "Configurazione Iniziale" "Impostazione password utente PostgreSQL..."

  # Backup temporaneo di pg_hba.conf
  cp "${CONF_DIR}/pg_hba.conf" "${CONF_DIR}/pg_hba.conf.bak"

  # Permette accesso locale senza password durante la configurazione
  {
    echo "local all postgres trust"
    cat "${CONF_DIR}/pg_hba.conf.bak"
  } > "${CONF_DIR}/pg_hba.conf"
  rm "${CONF_DIR}/pg_hba.conf.bak"

  # Avvia PostgreSQL per la configurazione iniziale
  show_info "Avvio Temporaneo" "Avvio temporaneo di PostgreSQL per configurazione..."
  systemctl start postgresql@"${PG_VERSION}-main" || {
    echo "=== Diagnostica ==="
    echo "- Esiste /run/postgresql? $(test -d /run/postgresql && echo Sì || echo No)"
    echo "- Permesso /run/postgresql: $(ls -ld /run/postgresql 2>/dev/null)"
    echo "- Esiste ${DATA_DIR}? $(test -d "${DATA_DIR}" && echo Sì || echo No)"
    echo "- Permesso ${DATA_DIR}: $(ls -ld "${DATA_DIR}" 2>/dev/null)"
    echo "- File postmaster.pid esistente? $(find "${DATA_DIR}" -name postmaster.pid 2>/dev/null)"
    echo "- File postgresql-${PG_VERSION}-main.log esistente? $(find /var/log/postgresql -name 'postgresql-'${PG_VERSION}'-main.log' 2>/dev/null)"

    print_pg_logs
    show_error "Impossibile avviare il servizio PostgreSQL. Controllare i log sopra riportati."
  }

  # Imposta password senza richiederla
  sudo -u postgres psql -c "ALTER USER postgres WITH PASSWORD 'postgres';" > /dev/null 2>&1 || show_error "Impossibile impostare la password di PostgreSQL"

  # Ferma PostgreSQL prima di applicare la configurazione finale
  systemctl stop postgresql@"${PG_VERSION}-main" || true

  # 12. Configurazione file pg_hba.conf (alla fine)
  show_info "Aggiornamento pg_hba.conf" "Modifica configurazione accesso PostgreSQL..."

  # Aggiunge configurazioni di rete
  ensure_pg_hba_line "host    all     all     10.0.100.0/23    md5" "${CONF_DIR}/pg_hba.conf"
  set_postgresql_conf "listen_addresses" "'*'" "${CONF_DIR}/postgresql.conf"

  # Commenta le linee di replication
  sed -i '/replication/ s/^/#/' "${CONF_DIR}/pg_hba.conf"

  # Modifica metodi di autenticazione
  sed -i '/^local[[:space:]]\+all[[:space:]]\+postgres[[:space:]]\+/ s/peer/md5/' "${CONF_DIR}/pg_hba.conf"
  sed -i '/^local[[:space:]]\+all[[:space:]]\+postgres[[:space:]]\+/ s/ident/md5/' "${CONF_DIR}/pg_hba.conf"
  sed -i '/127\.0\.0\.1/ s/ident/md5/' "${CONF_DIR}/pg_hba.conf"
  sed -i '/::1/ s/ident/md5/' "${CONF_DIR}/pg_hba.conf"

  # 13. Configurazione personalizzata Zucchetti per PostgreSQL 16 e 18
  if [ "$PG_VERSION" = "16" ] || [ "$PG_VERSION" = "18" ]; then
    set_postgresql_conf "include_if_exists" "'zucchetti.conf'" "${CONF_DIR}/postgresql.conf"

    cat > "${CONF_DIR}/zucchetti.conf" <<'EOF'
#-----------------------------------------------------------------------------
# NOTE:
#-----------------------------------------------------------------------------
# Postgres ha un degrado di performance quando il numero di thread attivi
# sono doppi o più rispetto al numero di core.
# Nel caso in cui l'AUTOANALYZE (che ha maggiore priorità) occupi troppe
# risorse, abbassare default_statistics_target.
#-----------------------------------------------------------------------------
# Fonte PGTUNE / Zucchetti - base generica da adattare all'hardware reale
#-----------------------------------------------------------------------------
max_connections = 100
shared_buffers = 3584MB
effective_cache_size = 10752MB
maintenance_work_mem = 1434MB
checkpoint_completion_target = 0.9
wal_buffers = -1
default_statistics_target = 1000
random_page_cost = 1.1
effective_io_concurrency = 200
work_mem = 10MB
min_wal_size = 1GB
max_wal_size = 4GB
max_locks_per_transaction = 1024
escape_string_warning = on
standard_conforming_strings = off

#-----------------------------------------------------------------------------
# LOGGER
#-----------------------------------------------------------------------------
log_destination = 'stderr'
logging_collector = on
log_filename = 'postgresql-%Y-%m-%d_%H%M%S.log'
log_rotation_age = 1d
log_rotation_size = 100MB

#-----------------------------------------------------------------------------
# AUTOVACUUM
#-----------------------------------------------------------------------------
autovacuum = on
autovacuum_analyze_scale_factor = 0.1
autovacuum_analyze_threshold = 500
autovacuum_freeze_max_age = 200000000
autovacuum_max_workers = 3
autovacuum_multixact_freeze_max_age = 400000000
autovacuum_naptime = 5s
autovacuum_vacuum_cost_delay = 20ms
autovacuum_vacuum_cost_limit = -1
autovacuum_vacuum_scale_factor = 0.2
autovacuum_vacuum_threshold = 1500
autovacuum_work_mem = -1
EOF

    chown postgres:postgres "${CONF_DIR}/zucchetti.conf"
  fi

  # 14. Riavvio servizio PostgreSQL
  show_info "Avvio Servizio" "Avvio definitivo del servizio PostgreSQL..."

  # Pulizia socket PostgreSQL (in caso di residui)
  rm -rf /var/run/postgresql/${PG_VERSION}-main
  mkdir -p /var/run/postgresql/${PG_VERSION}-main
  chown -R postgres:postgres /var/run/postgresql/${PG_VERSION}-main

  # Avvio del servizio
  systemctl daemon-reexec
  systemctl start postgresql@"${PG_VERSION}-main" || {
    echo "=== Diagnostica ==="
    echo "- Esiste /run/postgresql? $(test -d /run/postgresql && echo Sì || echo No)"
    echo "- Permesso /run/postgresql: $(ls -ld /run/postgresql 2>/dev/null)"
    echo "- Esiste la directory dati? $(test -d "${DATA_DIR}" && echo Sì || echo No)"
    echo "- Permesso directory dati: $(ls -ld "${DATA_DIR}" 2>/dev/null)"
    echo "- File postmaster.pid esistente? $(find "${DATA_DIR}" -name postmaster.pid 2>/dev/null)"
    echo "- File log esistente? $(find /var/log/postgresql -name 'postgresql-'${PG_VERSION}'-main.log' 2>/dev/null)"

    print_pg_logs
    show_error "Impossibile avviare il servizio PostgreSQL. Controllare i log e le informazioni sopra riportate."
  }

  # 15. Installazione script esterni
  show_info "Script Esterni" "Download e configurazione degli script richiesti..."

  # URL degli script
  RENAME_SCRIPT_URL="https://dl.poloinformatico.it/assistenza/Scripts/rename-vg.sh"
  EXPAND_SCRIPT_URL="https://dl.poloinformatico.it/assistenza/Scripts/expand_disk.sh"

  # Percorsi locali
  RENAME_SCRIPT_LOCAL="/etc/rename-vg.sh"
  EXPAND_SCRIPT_LOCAL="/etc/expand_disk.sh"
  SCRIPT_BIN_DIR="/usr/local/bin"

  # Scaricamento e configurazione script rename-vg.sh
  curl -fsSL "$RENAME_SCRIPT_URL" -o "$RENAME_SCRIPT_LOCAL" || show_error "Download rename-vg.sh fallito"
  chmod +x "$RENAME_SCRIPT_LOCAL" || show_error "Permesso esecuzione rename-vg.sh fallito"
  ln -sf "$RENAME_SCRIPT_LOCAL" "$SCRIPT_BIN_DIR/rename-vg" || show_error "Creazione symlink rename-vg fallita"

  # Scaricamento e configurazione script expand_disk.sh
  curl -fsSL "$EXPAND_SCRIPT_URL" -o "$EXPAND_SCRIPT_LOCAL" || show_error "Download expand_disk.sh fallito"
  chmod +x "$EXPAND_SCRIPT_LOCAL" || show_error "Permesso esecuzione expand_disk.sh fallito"
  ln -sf "$EXPAND_SCRIPT_LOCAL" "$SCRIPT_BIN_DIR/expand-disk" || show_error "Creazione symlink expand-disk fallita"

  # 16. Configurazione messaggio di benvenuto
  show_info "Messaggio Login" "Configurazione messaggio iniziale..."

  cat > /etc/profile.d/custom_commands.sh <<'EOF'
#!/bin/bash
# Mostra informazioni sugli script disponibili
if [ -t 1 ]; then
  echo -e "\n\033[1;32mComandi disponibili:\033[0m"
  echo "--------------------"
  echo -e "\033[1;34mrename-vg\033[0m\t- Rinomina il volume group LVM dopo l'espansione del disco"
  echo -e "\033[1;34mexpand-disk\033[0m\t- Espande lo spazio del disco (richiede cloud-utils)"
  echo -e "\nPer maggiori informazioni: \033[1mman <comando>\033[0m\n"
fi
EOF

  chmod +x /etc/profile.d/custom_commands.sh

  # 17. Configurazione backup automatico
  show_info "Backup Automatico" "Configurazione del backup giornaliero..."

  cat > "$BACKUP_SCRIPT" <<EOF
#!/bin/bash
NOW=\$(date +%d-%m-%Y)
backup_dir="${BACKUP_DIR}"

mkdir -p "\$backup_dir" > /dev/null 2>&1
chmod 700 "\$backup_dir"

find "\$backup_dir" -name 'bk_*.backup.gz' -mtime +5 -exec rm -f {} \;

export PGPASSWORD="postgres"
pg_dumpall -U postgres -h 127.0.0.1 -c -f "\$backup_dir/bk_\${NOW}.backup" > /tmp/pgdump.log 2>&1

gzip -9 "\$backup_dir/bk_\${NOW}.backup"
EOF

  chmod 755 "$BACKUP_SCRIPT"

  # Aggiunta programmazione in /etc/crontab
  if ! grep -qF "$BACKUP_SCRIPT" /etc/crontab; then
    echo "30 4 * * * root $BACKUP_SCRIPT" >> /etc/crontab
  fi

  # 18. Messaggio finale
  show_info "Completato" "Configurazione completata con successo!"
  if [ "$UNATTENDED" != "1" ] && [ -t 1 ] && command -v whiptail >/dev/null 2>&1; then
    whiptail --title "Completato" --msgbox "Configurazione completata con successo!\n\nPostgreSQL ${PG_VERSION} è stato configurato e avviato.\n\nData directory:\n${DATA_DIR}\n\nGli script:\n- rename-vg (richiamabile con 'rename-vg')\n- expand-disk (richiamabile con 'expand-disk')\nsono stati installati in /etc e resi eseguibili globalmente.\n\nIl backup giornaliero è stato programmato in /etc/crontab e verrà eseguito ogni giorno alle 04:30.\nCartella backup:\n${BACKUP_DIR}" 22 90 1
  fi
}

# Esecuzione principale
main
