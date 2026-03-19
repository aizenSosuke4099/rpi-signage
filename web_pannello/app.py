#!/usr/bin/env python3
"""
Pannello web di configurazione per il digital signage.
Permette di modificare la playlist e le impostazioni
tramite un'interfaccia web semplice su porta 8080.
"""

import json
import os
import subprocess
import signal
from pathlib import Path
from flask import Flask, render_template, request, redirect, url_for, flash, jsonify

# Percorso del file di configurazione (nella cartella padre)
CARTELLA_PROGETTO = Path(__file__).resolve().parent.parent
FILE_CONFIG = CARTELLA_PROGETTO / "config.json"

app = Flask(__name__)
app.secret_key = "chiave_segreta_signage_2024"


def leggi_config():
    """Legge e restituisce la configurazione corrente dal file JSON."""
    with open(FILE_CONFIG, "r", encoding="utf-8") as f:
        return json.load(f)


def salva_config(config):
    """Salva la configurazione aggiornata nel file JSON."""
    with open(FILE_CONFIG, "w", encoding="utf-8") as f:
        json.dump(config, f, indent=4, ensure_ascii=False)


@app.route("/")
def pagina_principale():
    """Mostra la pagina principale con la playlist e le impostazioni."""
    config = leggi_config()
    return render_template("index.html", config=config)


@app.route("/aggiorna_elemento", methods=["POST"])
def aggiorna_elemento():
    """Aggiorna un singolo elemento della playlist."""
    config = leggi_config()
    indice = int(request.form["indice"])

    if 0 <= indice < len(config["elementi"]):
        elemento = config["elementi"][indice]
        elemento["sorgente"] = request.form["sorgente"]
        elemento["descrizione"] = request.form["descrizione"]

        # Se è un elemento web, aggiorna anche la durata
        if elemento["tipo"] == "web":
            elemento["durata_secondi"] = int(request.form.get("durata_secondi", 20))

        salva_config(config)
        flash(f"Elemento {indice + 1} aggiornato!", "successo")
    else:
        flash("Indice elemento non valido.", "errore")

    return redirect(url_for("pagina_principale"))


@app.route("/aggiungi_elemento", methods=["POST"])
def aggiungi_elemento():
    """Aggiunge un nuovo elemento alla playlist."""
    config = leggi_config()
    tipo = request.form["tipo"]

    nuovo_elemento = {
        "tipo": tipo,
        "sorgente": request.form["sorgente"],
        "descrizione": request.form["descrizione"]
    }

    # Se è un elemento web, aggiungi la durata
    if tipo == "web":
        nuovo_elemento["durata_secondi"] = int(request.form.get("durata_secondi", 20))

    config["elementi"].append(nuovo_elemento)
    salva_config(config)
    flash(f"Nuovo elemento '{nuovo_elemento['descrizione']}' aggiunto!", "successo")

    return redirect(url_for("pagina_principale"))


@app.route("/rimuovi_elemento/<int:indice>", methods=["POST"])
def rimuovi_elemento(indice):
    """Rimuove un elemento dalla playlist."""
    config = leggi_config()

    if 0 <= indice < len(config["elementi"]):
        rimosso = config["elementi"].pop(indice)
        salva_config(config)
        flash(f"Elemento '{rimosso['descrizione']}' rimosso.", "successo")
    else:
        flash("Indice non valido.", "errore")

    return redirect(url_for("pagina_principale"))


@app.route("/sposta_elemento/<int:indice>/<direzione>", methods=["POST"])
def sposta_elemento(indice, direzione):
    """Sposta un elemento nella playlist (su o giù)."""
    config = leggi_config()
    elementi = config["elementi"]

    if direzione == "su" and indice > 0:
        elementi[indice], elementi[indice - 1] = elementi[indice - 1], elementi[indice]
        salva_config(config)
    elif direzione == "giu" and indice < len(elementi) - 1:
        elementi[indice], elementi[indice + 1] = elementi[indice + 1], elementi[indice]
        salva_config(config)

    return redirect(url_for("pagina_principale"))


@app.route("/aggiorna_impostazioni", methods=["POST"])
def aggiorna_impostazioni():
    """Aggiorna le impostazioni generali."""
    config = leggi_config()

    config["impostazioni"]["volume_video"] = int(request.form.get("volume_video", 80))
    config["impostazioni"]["nascondi_cursore"] = "nascondi_cursore" in request.form
    config["impostazioni"]["log_abilitato"] = "log_abilitato" in request.form

    salva_config(config)
    flash("Impostazioni aggiornate!", "successo")

    return redirect(url_for("pagina_principale"))


@app.route("/riconfigura", methods=["POST"])
def riconfigura():
    """Cancella la sessione Chromium e riavvia per permettere un nuovo login."""
    import shutil
    try:
        # Rimuovi il flag di configurazione completata
        file_pronto = CARTELLA_PROGETTO / ".configurazione_completata"
        if file_pronto.exists():
            file_pronto.unlink()

        # Rimuovi il profilo Chromium (cancella sessione/cookie)
        profilo_chromium = CARTELLA_PROGETTO / ".chromium-profilo"
        if profilo_chromium.exists():
            shutil.rmtree(profilo_chromium)

        # Riavvia il kiosk — rientrerà in modalità configurazione
        subprocess.run(["sudo", "systemctl", "restart", "kiosk"], check=True)
        flash("Sessione cancellata! Il kiosk si riavvierà in modalità configurazione. "
              "Vai alla TV per rifare il login.", "successo")
    except Exception as e:
        flash(f"Errore durante la riconfigurazione: {e}", "errore")

    return redirect(url_for("pagina_principale"))


@app.route("/riavvia_kiosk", methods=["POST"])
def riavvia_kiosk():
    """Riavvia lo script kiosk per applicare le modifiche immediatamente."""
    try:
        subprocess.run(["sudo", "systemctl", "restart", "kiosk"], check=True)
        flash("Kiosk riavviato!", "successo")
    except subprocess.CalledProcessError:
        flash("Errore nel riavvio del kiosk.", "errore")

    return redirect(url_for("pagina_principale"))


@app.route("/stato")
def stato():
    """Restituisce lo stato del sistema in formato JSON (utile per debug)."""
    try:
        risultato = subprocess.run(
            ["systemctl", "is-active", "kiosk"],
            capture_output=True, text=True
        )
        stato_kiosk = risultato.stdout.strip()
    except Exception:
        stato_kiosk = "sconosciuto"

    return jsonify({
        "kiosk": stato_kiosk,
        "config": leggi_config()
    })


if __name__ == "__main__":
    porta = leggi_config()["impostazioni"]["porta_pannello_web"]
    print(f"Pannello web avviato su http://0.0.0.0:{porta}")
    app.run(host="0.0.0.0", port=porta, debug=False)
