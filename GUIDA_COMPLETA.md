# Guida Completa: Digital Signage con Raspberry Pi

## Da zero assoluto a schermo funzionante in reception

---

## PARTE 1: Cosa comprare

### Lista della spesa (una tantum, ~€60-75)

| Cosa | Prezzo circa | Dove |
|------|-------------|------|
| **Raspberry Pi 4 Model B (2GB)** | €40-50 | Amazon, Melopero.com, Kubii.com |
| **Alimentatore USB-C 5V/3A** (ufficiale RPi) | €10 | Stesso negozio del RPi |
| **Scheda microSD 32GB** (classe 10) | €8-10 | Amazon (SanDisk Ultra va benissimo) |
| **Cavo micro-HDMI → HDMI** | €5-8 | Amazon |
| **Case/custodia** (opzionale ma consigliato) | €5-8 | Amazon |

> **NOTA**: Il Raspberry Pi 4 ha porte **micro-HDMI**, non HDMI standard.
> Ti serve il cavo adattatore o un cavo micro-HDMI ↔ HDMI.

### Cosa NON devi comprare
- **Tastiera e mouse**: ti servono SOLO per il setup iniziale. Puoi usare quelli dell'ufficio temporaneamente.
- **Monitor**: userai direttamente la TV della reception.

### Confronto costi con Yodeck

| | Yodeck | Soluzione nostra |
|---|--------|-----------------|
| Hardware | ~€100 | ~€65 (una tantum) |
| Software anno 1 | ~€300 | €0 |
| Software anno 2 | ~€300 | €0 |
| **Totale 2 anni** | **~€700** | **~€65** |

---

## PARTE 2: Preparare la scheda SD con il sistema operativo

### Cosa ti serve sul tuo PC
- Un lettore di schede SD (o adattatore microSD → USB)
- Il software **Raspberry Pi Imager** (gratuito)

### Passi

1. **Scarica Raspberry Pi Imager** dal sito ufficiale:
   `https://www.raspberrypi.com/software/`
   Disponibile per Windows, Mac e Linux.

2. **Inserisci la microSD** nel PC

3. **Apri Raspberry Pi Imager** e:
   - **Sistema operativo**: clicca "CHOOSE OS" → "Raspberry Pi OS (other)" → **"Raspberry Pi OS Lite (64-bit)"**
     (quello SENZA desktop — è intenzionale, ci pensiamo noi al desktop)
   - **Scheda SD**: seleziona la tua microSD
   - **Impostazioni** (icona ingranaggio ⚙️ in basso a destra):
     - **Abilita SSH**: SÌ, con password
     - **Username**: `pi`
     - **Password**: scegli una password (es. `signage2024`) — **annotala!**
     - **Configura WiFi**: inserisci nome e password della rete WiFi dell'ufficio
       (oppure, se usi il cavo Ethernet, salta questo punto)
     - **Locale**: Europe/Rome, tastiera IT
   - Clicca **"WRITE"** e aspetta (5-10 minuti)

4. **Estrai la microSD** dal PC

---

## PARTE 3: Primo avvio del Raspberry Pi

### Collegamento fisico

1. Inserisci la **microSD** nel Raspberry Pi (slot sotto la scheda)
2. Collega il **cavo micro-HDMI** dalla porta micro-HDMI del RPi alla TV
3. Collega **tastiera USB** e **mouse USB** (solo per il setup)
4. Se usi Ethernet, collega il **cavo di rete**
5. Collega l'**alimentatore USB-C** — il RPi si accende automaticamente

### Primo login

Dopo 30-60 secondi vedrai una schermata nera con testo. Fai login:
```
login: pi
password: (quella che hai impostato in Raspberry Pi Imager)
```

### Verifica connessione internet

Scrivi questo comando e premi Invio:
```bash
ping -c 3 google.com
```
Se vedi risposte tipo "64 bytes from...", sei connesso. Se no, controlla WiFi/Ethernet.

---

## PARTE 4: Installazione del software

### 4.1 Copia i file del progetto sul Raspberry

**Opzione A: Da chiavetta USB** (più semplice)
1. Copia la cartella `rpi-signage` su una chiavetta USB dal tuo PC
2. Inserisci la chiavetta nel Raspberry Pi
3. Monta la chiavetta e copia:
```bash
sudo mkdir -p /mnt/usb
sudo mount /dev/sda1 /mnt/usb
cp -r /mnt/usb/rpi-signage /home/pi/rpi-signage
sudo umount /mnt/usb
```

**Opzione B: Via rete con SCP** (da un altro PC sulla stessa rete)
Prima trova l'IP del Raspberry:
```bash
hostname -I
```
Poi dal tuo PC (Windows PowerShell, Mac Terminal, ecc.):
```bash
scp -r rpi-signage/ pi@<IP-RASPBERRY>:/home/pi/rpi-signage
```

### 4.2 Copia anche il video aziendale

Se il video è sulla chiavetta USB:
```bash
sudo mount /dev/sda1 /mnt/usb
cp /mnt/usb/nome_del_video.mp4 /home/pi/video_aziendale.mp4
sudo umount /mnt/usb
```
**Annota il percorso del video**, ti servirà tra poco.

### 4.3 Esegui l'installazione automatica

```bash
cd /home/pi/rpi-signage
sudo bash install.sh
```

Questo script fa tutto da solo:
- Installa i pacchetti necessari (ci vogliono 5-10 minuti)
- Crea l'utente dedicato "kiosk"
- Configura l'avvio automatico
- Attiva il pannello web di configurazione

### 4.4 Configura il video e l'URL

Modifica la configurazione con il tuo video e la tua pagina web:
```bash
sudo nano /home/kiosk/signage/config.json
```

Cambia questi valori:
- `"sorgente"` del video → il percorso del tuo file video
  (es. `/home/kiosk/video/presentazione.mp4`)
- `"sorgente"` della pagina web → l'URL reale del vostro sito fotovoltaico
- `"durata_secondi"` → 20 (o quello che preferisci)

**Per salvare in nano**: premi `Ctrl+O`, poi `Invio`, poi `Ctrl+X` per uscire.

Se hai copiato il video in `/home/pi/`, spostalo nella cartella giusta:
```bash
sudo cp /home/pi/video_aziendale.mp4 /home/kiosk/video/presentazione.mp4
sudo chown kiosk:kiosk /home/kiosk/video/presentazione.mp4
```

### 4.5 Riavvia

```bash
sudo reboot
```

### 4.6 Primo avvio: Login e configurazione del sito web

Dopo il riavvio (~30 secondi), succede questo:

1. Il Raspberry si accende e fa login automatico
2. **Chromium si apre con il sito web** che hai configurato
3. Appare una finestra con le istruzioni: **"MODALITÀ CONFIGURAZIONE"**
4. **Adesso puoi interagire con Chromium normalmente:**
   - Fai login sul sito del fornitore
   - Naviga fino alla pagina della panoramica fotovoltaico
   - Se necessario, mettila a schermo intero dentro il sito
5. **Quando sei sulla pagina giusta, chiudi la finestra delle istruzioni**
6. Il loop parte automaticamente: video → pagina web → video → ...

> **IMPORTANTE**: La sessione del browser viene salvata!
> Al prossimo riavvio del Raspberry, Chromium ricorderà il login e la pagina.
> Non dovrai più rifare questa procedura a meno che la sessione scada sul sito.

> **Se devi rifare il login**: usa il bottone "Riconfigura" nel pannello web
> (http://\<IP-RASPBERRY\>:8080) oppure da SSH:
> ```bash
> sudo rm /home/kiosk/signage/.configurazione_completata
> sudo rm -rf /home/kiosk/signage/.chromium-profilo
> sudo reboot
> ```

---

## PARTE 5: Gestione quotidiana

### Pannello web (la cosa più comoda)

Da qualsiasi computer/telefono sulla stessa rete:
1. Apri il browser
2. Vai a: `http://<IP-DEL-RASPBERRY>:8080`
3. Da lì puoi:
   - Cambiare il video o l'URL
   - Aggiungere nuovi elementi al loop
   - Regolare il volume
   - Riordinare la playlist
   - Riavviare il kiosk

Per trovare l'IP del Raspberry (se non lo ricordi), collegati via SSH:
```bash
ssh pi@raspberrypi.local
hostname -I
```

### Cambiare il video

1. Copia il nuovo video sulla chiavetta USB
2. Collegala al Raspberry
3. Da SSH:
```bash
sudo mount /dev/sda1 /mnt/usb
sudo cp /mnt/usb/nuovo_video.mp4 /home/kiosk/video/
sudo chown kiosk:kiosk /home/kiosk/video/nuovo_video.mp4
sudo umount /mnt/usb
```
4. Dal pannello web, aggiorna il percorso del video

### Accesso SSH (per interventi avanzati)

Da un altro PC sulla stessa rete:
```bash
ssh pi@<IP-DEL-RASPBERRY>
```
(Usa la password che hai impostato all'inizio)

---

## PARTE 6: Risoluzione problemi

### Lo schermo resta nero
- Verifica che il cavo HDMI sia collegato bene
- Prova l'altra porta micro-HDMI del Raspberry
- Collegati via SSH e controlla i log:
  ```bash
  cat /home/kiosk/signage/kiosk.log
  ```

### Il video non parte
- Verifica che il file esista: `ls -la /home/kiosk/video/`
- Verifica il formato: deve essere un video standard (MP4 con H.264 va benissimo)
- Prova manualmente: `mpv --fullscreen /home/kiosk/video/presentazione.mp4`

### La pagina web non si vede
- Verifica che il Raspberry sia connesso a internet: `ping google.com`
- Prova l'URL da un altro PC per verificare che funzioni
- Controlla i log: `cat /home/kiosk/signage/kiosk.log`

### Il pannello web non risponde
- Verifica il servizio: `sudo systemctl status signage-pannello`
- Riavvialo: `sudo systemctl restart signage-pannello`

### Come aggiornare il sistema
Ogni tanto (1 volta al mese):
```bash
ssh pi@<IP-RASPBERRY>
sudo apt update && sudo apt upgrade -y
sudo reboot
```

---

## PARTE 7: Schema riassuntivo

```
┌─────────────────────────────────────────────┐
│              RASPBERRY PI 4                  │
│                                              │
│  ┌─────────┐     ┌─────────────────────┐    │
│  │  mpv     │────▶│  TV Reception       │    │
│  │ (video)  │     │  (via HDMI)         │    │
│  └─────────┘     └─────────────────────┘    │
│       ▲                    ▲                 │
│       │                    │                 │
│  ┌─────────┐     ┌─────────────────────┐    │
│  │kiosk.sh │     │ Chromium kiosk      │    │
│  │ (loop)  │────▶│ (pagina web)        │    │
│  └─────────┘     └─────────────────────┘    │
│       ▲                                      │
│       │                                      │
│  ┌─────────────────────────────────────┐    │
│  │ config.json                         │    │
│  │ (playlist + impostazioni)           │    │
│  └─────────────────────────────────────┘    │
│       ▲                                      │
│       │  (modifica via browser)              │
│  ┌─────────────────────────────────────┐    │
│  │ Pannello Web Flask (:8080)          │    │
│  │ http://<ip-raspberry>:8080          │    │
│  └─────────────────────────────────────┘    │
│                                              │
└─────────────────────────────────────────────┘
        ▲
        │ (da qualsiasi dispositivo in rete)
   ┌─────────┐
   │ PC/Tel.  │
   │ browser  │
   └─────────┘
```

---

## Costi totali

| Voce | Costo |
|------|-------|
| Raspberry Pi 4 (2GB) | ~€45 |
| Alimentatore | ~€10 |
| MicroSD 32GB | ~€8 |
| Cavo micro-HDMI | ~€6 |
| Case | ~€6 |
| Software | **€0** |
| Abbonamento annuale | **€0** |
| **TOTALE** | **~€75 una tantum** |

vs Yodeck: €100 + €300/anno = **€700 in 2 anni**

**Risparmio in 2 anni: ~€625**
