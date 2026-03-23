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
    # Se Chromium non è stato ancora avviato, non fare nulla.
    if [ -z "$PID_CHROMIUM" ]; then
        return 0
    fi
    if ! kill -0 "$PID_CHROMIUM" 2>/dev/null; then
        scrivi_log "AVVISO: Chromium crashato (PID $PID_CHROMIUM), riavvio..."

        # Pulisci eventuali processi orfani
        pkill -f "chromium" 2>/dev/null
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

    chromium \
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
        --load-extension="$CARTELLA_PROGETTO/chromium-extension" \
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
    # Riproduce un video a schermo intero con VLC
    # VLC si chiude automaticamente a fine video (vlc://quit)
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

    # VLC in modalità schermo intero, senza interfaccia, si chiude a fine video
    cvlc \
        --fullscreen \
        --no-video-title-show \
        --no-osd \
        --no-audio \
        --play-and-exit \
        "$percorso_video" \
        >/dev/null 2>&1

    scrivi_log "Video terminato: $percorso_video"
    return 0
}

mostra_pagina_web() {
    # Mostra la finestra Chromium (già aperta) per la durata specificata
    # Esegue un click periodico per mantenere la sessione attiva
    local durata="$1"
    # Fallback: 20 secondi se durata non valida
    [ -z "$durata" ] || [ "$durata" = "null" ] && durata=20

    scrivi_log "Mostro pagina web per ${durata}s"

    # Porta Chromium in primo piano
    mostra_chromium

    # Click periodico ogni 30 secondi per mantenere la sessione attiva
    local tempo_trascorso=0
    while [ "$tempo_trascorso" -lt "$durata" ]; do
        local attesa=30
        # Se mancano meno di 30 secondi, aspetta solo il tempo rimanente
        local rimanente=$((durata - tempo_trascorso))
        if [ "$rimanente" -lt "$attesa" ]; then
            attesa=$rimanente
        fi
        sleep "$attesa"
        tempo_trascorso=$((tempo_trascorso + attesa))

        # Click al centro della pagina per mantenere la sessione
        if [ "$tempo_trascorso" -lt "$durata" ] && [ -n "$ID_FINESTRA_CHROMIUM" ]; then
            # Rileva centro schermo dinamicamente
            risoluzione=$(xdpyinfo 2>/dev/null | grep dimensions | awk '{print $2}')
            centro_x=$(( $(echo "$risoluzione" | cut -d'x' -f1) / 2 ))
            centro_y=$(( $(echo "$risoluzione" | cut -d'x' -f2) / 2 ))
            [ "$centro_x" -gt 0 ] 2>/dev/null || centro_x=960
            [ "$centro_y" -gt 0 ] 2>/dev/null || centro_y=540
            xdotool mousemove --window "$ID_FINESTRA_CHROMIUM" "$centro_x" "$centro_y"
            xdotool click 1
        fi
    done

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
# Se c'è un url_dopo_login, usalo come URL principale (la dashboard)
url_web=$(jq -r '.autologin.url_dopo_login // ""' "$FILE_CONFIG")
if [ -z "$url_web" ] || [ "$url_web" = "null" ]; then
    url_web=$(jq -r '.elementi[] | select(.tipo == "web") | .sorgente' "$FILE_CONFIG" | head -1)
fi
if [ -z "$url_web" ] || [ "$url_web" = "null" ]; then
    url_web="about:blank"
fi

# --- Autologin: fa login direttamente nel Chromium visibile con xdotool ---
# Legge credenziali da config.json, apre Chromium sul login, digita e clicca.
# Nessun headless: tutto nella finestra reale, cookie salvati nel profilo.
autologin_abilitato=$(jq -r '.autologin.abilitato // false' "$FILE_CONFIG")
url_login=$(jq -r '.autologin.url_login // ""' "$FILE_CONFIG")

if [ "$autologin_abilitato" = "true" ] && [ -n "$url_login" ] && [ "$url_login" != "null" ]; then
    scrivi_log "Autologin abilitato, apertura pagina login..."

    # Avvia Chromium sulla pagina di login
    avvia_chromium "$url_login"

    # Aspetta che la pagina carichi completamente
    scrivi_log "Attesa caricamento pagina login (10s)..."
    sleep 10

    # Leggi credenziali dal config
    login_email=$(jq -r '.autologin.email // ""' "$FILE_CONFIG")
    login_password=$(jq -r '.autologin.password // ""' "$FILE_CONFIG")

    if [ -n "$login_email" ] && [ -n "$login_password" ]; then
        scrivi_log "Inserimento credenziali con xdotool..."

        # Forza il focus sulla finestra di Chromium
        xdotool windowactivate --sync "$ID_FINESTRA_CHROMIUM" 2>/dev/null
        xdotool windowfocus --sync "$ID_FINESTRA_CHROMIUM" 2>/dev/null
        sleep 1

        # Click al centro della pagina per assicurare il focus (coordinate dinamiche)
        risoluzione=$(xdpyinfo 2>/dev/null | grep dimensions | awk '{print $2}')
        centro_x=$(( $(echo "$risoluzione" | cut -d'x' -f1) / 2 ))
        centro_y=$(( $(echo "$risoluzione" | cut -d'x' -f2) / 2 ))
        [ "$centro_x" -gt 0 ] 2>/dev/null || centro_x=960
        [ "$centro_y" -gt 0 ] 2>/dev/null || centro_y=540
        xdotool mousemove --window "$ID_FINESTRA_CHROMIUM" "$centro_x" "$centro_y"
        xdotool click 1
        sleep 1

        # Click sul campo username e digita
        xdotool key --clearmodifiers Tab
        sleep 0.5
        xdotool type --clearmodifiers "$login_email"
        sleep 0.5

        # Tab per passare al campo password e digita
        xdotool key --clearmodifiers Tab
        sleep 0.5
        xdotool type --clearmodifiers "$login_password"
        sleep 0.5

        # Premi Invio per fare login
        xdotool key --clearmodifiers Return
        scrivi_log "Credenziali inserite, attesa login (15s)..."
        sleep 15

        # Naviga alla dashboard se c'è un URL dopo login
        url_dopo_login=$(jq -r '.autologin.url_dopo_login // ""' "$FILE_CONFIG")
        if [ -n "$url_dopo_login" ] && [ "$url_dopo_login" != "null" ]; then
            scrivi_log "Navigazione a dashboard: $url_dopo_login"
            # Usa xdotool per aprire l'URL nella barra degli indirizzi
            xdotool key --clearmodifiers ctrl+l
            sleep 0.5
            xdotool type --clearmodifiers "$url_dopo_login"
            sleep 0.5
            xdotool key --clearmodifiers Return
            scrivi_log "Attesa caricamento dashboard (30s)..."
            sleep 30

            # Click sul bottone panoramica con coordinate fisse per risoluzione
            # Rileva la risoluzione corrente e usa le coordinate giuste
            risoluzione=$(xdpyinfo 2>/dev/null | grep dimensions | awk '{print $2}')
            schermo_x=$(echo "$risoluzione" | cut -d'x' -f1)
            schermo_y=$(echo "$risoluzione" | cut -d'x' -f2)
            scrivi_log "Risoluzione rilevata: ${schermo_x}x${schermo_y}"

            click_x=0
            click_y=0
            if [ "$schermo_y" -ge 2160 ] 2>/dev/null; then
                # 4K (3840x2160) — coordinate stimate da 1440p
                click_x=3752
                click_y=230
                scrivi_log "Modalità 4K (3840x2160)"
            elif [ "$schermo_y" -ge 1440 ] 2>/dev/null; then
                # 1440p (2560x1440) — coordinate verificate
                click_x=2502
                click_y=153
                scrivi_log "Modalità 1440p (2560x1440)"
            elif [ "$schermo_y" -ge 1080 ] 2>/dev/null; then
                # 1080p (1920x1080) — coordinate verificate
                click_x=1870
                click_y=152
                scrivi_log "Modalità 1080p (1920x1080)"
            fi

            if [ "$click_x" -gt 0 ] && [ "$click_y" -gt 0 ]; then
                scrivi_log "Click su bottone panoramica ($click_x, $click_y)"
                xdotool mousemove "$click_x" "$click_y"
                sleep 0.5
                xdotool click 1
                sleep 5
            else
                scrivi_log "AVVISO: Risoluzione non riconosciuta, click panoramica saltato"
            fi
        fi

        scrivi_log "Autologin completato"
    else
        scrivi_log "AVVISO: Credenziali mancanti in config.json"
    fi

    # Segna configurazione come completata
    touch "$FILE_PRONTO"
else
    # --- Avvia Chromium con profilo persistente (senza autologin) ---
    avvia_chromium "$url_web"

    # --- Modalità configurazione (solo al primo avvio) ---
    if [ ! -f "$FILE_PRONTO" ]; then
        modalita_configurazione
    else
        scrivi_log "Configurazione già completata, avvio loop diretto"
        sleep 5
    fi
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
