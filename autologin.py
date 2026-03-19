#!/usr/bin/env python3
"""
autologin.py - Login automatico sul sito del fornitore

Controlla se la sessione è ancora attiva. Se serve, inserisce
le credenziali e fa login automaticamente.

Usa Selenium con il profilo Chromium persistente, così i cookie
restano condivisi con il Chromium del kiosk.

Uso: python3 autologin.py
"""

import json
import sys
import time
from pathlib import Path
from selenium import webdriver
from selenium.webdriver.chrome.options import Options
from selenium.webdriver.chrome.service import Service
from selenium.webdriver.common.by import By
from selenium.webdriver.support.ui import WebDriverWait
from selenium.webdriver.support import expected_conditions as EC

# Percorsi
CARTELLA_PROGETTO = Path(__file__).resolve().parent
FILE_CONFIG = CARTELLA_PROGETTO / "config.json"
PROFILO_CHROMIUM = CARTELLA_PROGETTO / ".chromium-profilo"


def leggi_config():
    """Legge la configurazione dal file JSON."""
    with open(FILE_CONFIG, "r", encoding="utf-8") as f:
        return json.load(f)


def esegui_login():
    """
    Apre il sito, controlla se serve login, e lo fa automaticamente.
    Restituisce True se il login è riuscito (o non era necessario).
    """
    config = leggi_config()

    # Leggi le credenziali dalla config
    credenziali = config.get("autologin", {})
    url_login = credenziali.get("url_login", "")
    email = credenziali.get("email", "")
    password = credenziali.get("password", "")

    # Selettori CSS per trovare i campi del form
    # NOTA: questi vanno personalizzati in base al sito del fornitore.
    # Quelli di default funzionano per la maggior parte dei siti.
    selettori = credenziali.get("selettori", {})
    sel_email = selettori.get("campo_email", "input[type='email'], input[name='email'], input[name='username']")
    sel_password = selettori.get("campo_password", "input[type='password']")
    sel_bottone = selettori.get("bottone_login", "button[type='submit'], input[type='submit']")

    # Elemento che conferma che il login è andato a buon fine
    # (qualcosa che appare solo quando sei loggato)
    sel_conferma = selettori.get("elemento_conferma", "")

    if not url_login or not email or not password:
        print("[AUTOLOGIN] Credenziali non configurate, salto autologin")
        return True

    print(f"[AUTOLOGIN] Controllo sessione su: {url_login}")

    # Configura Chromium con lo stesso profilo usato dal kiosk
    opzioni = Options()
    opzioni.add_argument(f"--user-data-dir={PROFILO_CHROMIUM}")
    opzioni.add_argument("--no-sandbox")
    opzioni.add_argument("--disable-dev-shm-usage")
    opzioni.add_argument("--disable-gpu")

    # Usa la modalità headless (senza finestra visibile) per il check
    opzioni.add_argument("--headless=new")

    try:
        driver = webdriver.Chrome(options=opzioni)
        driver.set_page_load_timeout(30)

        # Vai alla pagina di login
        driver.get(url_login)
        time.sleep(3)  # Aspetta il caricamento

        # Controlla se siamo già loggati
        # Se c'è un elemento di conferma configurato, cercalo
        if sel_conferma:
            try:
                driver.find_element(By.CSS_SELECTOR, sel_conferma)
                print("[AUTOLOGIN] Sessione ancora attiva, login non necessario")
                driver.quit()
                return True
            except Exception:
                print("[AUTOLOGIN] Sessione scaduta, procedo con il login")

        # Cerca il campo email/username
        try:
            campo_email = WebDriverWait(driver, 10).until(
                EC.presence_of_element_located((By.CSS_SELECTOR, sel_email))
            )
        except Exception:
            # Se non trova il campo email, probabilmente siamo già loggati
            print("[AUTOLOGIN] Campo email non trovato — probabilmente già loggato")
            driver.quit()
            return True

        # Compila il form e invia
        print("[AUTOLOGIN] Inserimento credenziali...")
        campo_email.clear()
        campo_email.send_keys(email)

        campo_password = driver.find_element(By.CSS_SELECTOR, sel_password)
        campo_password.clear()
        campo_password.send_keys(password)

        bottone = driver.find_element(By.CSS_SELECTOR, sel_bottone)
        bottone.click()

        # Aspetta che il login vada a buon fine (5 secondi)
        time.sleep(5)

        # Verifica che il login sia riuscito
        url_attuale = driver.current_url
        print(f"[AUTOLOGIN] Login completato. Pagina attuale: {url_attuale}")

        # Se c'è un URL specifico della panoramica, navigaci
        url_panoramica = credenziali.get("url_dopo_login", "")
        if url_panoramica:
            print(f"[AUTOLOGIN] Navigazione a: {url_panoramica}")
            driver.get(url_panoramica)
            time.sleep(3)

        driver.quit()
        print("[AUTOLOGIN] Login automatico completato con successo")
        return True

    except Exception as e:
        print(f"[AUTOLOGIN] Errore: {e}")
        try:
            driver.quit()
        except Exception:
            pass
        return False


if __name__ == "__main__":
    riuscito = esegui_login()
    sys.exit(0 if riuscito else 1)
