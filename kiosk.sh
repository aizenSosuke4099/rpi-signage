#!/bin/bash
# =============================================================================
# kiosk.sh - Script principale per il digital signage
#
# FUNZIONAMENTO:
# 1. All'avvio, apre Chromium con profilo persistente (sessione salvata)
# 2. Entra in "modalità configurazione": l'utente può fare login,
#    navigare alla pagina giusta, ecc. Quando è pronto, preme F5.
# 3. Parte il loop infinito: video → pagina web → video → ...
#    Chromium NON viene mai chiuso, la sessione resta attiva.
#    Si alterna la visibilità tra mpv (video) e Chromium (web).
# =============================================================================

CARTELLA_PROGETTO="$(cd "$(dirname "$0")" && pwd)"
FILE_CONFIG="$CARTELLA_PROGETTO/config.json"
FILE_LOG="$CARTELLA_PROGETTO/kiosk.log"
FILE_PRONTO="$CARTELLA_PROGETTO/.configurazione_completata"

# --- Funzioni di utilità ---

scrivi_log() {
    # Scrive un messaggio nel file di log con timestamp
    local messaggio="$1"
    local log_abilitato
    log_abilitato=$(jq -r '.impostazioni.log_abilitato' "$FILE_CONFIG")
    if [ "$log_abilitato" = "true" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] $messaggio" >> "$FILE_LOG"
    fi
}

leggi_config() {
    # Legge un campo dal file di configurazione JSON
    jq -r "$1" "$FILE_CONFIG"
}

attendi_display() {
    # Aspetta che il display X sia disponibile
    local tentativi=0
    while ! xdpyinfo -display :0 >/dev/null 2>&1; do
        sleep 1
        tentativi=$((tentativi + 1))
        if [ $tentativi -ge 30 ]; then
            scrivi_log "ERRORE: Display :0 non disponibile dopo 30 secondi"
            exit 1
        fi
    done
    scrivi_log "Display :0 disponibile"
}

avvia_chromium() {
    # Avvia Chromium con profilo persistente (mantiene login e sessione)
    # NON usa --incognito, così i cookie e la sessione restano salvati su disco
    local url="$1"

    scrivi_log "Avvio Chromium con profilo persistente: $url"

    chromium-browser \
        --noerrdialogs \
        --disable-infobars \
        --disable-session-crashed-bubble \
        --disable-translate \
        --no-first-run \
        --start-fullscreen \
        --disable-pinch \
        --overscroll-history-navigation=0 \
        --user-data-dir="$CARTELLA_PROGETTO/.chromium-profilo" \
        --check-for-update-interval=31536000 \
        "$url" \
        >/dev/null 2>&1 &

    PID_CHROMIUM=$!
    scrivi_log "Chromium avviato (PID: $PID_CHROMIUM)"

    # Aspetta che la finestra di Chromium sia visibile
    local tentativi=0
    while ! xdotool search --name "Chromium" >/dev/null 2>&1; do
        sleep 1
        tentativi=$((tentativi + 1))
        if [ $tentativi -ge 20 ]; then
            scrivi_log "AVVISO: Finestra Chromium non trovata dopo 20s, riprovo..."
            break
        fi
    done
    sleep 2  # Tempo extra per il rendering della pagina

    # Salva l'ID della finestra di Chromium per uso futuro
    ID_FINESTRA_CHROMIUM=$(xdotool search --name "Chromium" | head -1)
    scrivi_log "Finestra Chromium ID: $ID_FINESTRA_CHROMIUM"
}

mostra_chromium() {
    # Porta Chromium in primo piano a schermo intero
    if [ -n "$ID_FINESTRA_CHROMIUM" ]; then
        xdotool windowactivate --sync "$ID_FINESTRA_CHROMIUM" 2>/dev/null
        xdotool windowfocus --sync "$ID_FINESTRA_CHROMIUM" 2>/dev/null
        # Metti a schermo intero con F11
        xdotool key --window "$ID_FINESTRA_CHROMIUM" F11 2>/dev/null
        sleep 0.5
        scrivi_log "Chromium portato in primo piano"
    fi
}

nascondi_chromium() {
    # Minimizza/nasconde la finestra di Chromium
    if [ -n "$ID_FINESTRA_CHROMIUM" ]; then
        xdotool windowminimize "$ID_FINESTRA_CHROMIUM" 2>/dev/null
        scrivi_log "Chromium nascosto"
    fi
}

riproduci_video() {
    # Riproduce un video a schermo intero con mpv
    # mpv si apre sopra tutto, e si chiude automaticamente a fine video
    local percorso_video="$1"
    local volume
    volume=$(leggi_config '.impostazioni.volume_video')

    if [ ! -f "$percorso_video" ]; then
        scrivi_log "ERRORE: Video non trovato: $percorso_video"
        sleep 5
        return 1
    fi

    scrivi_log "Riproduzione video: $percorso_video (volume: $volume%)"

    # Nascondi Chromium prima di mostrare il video
    nascondi_chromium

    # mpv in modalità schermo intero, senza controlli, si chiude a fine video
    mpv \
        --fullscreen \
        --no-osc \
        --no-input-default-bindings \
        --no-terminal \
        --volume="$volume" \
        --hwdec=auto \
        --gpu-context=auto \
        --ontop \
        "$percorso_video" \
        >/dev/null 2>&1

    scrivi_log "Video terminato: $percorso_video"
    return 0
}

mostra_pagina_web() {
    # Mostra la finestra Chromium (già aperta) per la durata specificata
    local durata="$1"

    scrivi_log "Mostro pagina web per ${durata}s"

    # Porta Chromium in primo piano
    mostra_chromium

    # Aspetta la durata configurata
    sleep "$durata"

    scrivi_log "Tempo pagina web scaduto"
}

modalita_configurazione() {
    # Modalità interattiva: l'utente può navigare in Chromium
    # per fare login e raggiungere la pagina desiderata.
    # Premendo F5 si avvia il loop.

    scrivi_log "=== MODALITÀ CONFIGURAZIONE ==="
    scrivi_log "In attesa che l'utente configuri Chromium e prema F5..."

    # Mostra un messaggio sulla schermata usando xmessage (se disponibile)
    # oppure mostra Chromium direttamente
    mostra_chromium

    # Mostra istruzioni a schermo tramite una finestra di notifica
    # (usa notify-send se disponibile, altrimenti scrive nel terminale)
    if command -v zenity &>/dev/null; then
        zenity --info \
            --title="Configurazione Signage" \
            --text="MODALITÀ CONFIGURAZIONE\n\n1. Fai login nel sito\n2. Naviga alla pagina della panoramica\n3. Quando sei pronto, CHIUDI questa finestra\n\nIl loop partirà automaticamente." \
            --width=400 \
            2>/dev/null
    elif command -v xmessage &>/dev/null; then
        xmessage -center \
            "MODALITÀ CONFIGURAZIONE

1. Fai login nel sito
2. Naviga alla pagina della panoramica
3. Quando sei pronto, CHIUDI questa finestra

Il loop partirà automaticamente." \
            2>/dev/null
    else
        # Fallback: aspetta che l'utente crei il file .configurazione_completata
        echo ""
        echo "==========================================="
        echo "  MODALITÀ CONFIGURAZIONE"
        echo "==========================================="
        echo ""
        echo "  Chromium è aperto. Fai login e naviga alla"
        echo "  pagina che vuoi mostrare."
        echo ""
        echo "  Quando sei pronto, premi INVIO qui..."
        echo ""
        read -r
    fi

    scrivi_log "Configurazione completata, avvio loop"

    # Segna che la configurazione è stata fatta
    touch "$FILE_PRONTO"
}

# --- Programma principale ---

scrivi_log "========================================="
scrivi_log "Avvio kiosk digital signage"
scrivi_log "========================================="

# Aspetta che il display sia pronto
export DISPLAY=:0
attendi_display

# Nascondi il cursore del mouse se configurato
nascondi_cursore=$(leggi_config '.impostazioni.nascondi_cursore')
if [ "$nascondi_cursore" = "true" ]; then
    unclutter -idle 0.5 -root &
    scrivi_log "Cursore mouse nascosto"
fi

# Disabilita screensaver e risparmio energetico
xset s off
xset -dpms
xset s noblank
scrivi_log "Screensaver e risparmio energetico disabilitati"

# --- Trova l'URL dell'elemento web nella config ---
url_web=$(jq -r '.elementi[] | select(.tipo == "web") | .sorgente' "$FILE_CONFIG" | head -1)
if [ -z "$url_web" ] || [ "$url_web" = "null" ]; then
    url_web="about:blank"
fi

# --- Autologin: controlla/rinnova la sessione prima di aprire Chromium ---
autologin_abilitato=$(jq -r '.autologin.abilitato // false' "$FILE_CONFIG")
if [ "$autologin_abilitato" = "true" ]; then
    scrivi_log "Autologin abilitato, esecuzione controllo sessione..."
    python3 "$CARTELLA_PROGETTO/autologin.py" 2>&1 | while read -r riga; do
        scrivi_log "$riga"
    done
    scrivi_log "Autologin completato"
fi

# --- Avvia Chromium con profilo persistente ---
avvia_chromium "$url_web"

# --- Modalità configurazione (solo al primo avvio o se richiesto) ---
# Se non è mai stata fatta la configurazione, entra in modalità configurazione
# per permettere all'utente di fare login e navigare alla pagina giusta.
# Al riavvio successivo, l'autologin + profilo persistente gestiscono tutto.
if [ ! -f "$FILE_PRONTO" ]; then
    modalita_configurazione
else
    scrivi_log "Configurazione già completata, avvio loop diretto"
    # Piccola pausa per permettere a Chromium di caricare la sessione salvata
    sleep 5
fi

# --- Loop principale infinito ---
scrivi_log "=== INIZIO LOOP PRINCIPALE ==="

while true; do
    # Rileggi la config ad ogni ciclo (permette modifiche a caldo)
    numero_elementi=$(jq '.elementi | length' "$FILE_CONFIG")

    for (( i=0; i<numero_elementi; i++ )); do
        tipo=$(jq -r ".elementi[$i].tipo" "$FILE_CONFIG")
        sorgente=$(jq -r ".elementi[$i].sorgente" "$FILE_CONFIG")
        descrizione=$(jq -r ".elementi[$i].descrizione" "$FILE_CONFIG")

        scrivi_log "--- Elemento $((i+1))/$numero_elementi: $descrizione ---"

        case "$tipo" in
            "video")
                riproduci_video "$sorgente"
                ;;
            "web")
                durata=$(jq -r ".elementi[$i].durata_secondi" "$FILE_CONFIG")
                mostra_pagina_web "$durata"
                ;;
            *)
                scrivi_log "ATTENZIONE: Tipo sconosciuto '$tipo', salto elemento"
                ;;
        esac

        # Piccola pausa tra un elemento e l'altro per evitare glitch
        sleep 1
    done

    scrivi_log "Ciclo completato, ripartenza..."
done
