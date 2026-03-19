# RPi Digital Signage

Soluzione digital signage open source per Raspberry Pi.
Loop automatico: video aziendale + pagina web (con sessione persistente).

## Cosa fa

- Riproduce un video a schermo intero
- Mostra una pagina web per N secondi (con login salvato)
- Ripete all'infinito: video → web → video → web → ...
- Pannello web su porta 8080 per gestire tutto da browser

## Setup rapido

```bash
sudo bash install.sh
```

Guida completa passo-passo: [GUIDA_COMPLETA.md](GUIDA_COMPLETA.md)

## Struttura

```
├── install.sh          # Installazione automatica
├── kiosk.sh            # Loop principale (video + web)
├── config.json         # Playlist e impostazioni
├── web_pannello/       # Pannello web Flask
│   ├── app.py
│   └── templates/
│       └── index.html
└── GUIDA_COMPLETA.md   # Guida da zero assoluto
```
