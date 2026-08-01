#!/bin/bash
# =============================================================================
# test_casa.sh - Confronta il costo dei vari modi di riprodurre lo stesso video
#
# PERCHÉ FUNZIONA SENZA UNA TV 4K:
# a 1080p il Pi ha margine, quindi qualunque configurazione "sembra" fluida.
# Ma il costo si misura lo stesso. Se la configurazione attuale consuma il
# 300% di CPU dove un'altra ne consuma il 30%, a 4K (4 volte i pixel) la prima
# è matematicamente destinata a perdere frame e la seconda no.
# Quindi: non guardiamo lo schermo, contiamo CPU e frame persi.
#
# Uso:
#     bash test_casa.sh                    # usa il primo video di config.json
#     bash test_casa.sh /percorso/video.mp4
#     bash test_casa.sh --durata 60        # prova più lunga (default 30s)
#
# Ogni prova occupa lo schermo per la durata scelta. Serve la sessione grafica
# (da SSH: export DISPLAY=:0 prima di lanciarlo).
# =============================================================================

CARTELLA_PROGETTO="$(cd "$(dirname "$0")" && pwd)"
FILE_CONFIG="$CARTELLA_PROGETTO/config.json"
FILE_OUTPUT="$CARTELLA_PROGETTO/test_casa.txt"
DURATA=30
VIDEO=""

VERDE='\033[0;32m'
GIALLO='\033[1;33m'
NC='\033[0m'

titolo() { echo -e "\n${VERDE}=== $1 ===${NC}"; }
avviso() { echo -e "${GIALLO}! $1${NC}"; }

# --- Argomenti ---
while [ $# -gt 0 ]; do
    case "$1" in
        --durata) DURATA="$2"; shift 2 ;;
        *)        VIDEO="$1";  shift ;;
    esac
done

exec > >(tee "$FILE_OUTPUT") 2>&1
export DISPLAY="${DISPLAY:-:0}"

echo "test_casa rpi-signage — $(date '+%Y-%m-%d %H:%M:%S')"

# --- Video da usare ---
if [ -z "$VIDEO" ]; then
    VIDEO=$(jq -r '.elementi[] | select(.tipo=="video") | .sorgente' "$FILE_CONFIG" 2>/dev/null | head -1)
fi
if [ ! -f "$VIDEO" ]; then
    echo "ERRORE: video non trovato: $VIDEO"
    echo "Passane uno esplicito:  bash test_casa.sh /percorso/video.mp4"
    exit 1
fi

titolo "Contesto"
echo "video:  $VIDEO"
if command -v ffprobe &>/dev/null; then
    ffprobe -v error -select_streams v:0 \
        -show_entries stream=codec_name,width,height,r_frame_rate \
        -of csv=p=0:s=' ' "$VIDEO" | sed 's/^/        /'
else
    avviso "ffprobe assente (sudo apt install -y ffmpeg) — non posso mostrare codec/risoluzione"
fi
echo "durata prova: ${DURATA}s per configurazione"
risoluzione=$(xrandr --query 2>/dev/null | grep -oE '[0-9]+x[0-9]+\+0\+0' | head -1 | cut -d+ -f1)
refresh=$(xrandr --query 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\*' | head -1 | tr -d '*')
echo "schermo: ${risoluzione:-sconosciuta} @ ${refresh:-?} Hz"
nproc | sed 's/^/core CPU: /'
echo "(100% CPU = un core saturo; con 4 core il tetto è 400%)"

# --- Strumenti mancanti ---
# mpv non è più installato da install.sh (tolto nel commit fb88bd5), ma serve
# per il confronto C/D: è la configurazione con cui il sistema funzionava prima.
mancanti=""
for strumento in mpv ffprobe; do
    command -v "$strumento" &>/dev/null || mancanti="$mancanti $strumento"
done
if [ -n "$mancanti" ]; then
    avviso "strumenti mancanti:$mancanti"
    avviso "installali per un confronto completo:  sudo apt install -y mpv ffmpeg"
fi

# --- Motore di misura ---
# Usa il builtin `time` di bash: user+sys diviso real dà la CPU% reale,
# comprese tutte le thread del player.
RIGHE_RISULTATO=()

misura() {
    local etichetta="$1"; shift
    local log; log=$(mktemp)
    local tempi

    echo -e "\n--- $etichetta"
    if ! command -v "$1" &>/dev/null; then
        avviso "    $1 non installato — prova saltata"
        RIGHE_RISULTATO+=("$etichetta|n/d|n/d|non installato")
        rm -f "$log"
        return
    fi

    tempi=$( { TIMEFORMAT='%R %U %S'; time "$@" >"$log" 2>&1; } 2>&1 | tail -1 )
    local reale user sys cpu
    reale=$(echo "$tempi" | awk '{print $1}')
    user=$(echo  "$tempi" | awk '{print $2}')
    sys=$(echo   "$tempi" | awk '{print $3}')
    cpu=$(awk -v u="$user" -v s="$sys" -v r="$reale" \
          'BEGIN { if (r > 0) printf "%.0f", (u+s)/r*100; else print "?" }')

    # Frame persi: VLC e mpv li segnalano in modo diverso
    local persi
    persi=$(grep -ciE 'late picture skipped|picture skipped' "$log" 2>/dev/null)
    if [ "$persi" = "0" ]; then
        persi=$(grep -oE 'DROPS=[0-9]+' "$log" 2>/dev/null | tail -1 | cut -d= -f2)
    fi
    [ -z "$persi" ] && persi="0"

    echo "    CPU: ${cpu}%   frame persi: ${persi}   (reale ${reale}s)"
    RIGHE_RISULTATO+=("$etichetta|${cpu}%|${persi}|ok")
    rm -f "$log"
}

titolo "Prove"

# A) Esattamente il comando che gira oggi in kiosk.sh — il riferimento.
misura "A. cvlc  (come kiosk.sh oggi)" \
    cvlc -vv --fullscreen --no-video-title-show --no-osd --no-audio \
         --run-time "$DURATA" --play-and-exit "$VIDEO"

# B) Stesso VLC ma con decodifica hardware e uscita OpenGL ES esplicite.
misura "B. cvlc  + hwdec + vout gles2" \
    cvlc -vv --fullscreen --no-video-title-show --no-osd --no-audio \
         --avcodec-hw=any --vout=gles2 \
         --run-time "$DURATA" --play-and-exit "$VIDEO"

# C) mpv come era prima del passaggio a VLC (commit fb88bd5).
misura "C. mpv   --hwdec=auto --vo=gpu" \
    mpv --fullscreen --no-osc --no-input-default-bindings --terminal=yes \
        --hwdec=auto --vo=gpu --ao=null --length="$DURATA" \
        --term-status-msg='DROPS=${frame-drop-count}' "$VIDEO"

# D) Controllo: mpv con decodifica hardware DISATTIVATA di proposito.
#    Se C e D costano uguale, la decodifica hardware non si sta attivando.
misura "D. mpv   --hwdec=no  (controllo)" \
    mpv --fullscreen --no-osc --no-input-default-bindings --terminal=yes \
        --hwdec=no --vo=gpu --ao=null --length="$DURATA" \
        --term-status-msg='DROPS=${frame-drop-count}' "$VIDEO"

# --- Riepilogo ---
titolo "Riepilogo"
printf "%-34s %8s %14s   %s\n" "configurazione" "CPU" "frame persi" "stato"
printf "%-34s %8s %14s   %s\n" "----------------------------------" "--------" "--------------" "------"
for r in "${RIGHE_RISULTATO[@]}"; do
    IFS='|' read -r e c p s <<< "$r"
    printf "%-34s %8s %14s   %s\n" "$e" "$c" "$p" "$s"
done

cat <<'NOTE'

COME LEGGERLO
  - Confronta A con B e C. Se A costa molto più CPU delle altre, il problema
    è la riga di comando di cvlc in kiosk.sh, non l'hardware del Pi.
  - Confronta C con D. Se costano uguale, la decodifica hardware non si sta
    attivando affatto e il Pi sta decodificando in software.
  - Moltiplica per 4 la CPU misurata per stimare il costo a 4K. Se A supera
    il numero di core x 100%, a 4K perde frame per forza.

RIPRODURRE DAVVERO IL 4K SENZA UNA TV 4K (opzionale)
  Si può forzare l'uscita a 3840x2160 ignorando quello che dichiara la TV.
  Lo schermo diventa illeggibile, ma la misura si legge via SSH.

    sudo nano /boot/firmware/cmdline.txt
    # aggiungi in fondo alla riga (una sola riga, separato da spazio):
    #   video=HDMI-A-1:3840x2160@30D
    sudo reboot
    # poi da SSH:  export DISPLAY=:0 && bash test_casa.sh

  Per tornare indietro: togli quel pezzo da cmdline.txt e riavvia.
NOTE

echo "Output salvato in: $FILE_OUTPUT"
