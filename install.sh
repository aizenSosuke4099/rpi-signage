#!/bin/bash
# =============================================================================
# install.sh - Installazione automatica del digital signage su Raspberry Pi
#
# Esegui con: sudo bash install.sh
#
# Cosa fa questo script:
# 1. Installa tutti i pacchetti necessari (mpv, chromium, flask, ecc.)
# 2. Crea un utente dedicato "kiosk" per il digital signage
# 3. Copia i file del progetto nella home dell'utente kiosk
# 4. Configura l'auto-login e l'avvio automatico
# 5. Crea i servizi systemd per kiosk e pannello web
# =============================================================================

set -e  # Interrompi lo script al primo errore

# Colori per i messaggi nel terminale
VERDE='\033[0;32m'
GIALLO='\033[1;33m'
ROSSO='\033[0;31m'
NC='\033[0m' # Reset colore

# Cartella dove si trova questo script
CARTELLA_SCRIPT="$(cd "$(dirname "$0")" && pwd)"

stampa_info()    { echo -e "${VERDE}[INFO]${NC} $1"; }
stampa_avviso()  { echo -e "${GIALLO}[AVVISO]${NC} $1"; }
stampa_errore()  { echo -e "${ROSSO}[ERRORE]${NC} $1"; }

# --- Verifiche preliminari ---

if [ "$EUID" -ne 0 ]; then
    stampa_errore "Questo script deve essere eseguito come root (usa: sudo bash install.sh)"
    exit 1
fi

stampa_info "========================================="
stampa_info "  Installazione Digital Signage per RPi"
stampa_info "========================================="
echo ""

# --- 1. Aggiornamento sistema e installazione pacchetti ---

stampa_info "Aggiornamento lista pacchetti..."
apt-get update

stampa_info "Installazione pacchetti necessari..."
apt-get install -y \
    xserver-xorg \
    x11-xserver-utils \
    xinit \
    openbox \
    chromium \
    mpv \
    unclutter \
    jq \
    xdotool \
    zenity \
    python3-flask \
    python3-pip \
    chromium-driver \
    lightdm

stampa_info "Pacchetti installati con successo"

# Installa Selenium per l'autologin
stampa_info "Installazione Selenium per autologin..."
pip3 install selenium --break-system-packages
stampa_info "Selenium installato"

# --- 2. Creazione utente kiosk (se non esiste) ---

UTENTE_KIOSK="kiosk"
HOME_KIOSK="/home/$UTENTE_KIOSK"

if ! id "$UTENTE_KIOSK" &>/dev/null; then
    stampa_info "Creazione utente '$UTENTE_KIOSK'..."
    useradd -m -s /bin/bash "$UTENTE_KIOSK"
    # Aggiungi ai gruppi necessari per accesso video/audio
    usermod -aG video,audio,input,tty "$UTENTE_KIOSK"
    stampa_info "Utente '$UTENTE_KIOSK' creato"
else
    stampa_avviso "Utente '$UTENTE_KIOSK' esiste già"
fi

# --- 3. Copia file del progetto ---

stampa_info "Copia file del progetto in $HOME_KIOSK/signage..."

CARTELLA_DEST="$HOME_KIOSK/signage"
mkdir -p "$CARTELLA_DEST"
mkdir -p "$HOME_KIOSK/video"  # Cartella per i video

# Copia tutti i file del progetto
cp "$CARTELLA_SCRIPT/kiosk.sh" "$CARTELLA_DEST/"
cp "$CARTELLA_SCRIPT/config.json" "$CARTELLA_DEST/"
cp -r "$CARTELLA_SCRIPT/web_pannello" "$CARTELLA_DEST/"

# Rendi eseguibile lo script kiosk
chmod +x "$CARTELLA_DEST/kiosk.sh"

# Imposta i permessi corretti
chown -R "$UTENTE_KIOSK:$UTENTE_KIOSK" "$HOME_KIOSK"

stampa_info "File copiati"

# --- 4. Configurazione auto-login con LightDM ---

stampa_info "Configurazione auto-login..."

# Configura LightDM per auto-login dell'utente kiosk
mkdir -p /etc/lightdm/lightdm.conf.d
cat > /etc/lightdm/lightdm.conf.d/50-kiosk.conf << 'LIGHTDM'
[Seat:*]
autologin-user=kiosk
autologin-user-timeout=0
user-session=kiosk-signage
LIGHTDM

stampa_info "Auto-login configurato"

# --- 5. Configurazione sessione Openbox per il kiosk ---

stampa_info "Configurazione sessione desktop kiosk..."

# Crea il file .desktop per la sessione kiosk
cat > /usr/share/xsessions/kiosk-signage.desktop << 'SESSIONE'
[Desktop Entry]
Name=Kiosk Signage
Exec=/home/kiosk/signage/kiosk.sh
Type=Application
SESSIONE

# Configura Openbox per avviare il kiosk (fallback)
mkdir -p "$HOME_KIOSK/.config/openbox"
cat > "$HOME_KIOSK/.config/openbox/autostart" << 'AUTOSTART'
# Avvia lo script kiosk digital signage
/home/kiosk/signage/kiosk.sh &
AUTOSTART

chown -R "$UTENTE_KIOSK:$UTENTE_KIOSK" "$HOME_KIOSK/.config"

stampa_info "Sessione desktop configurata"

# --- 6. Creazione servizio systemd per il pannello web ---

stampa_info "Creazione servizio systemd per il pannello web..."

cat > /etc/systemd/system/signage-pannello.service << 'SERVIZIO'
[Unit]
Description=Pannello Web Digital Signage
After=network.target

[Service]
Type=simple
User=kiosk
WorkingDirectory=/home/kiosk/signage/web_pannello
ExecStart=/usr/bin/python3 /home/kiosk/signage/web_pannello/app.py
Restart=always
RestartSec=5
Environment=PYTHONDONTWRITEBYTECODE=1

[Install]
WantedBy=multi-user.target
SERVIZIO

# Abilita e avvia il servizio del pannello web
systemctl daemon-reload
systemctl enable signage-pannello.service
stampa_info "Servizio pannello web creato e abilitato"

# --- 7. Creazione servizio systemd per il kiosk (come backup) ---

cat > /etc/systemd/system/kiosk.service << 'SERVIZIO_KIOSK'
[Unit]
Description=Kiosk Digital Signage
After=graphical.target

[Service]
Type=simple
User=kiosk
Environment=DISPLAY=:0
ExecStart=/home/kiosk/signage/kiosk.sh
Restart=always
RestartSec=10

[Install]
WantedBy=graphical.target
SERVIZIO_KIOSK

systemctl daemon-reload
systemctl enable kiosk.service

stampa_info "Servizio kiosk creato e abilitato"

# --- 8. Configurazione risparmio energetico (disabilitato) ---

stampa_info "Disabilitazione risparmio energetico schermo..."

# Evita che lo schermo vada in standby
if [ -f /etc/lightdm/lightdm.conf.d/50-kiosk.conf ]; then
    # Aggiungi xserver-command per disabilitare dpms
    sed -i '/\[Seat:\*\]/a xserver-command=X -s 0 -dpms' /etc/lightdm/lightdm.conf.d/50-kiosk.conf 2>/dev/null || true
fi

# --- 9. Riepilogo finale ---

echo ""
stampa_info "========================================="
stampa_info "  INSTALLAZIONE COMPLETATA!"
stampa_info "========================================="
echo ""
stampa_info "Riepilogo:"
stampa_info "  - Utente kiosk:        $UTENTE_KIOSK"
stampa_info "  - File progetto:       $CARTELLA_DEST/"
stampa_info "  - Cartella video:      $HOME_KIOSK/video/"
stampa_info "  - Pannello web:        http://<IP-RASPBERRY>:8080"
stampa_info "  - Configurazione:      $CARTELLA_DEST/config.json"
echo ""
stampa_avviso "PROSSIMI PASSI:"
stampa_avviso "  1. Copia il tuo video in: $HOME_KIOSK/video/"
stampa_avviso "  2. Modifica config.json con il percorso video e URL corretti"
stampa_avviso "  3. Riavvia il Raspberry Pi: sudo reboot"
stampa_avviso "  4. Al primo avvio: Chromium si apre, fai login e naviga"
stampa_avviso "     alla pagina giusta, poi chiudi la finestra di istruzioni."
stampa_avviso "     Da quel momento il loop parte automaticamente."
stampa_avviso "     La sessione resta salvata anche dopo un riavvio."
echo ""
stampa_info "Dopo il riavvio, il signage partirà automaticamente!"
stampa_info "Pannello web disponibile su porta 8080 dalla rete locale."
echo ""
stampa_info "COMANDI UTILI:"
stampa_info "  Rifare il login:  sudo rm $CARTELLA_DEST/.configurazione_completata"
stampa_info "                    sudo rm -rf $CARTELLA_DEST/.chromium-profilo"
stampa_info "                    sudo reboot"
echo ""
