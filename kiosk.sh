#!/bin/bash
# =============================================================================
# kiosk.sh - Script principale per il digital signage
#
# FUNZIONAMENTO:
# 1. Valida config.json all'avvio
# 2. Esegue autologin (se abilitato) per rinnovare la sessione
# 3. Apre Chromium con profilo persistente (sessione salvata)
# 4. Al primo avvio: modalità configurazione (login manuale)
# 5. Loop infinito: video → pagina web → video → ...
#    Chromium NON viene mai chiuso, la sessione resta attiva.
#    Si alterna la visibilità tra mpv (video) e Chromium (web).
# =============================================================================

CARTELLA_PROGETTO="$(cd "$(dirname "$0")" && pwd)"
FILE_CONFIG="$CARTELLA_PROGETTO/config.json"
FILE_LOG="$CARTELLA_PROGETTO/kiosk.log"
FILE_PRONTO="$CARTELLA_PROGETTO/.configurazione_completata"
DIMENSIONE_MAX_LOG=5242880  # 5MB — oltre questa soglia il log viene ruotato

# --- Funzioni di utilità ---

scrivi_log() {
    # Scrive un messaggio nel file di log con timestamp
    # Ruota il log se supera la dimensione massima
    local messaggio="$1"
    local log_abilitato
    log_abilitato=$(jq -r '.impostazioni.log_abilitato // "true"' "$FILE_CONFIG" 2>/dev/null)
    if [ "$log_abilitato" = "true" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] $messaggio" >> "$FILE_LOG"

        # Rotazione log: se il file supera 5MB, tieni solo le ultime 500 righe
        if [ -f "$FILE_LOG" ]; then
            local dimensione
            dimensione=$(stat -c%s "$FILE_LOG" 2>/dev/null || echo 0)
            if [ "$dimensione" -gt "$DIMENSIONE_MAX_LOG" ]; then
                tail -500 "$FILE_LOG" > "$FILE_LOG.tmp" && mv "$FILE_LOG.tmp" "$FILE_LOG"
            fi
        fi
    fi
}

leggi_config() {
    # Legge un campo dal file di configurazione JSON
    jq -r "$1" "$FILE_CONFIG" 2>/dev/null
}

valida_config() {
    # Verifica che config.json esista e sia JSON valido
    # Restituisce 0 se ok, 1 se errore
    if [ ! -f "$FILE_CONFIG" ]; then
        echo "ERRORE CRITICO: $FILE_CONFIG non trovato!" >&2
        return 1
    fi

    if ! jq empty "$FILE_CONFIG" 2>/dev/null; then
        echo "ERRORE CRITICO: $FILE_CONFIG non è un JSON valido!" >&2
        return 1
    fi

    # Verifica che ci siano le sezioni obbligatorie
    local ha_elementi
    ha_elementi=$(jq 'has("elementi") and has("impostazioni")' "$FILE_CONFIG" 2>/dev/null)
    if [ "$ha_elementi" != "true" ]; then
        echo "ERRORE CRITICO: config.json manca di 'elementi' o 'impostazioni'" >&2
        return 1
    fi

    return 0
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

controlla_chromium() {
    # Verifica che Chromium sia ancora in esecuzione.
    # Se è crashato, lo riavvia automaticamente.
    if [ -n "$PID_CHROMIUM" ] && ! kill -0 "$PID_CHROMIUM" 2>/dev/null; then
        scrivi_log "AVVISO: Chromium crashato (PID $PID_CHROMIUM), riavvio..."

        # Pulisci eventuali processi orfani
        pkill -f "chromium-browser" 2>/dev/null
        sleep 2

        # Riavvia Chromium
        local url_web
        url_web=$(jq -r '.elementi[] | select(.tipo == "web") | .sorgente' "$FILE_CONFIG" | head -1)
        [ -z "$url_web" ] || [ "$url_web" = "null" ] && url_web="about:blank"
        avvia_chromium "$url_web"

        scrivi_log "Chromium riavviato con successo"
    fi
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
            scrivi_log "AVVISO: Finestra Chromium non trovata dopo 20s"
            break
        fi
    done
    sleep 2  # Tempo extra per il rendering della pagina

    # Salva l'ID della finestra di Chromium per uso futuro
    ID_FINESTRA_CHROMIUM=$(xdotool search --name "Chromium" | head -1)
    if [ -z "$ID_FINESTRA_CHROMIUM" ]; then
        scrivi_log "AVVISO: ID finestra Chromium non trovato, alcune funzioni potrebbero non funzionare"
    else
        scrivi_log "Finestra Chromium ID: $ID_FINESTRA_CHROMIUM"
    fi
}

mostra_chromium() {
    # Porta Chromium in primo piano a schermo intero
    # Prima verifica che Chromium sia ancora vivo
    controlla_chromium

    if [ -n "$ID_FINESTRA_CHROMIUM" ]; then
        xdotool windowactivate --sync "$ID_FINESTRA_CHROMIUM" 2>/dev/null
        xdotool windowfocus --sync "$ID_FINESTRA_CHROMIUM" 2>/dev/null
        # Metti a schermo intero con F11
        xdotool key --window "$ID_FINESTRA_CHROMIUM" F11 2>/dev/null
        sleep 0.5
        scrivi_log "Chromium portato in primo piano"
    else
        scrivi_log "AVVISO: Nessuna finestra Chromium da mostrare"
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
    # Se il file non esiste, CONTINUA il loop (non blocca)
    local percorso_video="$1"
    local volume
    volume=$(leggi_config '.impostazioni.volume_video')
    # Fallback: volume 80 se non configurato
    [ -z "$volume" ] || [ "$volume" = "null" ] && volume=80

    if [ ! -f "$percorso_video" ]; then
        scrivi_log "ERRORE: Video non trovato: $percorso_video — salto al prossimo elemento"
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
    # Fallback: 20 secondi se durata non valida
    [ -z "$durata" ] || [ "$durata" = "null" ] && durata=20

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
    # Quando chiude la finestra di istruzioni, il loop parte.

    scrivi_log "=== MODALITÀ CONFIGURAZIONE ==="
    scrivi_log "In attesa che l'utente configuri Chromium..."

    # Porta Chromium in primo piano per l'interazione
    mostra_chromium

    # Mostra istruzioni a schermo tramite una finestra di notifica
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
        # Fallback: aspetta 120 secondi (tempo ragionevole per fare login)
        scrivi_log "Né zenity né xmessage disponibili, attesa 120s per configurazione"
        sleep 120
    fi

    scrivi_log "Configurazione completata, avvio loop"

    # Segna che la configurazione è stata fatta
    touch "$FILE_PRONTO"
}

# --- Programma principale ---

scrivi_log "========================================="
scrivi_log "Avvio kiosk digital signage"
scrivi_log "========================================="

# --- Validazione config.json ---
if ! valida_config; then
    scrivi_log "ERRORE CRITICO: config.json non valido, impossibile avviare"
    # Mostra errore a schermo se possibile
    echo "ERRORE: config.json non valido o mancante. Controlla il file e riprova."
    exit 1
fi
scrivi_log "config.json validato con successo"

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
# Nota: autologin usa Chromium in modalità headless, separata dal Chromium del kiosk.
# Si completa PRIMA che il Chromium visibile venga avviato (nessuna race condition).
autologin_abilitato=$(jq -r '.autologin.abilitato // false' "$FILE_CONFIG")
if [ "$autologin_abilitato" = "true" ]; then
    scrivi_log "Autologin abilitato, esecuzione controllo sessione..."
    # Timeout di 60 secondi per evitare blocchi infiniti
    timeout 60 python3 "$CARTELLA_PROGETTO/autologin.py" 2>&1 | while read -r riga; do
        scrivi_log "$riga"
    done
    esito_autologin=$?
    if [ "$esito_autologin" -eq 124 ]; then
        scrivi_log "AVVISO: Autologin interrotto per timeout (60s)"
    fi
    scrivi_log "Autologin completato"
fi

# --- Avvia Chromium con profilo persistente ---
avvia_chromium "$url_web"

# --- Modalità configurazione (solo al primo avvio o se richiesto) ---
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
    # Se la config è corrotta, salta il ciclo e riprova
    if ! jq empty "$FILE_CONFIG" 2>/dev/null; then
        scrivi_log "AVVISO: config.json corrotto, riprovo tra 10s"
        sleep 10
        continue
    fi

    numero_elementi=$(jq '.elementi | length' "$FILE_CONFIG")

    # Se la playlist è vuota, aspetta e riprova
    if [ "$numero_elementi" -eq 0 ] || [ -z "$numero_elementi" ]; then
        scrivi_log "AVVISO: Playlist vuota, attesa 10s"
        sleep 10
        continue
    fi

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
