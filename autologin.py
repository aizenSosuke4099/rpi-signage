#!/usr/bin/env python3
"""
autologin.py - Login automatico sul sito del fornitore

Controlla se la sessione è ancora attiva. Se serve, inserisce
le credenziali e fa login automaticamente.

Usa Selenium con il profilo Chromium persistente, così i cookie
restano condivisi con il Chromium del kiosk.

NOTA: Questo script gira in modalità headless (senza finestra visibile)
e si completa PRIMA che il Chromium del kiosk venga avviato.
Non c'è conflitto di profilo perché sono sequenziali.

Uso: python3 autologin.py
"""

import json
import sys
import time
import traceback
from pathlib import Path

try:
    from selenium import webdriver
    from selenium.webdriver.chrome.options import Options
    from selenium.webdriver.common.by import By
    from selenium.webdriver.support.ui import WebDriverWait
    from selenium.webdriver.support import expected_conditions as EC
    from selenium.common.exceptions import TimeoutException, WebDriverException
except ImportError:
    print("[AUTOLOGIN] ERRORE: Selenium non installato. Esegui: pip3 install selenium --break-system-packages")
    sys.exit(1)

# Percorsi
CARTELLA_PROGETTO = Path(__file__).resolve().parent
FILE_CONFIG = CARTELLA_PROGETTO / "config.json"
PROFILO_CHROMIUM = CARTELLA_PROGETTO / ".chromium-profilo"

# Timeout globale per tutte le operazioni di rete (secondi)
TIMEOUT_PAGINA = 30
TIMEOUT_ELEMENTO = 15


def leggi_config():
    """Legge la configurazione dal file JSON con gestione errori."""
    try:
        with open(FILE_CONFIG, "r", encoding="utf-8") as f:
            return json.load(f)
    except FileNotFoundError:
        print(f"[AUTOLOGIN] ERRORE: {FILE_CONFIG} non trovato")
        return None
    except json.JSONDecodeError as e:
        print(f"[AUTOLOGIN] ERRORE: config.json non è JSON valido: {e}")
        return None


def crea_driver():
    """Crea e restituisce un'istanza del driver Chromium configurata."""
    opzioni = Options()
    opzioni.add_argument(f"--user-data-dir={PROFILO_CHROMIUM}")
    opzioni.add_argument("--no-sandbox")
    opzioni.add_argument("--disable-dev-shm-usage")
    opzioni.add_argument("--disable-gpu")
    # Modalità headless: nessuna finestra visibile
    opzioni.add_argument("--headless=new")

    driver = webdriver.Chrome(options=opzioni)
    driver.set_page_load_timeout(TIMEOUT_PAGINA)
    driver.set_script_timeout(TIMEOUT_PAGINA)
    # Timeout implicito per trovare elementi
    driver.implicitly_wait(5)

    return driver


def esegui_login():
    """
    Apre il sito, controlla se serve login, e lo fa automaticamente.
    Restituisce True se il login è riuscito (o non era necessario).
    """
    config = leggi_config()
    if config is None:
        return False

    # Leggi le credenziali dalla config
    credenziali = config.get("autologin", {})
    url_login = credenziali.get("url_login", "")
    email = credenziali.get("email", "")
    password = credenziali.get("password", "")

    # Selettori CSS per trovare i campi del form
    selettori = credenziali.get("selettori", {})
    sel_email = selettori.get("campo_email", "input[type='email'], input[name='email'], input[name='username']")
    sel_password = selettori.get("campo_password", "input[type='password']")
    sel_bottone = selettori.get("bottone_login", "button[type='submit'], input[type='submit']")
    sel_conferma = selettori.get("elemento_conferma", "")

    if not url_login or not email or not password:
        print("[AUTOLOGIN] Credenziali non configurate, salto autologin")
        return True

    print(f"[AUTOLOGIN] Controllo sessione su: {url_login}")

    driver = None
    try:
        driver = crea_driver()

        # Vai alla pagina di login
        try:
            driver.get(url_login)
        except TimeoutException:
            print(f"[AUTOLOGIN] ERRORE: Timeout caricamento {url_login} ({TIMEOUT_PAGINA}s)")
            return False

        time.sleep(3)  # Aspetta il rendering JavaScript

        # Controlla se siamo già loggati (se c'è un selettore di conferma)
        if sel_conferma:
            try:
                driver.find_element(By.CSS_SELECTOR, sel_conferma)
                print("[AUTOLOGIN] Sessione ancora attiva, login non necessario")
                return True
            except Exception:
                print("[AUTOLOGIN] Sessione scaduta, procedo con il login")

        # Cerca il campo email/username
        try:
            campo_email = WebDriverWait(driver, TIMEOUT_ELEMENTO).until(
                EC.presence_of_element_located((By.CSS_SELECTOR, sel_email))
            )
        except TimeoutException:
            # Se non trova il campo email, probabilmente siamo già loggati
            print("[AUTOLOGIN] Campo email non trovato — probabilmente già loggato")
            return True

        # Compila il form e invia
        print("[AUTOLOGIN] Inserimento credenziali...")
        campo_email.clear()
        campo_email.send_keys(email)

        try:
            campo_password = driver.find_element(By.CSS_SELECTOR, sel_password)
        except Exception:
            print("[AUTOLOGIN] ERRORE: Campo password non trovato con selettore: " + sel_password)
            return False

        campo_password.clear()
        campo_password.send_keys(password)

        try:
            bottone = driver.find_element(By.CSS_SELECTOR, sel_bottone)
        except Exception:
            print("[AUTOLOGIN] ERRORE: Bottone login non trovato con selettore: " + sel_bottone)
            return False

        bottone.click()

        # Aspetta che il login vada a buon fine
        time.sleep(5)

        # Verifica che il login sia riuscito
        url_attuale = driver.current_url
        print(f"[AUTOLOGIN] Login completato. Pagina attuale: {url_attuale}")

        # Se c'è un URL specifico della panoramica, navigaci
        url_panoramica = credenziali.get("url_dopo_login", "")
        if url_panoramica:
            print(f"[AUTOLOGIN] Navigazione a: {url_panoramica}")
            try:
                driver.get(url_panoramica)
                time.sleep(3)
            except TimeoutException:
                print(f"[AUTOLOGIN] AVVISO: Timeout navigazione a {url_panoramica}")

        print("[AUTOLOGIN] Login automatico completato con successo")
        return True

    except WebDriverException as e:
        print(f"[AUTOLOGIN] ERRORE WebDriver: {e}")
        return False
    except Exception as e:
        print(f"[AUTOLOGIN] ERRORE imprevisto: {e}")
        print(f"[AUTOLOGIN] Traceback: {traceback.format_exc()}")
        return False
    finally:
        # Chiudi SEMPRE il driver, anche in caso di errore
        if driver is not None:
            try:
                driver.quit()
            except Exception:
                # Forza la chiusura dei processi chromium orfani
                import subprocess
                subprocess.run(["pkill", "-f", "chromium.*headless"], capture_output=True)


if __name__ == "__main__":
    riuscito = esegui_login()
    sys.exit(0 if riuscito else 1)
