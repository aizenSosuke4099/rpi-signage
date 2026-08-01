#!/bin/bash
# =============================================================================
# diagnostica.sh - Raccoglie i dati per capire perché i video vanno a scatti
#
# Esegui sul Raspberry collegato allo schermo che dà problemi:
#     bash diagnostica.sh
#
# Lo script è di sola lettura: non modifica niente e non riavvia niente.
# I passi 1-8 girano anche via SSH senza toccare lo schermo.
# Il passo 9 occupa lo schermo per ~20 secondi (va lanciato quando la
# reception è libera, oppure saltato con:  bash diagnostica.sh --senza-video)
#
# Salva tutto anche su diagnostica.txt, così lo puoi allegare/incollare.
# =============================================================================

CARTELLA_PROGETTO="$(cd "$(dirname "$0")" && pwd)"
FILE_CONFIG="$CARTELLA_PROGETTO/config.json"
FILE_OUTPUT="$CARTELLA_PROGETTO/diagnostica.txt"

VERDE='\033[0;32m'
GIALLO='\033[1;33m'
NC='\033[0m'

titolo() { echo -e "\n${VERDE}=== $1 ===${NC}"; }
avviso() { echo -e "${GIALLO}! $1${NC}"; }

# Tutto quello che segue finisce sia a schermo che nel file
exec > >(tee "$FILE_OUTPUT") 2>&1

export DISPLAY="${DISPLAY:-:0}"

echo "diagnostica rpi-signage — $(date '+%Y-%m-%d %H:%M:%S')"

# --- 1. Hardware e sistema operativo ---
titolo "1. Hardware e sistema"
tr -d '\0' < /proc/device-tree/model 2>/dev/null; echo
grep PRETTY_NAME /etc/os-release
echo "kernel: $(uname -srm)"
echo "RAM: $(free -m | awk '/^Mem:/ {print $2" MB"}')"

# --- 2. Configurazione di boot ---
# Su Bookworm/Trixie il file sta in /boot/firmware/, prima era in /boot/
titolo "2. config.txt (righe rilevanti per il video)"
for f in /boot/firmware/config.txt /boot/config.txt; do
    if [ -f "$f" ]; then
        echo "file: $f"
        grep -E '^[[:space:]]*(hdmi_|dtoverlay=vc4|gpu_mem|max_framebuffer|disable_overscan|framebuffer_)' "$f" \
            || echo "  (nessuna riga hdmi_/vc4/gpu_mem attiva)"
        break
    fi
done
echo "--- cmdline.txt ---"
cat /boot/firmware/cmdline.txt 2>/dev/null || cat /boot/cmdline.txt 2>/dev/null

# --- 3. Modo video realmente negoziato con la TV ---
# È il dato più importante: risoluzione E frequenza di aggiornamento.
titolo "3. Uscita video attiva (xrandr)"
if command -v xrandr &>/dev/null && xrandr &>/dev/null; then
    xrandr --query | grep -E ' connected|\*'
else
    avviso "xrandr non disponibile (serve DISPLAY valido: lancialo dalla sessione grafica)"
fi
echo "--- modo secondo il driver KMS ---"
for s in /sys/class/drm/card*-HDMI*/modes; do
    [ -f "$s" ] && { echo "$s:"; head -3 "$s"; }
done

# --- 4. C'è un window manager? ---
# Serve perché xdotool windowminimize/windowactivate funzionino.
titolo "4. Window manager"
if command -v xprop &>/dev/null && xprop -root _NET_SUPPORTING_WM_CHECK 2>/dev/null | grep -q window; then
    nome_wm=$(xprop -root _NET_SUPPORTING_WM_CHECK 2>/dev/null | grep -oE '0x[0-9a-f]+' | head -1)
    echo "WM presente (finestra di controllo: $nome_wm)"
    xprop -id "$nome_wm" _NET_WM_NAME 2>/dev/null
else
    avviso "NESSUN window manager attivo — xdotool windowminimize non fa niente,"
    avviso "quindi Chromium resta a disegnare dietro il video."
fi

# --- 5. Processi: c'è più di una copia del kiosk? ---
titolo "5. Processi in esecuzione"
echo "copie di kiosk.sh:  $(pgrep -fc 'kiosk\.sh')"
echo "processi chromium:  $(pgrep -fc chromium)"
echo "processi vlc:       $(pgrep -fc vlc)"
echo "--- servizi systemd ---"
systemctl is-enabled kiosk.service 2>/dev/null | sed 's/^/kiosk.service: /'
systemctl is-active  kiosk.service 2>/dev/null | sed 's/^/kiosk.service: /'

# --- 6. Alimentazione e temperatura ---
# Un Pi sottoalimentato o in throttling termico rallenta e fa scattare i video.
titolo "6. Throttling e temperatura"
if command -v vcgencmd &>/dev/null; then
    stato=$(vcgencmd get_throttled)
    echo "$stato"
    valore=$(echo "$stato" | cut -d= -f2)
    if [ "$valore" = "0x0" ]; then
        echo "  -> nessun problema di alimentazione o temperatura"
    else
        avviso "  -> PROBLEMA: throttling attivo o avvenuto (vedi bit in get_throttled)"
    fi
    vcgencmd measure_temp
    vcgencmd measure_clock arm | sed 's/^/clock arm: /'
else
    avviso "vcgencmd non disponibile"
fi

# --- 7. Caratteristiche dei video in playlist ---
# Se i file sono già 4K, il Pi 4 non li decodifica in hardware: va rifatto l'encode.
titolo "7. Video in playlist"
if ! command -v ffprobe &>/dev/null; then
    avviso "ffprobe non installato. Installalo con: sudo apt install -y ffmpeg"
else
    jq -r '.elementi[] | select(.tipo=="video") | .sorgente' "$FILE_CONFIG" 2>/dev/null | while read -r v; do
        echo "--- $v"
        if [ ! -f "$v" ]; then
            avviso "    file non trovato"
            continue
        fi
        ffprobe -v error -select_streams v:0 \
            -show_entries stream=codec_name,profile,width,height,r_frame_rate,bit_rate,pix_fmt \
            -show_entries format=duration,bit_rate \
            -of default=noprint_wrappers=1 "$v"
    done
fi

# --- 8. La decodifica software da sola regge il tempo reale? ---
# Decodifica senza mostrare niente a schermo. Se qui fa molti più fps del
# framerate del video, la decodifica NON è il collo di bottiglia: il problema
# è nel percorso di uscita video (scaling da 1080p a 4K fatto in CPU).
titolo "8. Benchmark decodifica software (senza schermo)"
if command -v ffmpeg &>/dev/null; then
    primo_video=$(jq -r '.elementi[] | select(.tipo=="video") | .sorgente' "$FILE_CONFIG" 2>/dev/null | head -1)
    if [ -f "$primo_video" ]; then
        echo "file di prova: $primo_video"
        ffmpeg -hide_banner -benchmark -i "$primo_video" -t 30 -f null - 2>&1 | tail -4
    else
        avviso "nessun video valido da testare"
    fi
else
    avviso "ffmpeg non installato: sudo apt install -y ffmpeg"
fi

# --- 9. Quali moduli usa VLC davvero (test a schermo) ---
# Mostra quale uscita video e quale decoder VLC seleziona, e quanti frame perde.
titolo "9. Test VLC a schermo (20 secondi)"
if [ "$1" = "--senza-video" ]; then
    echo "saltato (--senza-video)"
elif ! command -v cvlc &>/dev/null; then
    avviso "cvlc non trovato"
else
    primo_video=$(jq -r '.elementi[] | select(.tipo=="video") | .sorgente' "$FILE_CONFIG" 2>/dev/null | head -1)
    if [ -f "$primo_video" ]; then
        echo "riproduco 20s di: $primo_video"
        log_vlc=$(mktemp)
        timeout 25 cvlc -vvv --fullscreen --no-audio --no-osd \
            --run-time 20 --play-and-exit "$primo_video" > "$log_vlc" 2>&1
        echo "--- moduli selezionati ---"
        grep -iE "using (video output|decoder|vout display|hardware) module" "$log_vlc" | sort -u
        echo "--- frame persi / in ritardo ---"
        grep -icE "late picture|picture skipped|frame dropp" "$log_vlc" | sed 's/^/occorrenze: /'
        grep -iE "lost|dropped" "$log_vlc" | tail -5
        echo "(log completo in $log_vlc)"
    else
        avviso "nessun video valido da testare"
    fi
fi

titolo "Fine"
echo "Output salvato in: $FILE_OUTPUT"
