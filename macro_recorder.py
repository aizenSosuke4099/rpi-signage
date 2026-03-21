#!/usr/bin/env python3
"""
macro_recorder.py - Registratore e riproduttore di macro per il browser

MODALITÀ REGISTRAZIONE (eseguire una sola volta):
  python3 macro_recorder.py registra

  Apre Chromium visibile. Tu fai login, navighi, clicchi dove serve.
  Ogni azione viene registrata automaticamente.
  Quando hai finito, chiudi la finestra del terminale di istruzioni
  oppure premi Ctrl+C. Le azioni vengono salvate in macro.json.

MODALITÀ RIPRODUZIONE (automatica ad ogni avvio):
  python3 macro_recorder.py riproduci

  Apre Chromium in headless, esegue tutte le azioni registrate,
  poi chiude. I cookie e la sessione restano salvati nel profilo.

Le azioni registrate includono:
  - Click su elementi (salvati per selettore CSS univoco)
  - Testo digitato nei campi input
  - Navigazione a URL diversi
  - Attese tra un'azione e l'altra
"""

import json
import sys
import time
import traceback
from pathlib import Path

# Selenium viene importato solo quando serve (registra/riproduci),
# così "mostra" funziona anche senza Selenium installato.
SELENIUM_DISPONIBILE = False
try:
    from selenium import webdriver
    from selenium.webdriver.chrome.options import Options
    from selenium.webdriver.common.by import By
    from selenium.webdriver.support.ui import WebDriverWait
    from selenium.webdriver.support import expected_conditions as EC
    from selenium.common.exceptions import (
        TimeoutException, WebDriverException,
        StaleElementReferenceException, NoSuchElementException
    )
    SELENIUM_DISPONIBILE = True
except ImportError:
    pass


def richiedi_selenium():
    """Verifica che Selenium sia disponibile, altrimenti esce con errore."""
    if not SELENIUM_DISPONIBILE:
        print("[MACRO] ERRORE: Selenium non installato.")
        print("  Esegui: pip3 install selenium --break-system-packages")
        sys.exit(1)

# Percorsi
CARTELLA_PROGETTO = Path(__file__).resolve().parent
FILE_MACRO = CARTELLA_PROGETTO / "macro.json"
PROFILO_CHROMIUM = CARTELLA_PROGETTO / ".chromium-profilo"

# Timeout per trovare elementi durante la riproduzione (secondi)
TIMEOUT_ELEMENTO = 15

# JavaScript iniettato nel browser per catturare le azioni dell'utente
# Registra: click, input di testo, cambio pagina
JS_REGISTRATORE = """
(function() {
    // Evita di iniettare due volte
    if (window.__macroRecorderAttivo) return;
    window.__macroRecorderAttivo = true;

    // Array dove salviamo le azioni registrate
    window.__macroAzioni = window.__macroAzioni || [];

    // Genera un selettore CSS univoco per un elemento
    function generaSelettore(el) {
        // Prima prova con ID (il più affidabile)
        if (el.id) {
            return '#' + CSS.escape(el.id);
        }

        // Prova con name (utile per i form)
        if (el.name) {
            var sel = el.tagName.toLowerCase() + '[name="' + el.name + '"]';
            if (document.querySelectorAll(sel).length === 1) return sel;
        }

        // Prova con type per input
        if (el.type && el.tagName === 'INPUT') {
            var sel = 'input[type="' + el.type + '"]';
            if (el.placeholder) {
                sel += '[placeholder="' + el.placeholder + '"]';
            }
            if (document.querySelectorAll(sel).length === 1) return sel;
        }

        // Prova con classe + tag
        if (el.className && typeof el.className === 'string') {
            var classi = el.className.trim().split(/\\s+/).slice(0, 3).join('.');
            if (classi) {
                var sel = el.tagName.toLowerCase() + '.' + classi;
                if (document.querySelectorAll(sel).length === 1) return sel;
            }
        }

        // Prova con testo del bottone
        if ((el.tagName === 'BUTTON' || el.tagName === 'A') && el.textContent.trim()) {
            var testo = el.textContent.trim().substring(0, 30);
            // Usa XPath-like approach via attributo
            var sel = el.tagName.toLowerCase();
            var tutti = document.querySelectorAll(sel);
            for (var i = 0; i < tutti.length; i++) {
                if (tutti[i] === el) {
                    return sel + ':nth-of-type(' + (i + 1) + ')';
                }
            }
        }

        // Fallback: percorso completo dal body
        var percorso = [];
        var corrente = el;
        while (corrente && corrente !== document.body && corrente !== document) {
            var tag = corrente.tagName.toLowerCase();
            var indice = 1;
            var fratello = corrente.previousElementSibling;
            while (fratello) {
                if (fratello.tagName === corrente.tagName) indice++;
                fratello = fratello.previousElementSibling;
            }
            percorso.unshift(tag + ':nth-of-type(' + indice + ')');
            corrente = corrente.parentElement;
        }
        return percorso.join(' > ');
    }

    // Registra i click
    document.addEventListener('click', function(e) {
        var el = e.target;
        // Ignora click su elementi invisibili o troppo generici
        if (el === document.body || el === document.documentElement) return;

        var azione = {
            tipo: 'click',
            selettore: generaSelettore(el),
            timestamp: Date.now(),
            url: window.location.href,
            testo_elemento: (el.textContent || '').trim().substring(0, 50),
            tag: el.tagName.toLowerCase()
        };

        window.__macroAzioni.push(azione);
        console.log('[MACRO] Click registrato:', azione.selettore);
    }, true);

    // Registra l'input di testo (quando l'utente finisce di scrivere in un campo)
    document.addEventListener('change', function(e) {
        var el = e.target;
        if (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA' || el.tagName === 'SELECT') {
            var azione = {
                tipo: 'input',
                selettore: generaSelettore(el),
                valore: el.value,
                timestamp: Date.now(),
                url: window.location.href,
                tipo_input: el.type || 'text',
                tag: el.tagName.toLowerCase()
            };

            window.__macroAzioni.push(azione);
            console.log('[MACRO] Input registrato:', azione.selettore, '→',
                        azione.tipo_input === 'password' ? '****' : azione.valore);
        }
    }, true);

    // Registra submit dei form
    document.addEventListener('submit', function(e) {
        var form = e.target;
        var azione = {
            tipo: 'submit',
            selettore: generaSelettore(form),
            timestamp: Date.now(),
            url: window.location.href,
            tag: 'form'
        };
        window.__macroAzioni.push(azione);
        console.log('[MACRO] Submit registrato');
    }, true);

    console.log('[MACRO] Registratore attivato. Ogni azione viene catturata.');
})();
"""


def crea_driver(headless=False):
    """Crea un'istanza del driver Chromium.

    Su Debian Trixie/aarch64, usa il chromedriver installato dal sistema.
    Evita Selenium Manager che non supporta linux/aarch64.
    """
    from selenium.webdriver.chrome.service import Service

    opzioni = Options()
    opzioni.add_argument(f"--user-data-dir={PROFILO_CHROMIUM}")
    opzioni.add_argument("--no-sandbox")
    opzioni.add_argument("--disable-dev-shm-usage")
    opzioni.add_argument("--disable-gpu")
    opzioni.add_argument("--start-maximized")
    # Specifica il percorso al binario chromium
    opzioni.binary_location = "/usr/bin/chromium"

    if headless:
        opzioni.add_argument("--headless=new")

    # Usa il chromedriver installato dal sistema, non Selenium Manager
    service = Service("/usr/bin/chromedriver")
    driver = webdriver.Chrome(service=service, options=opzioni)
    driver.set_page_load_timeout(30)
    driver.implicitly_wait(5)
    return driver


def registra():
    """
    Modalità registrazione: apre il browser, l'utente interagisce,
    le azioni vengono catturate e salvate in macro.json.
    """
    richiedi_selenium()
    config = leggi_config()
    credenziali = config.get("autologin", {})
    url_iniziale = credenziali.get("url_login", "")

    if not url_iniziale:
        # Fallback: usa il primo URL web nella playlist
        for el in config.get("elementi", []):
            if el.get("tipo") == "web":
                url_iniziale = el.get("sorgente", "")
                break

    if not url_iniziale:
        print("[MACRO] ERRORE: Nessun URL configurato. Imposta url_login in config.json")
        return False

    print("=" * 50)
    print("  REGISTRAZIONE MACRO")
    print("=" * 50)
    print()
    print(f"  Si aprirà il browser su: {url_iniziale}")
    print()
    print("  Cosa fare:")
    print("  1. Fai login nel sito")
    print("  2. Naviga alla pagina che vuoi mostrare")
    print("  3. Fai tutte le azioni necessarie")
    print("     (click su bottoni, fullscreen, ecc.)")
    print("  4. Quando hai finito, torna qui e premi INVIO")
    print()
    print("  Ogni tua azione viene registrata automaticamente.")
    print("=" * 50)
    print()

    driver = None
    try:
        driver = crea_driver(headless=False)
        driver.get(url_iniziale)

        # Inietta il registratore JavaScript
        driver.execute_script(JS_REGISTRATORE)
        url_precedente = url_iniziale

        print("[MACRO] Browser aperto. Interagisci con la pagina...")
        print("[MACRO] Premi INVIO qui quando hai finito.\n")

        # Loop: re-inietta il JS ad ogni cambio pagina e aspetta che l'utente finisca
        import threading
        finito = threading.Event()

        def attendi_input():
            input()
            finito.set()

        t = threading.Thread(target=attendi_input, daemon=True)
        t.start()

        while not finito.is_set():
            try:
                url_corrente = driver.current_url
                # Se la pagina è cambiata, re-inietta il registratore
                if url_corrente != url_precedente:
                    time.sleep(1)  # Aspetta il caricamento
                    driver.execute_script(JS_REGISTRATORE)
                    url_precedente = url_corrente
                    print(f"[MACRO] Navigazione rilevata: {url_corrente}")
            except Exception:
                pass
            time.sleep(0.5)

        # Recupera le azioni registrate dal browser
        azioni = driver.execute_script("return window.__macroAzioni || [];")

        # Aggiungi l'URL finale come ultima azione (la pagina da mostrare nel loop)
        url_finale = driver.current_url
        azioni.append({
            "tipo": "url_finale",
            "url": url_finale,
            "timestamp": int(time.time() * 1000)
        })

        # Salva le azioni su file
        macro = {
            "versione": 1,
            "data_registrazione": time.strftime("%Y-%m-%d %H:%M:%S"),
            "url_iniziale": url_iniziale,
            "url_finale": url_finale,
            "numero_azioni": len(azioni),
            "azioni": azioni
        }

        with open(FILE_MACRO, "w", encoding="utf-8") as f:
            json.dump(macro, f, indent=4, ensure_ascii=False)

        print(f"\n[MACRO] Registrazione completata!")
        print(f"[MACRO] Azioni registrate: {len(azioni)}")
        print(f"[MACRO] URL finale: {url_finale}")
        print(f"[MACRO] Salvato in: {FILE_MACRO}")
        return True

    except Exception as e:
        print(f"[MACRO] ERRORE: {e}")
        traceback.print_exc()
        return False
    finally:
        if driver:
            try:
                driver.quit()
            except Exception:
                pass


def riproduci():
    """
    Modalità riproduzione: esegue le azioni registrate in macro.json.
    Usa modalità headless (nessuna finestra visibile).
    """
    richiedi_selenium()
    if not FILE_MACRO.exists():
        print("[MACRO] Nessuna macro registrata. Esegui prima: python3 macro_recorder.py registra")
        return False

    with open(FILE_MACRO, "r", encoding="utf-8") as f:
        macro = json.load(f)

    azioni = macro.get("azioni", [])
    if not azioni:
        print("[MACRO] Macro vuota, niente da riprodurre")
        return True

    url_iniziale = macro.get("url_iniziale", "")
    print(f"[MACRO] Riproduzione macro ({len(azioni)} azioni)")
    print(f"[MACRO] URL iniziale: {url_iniziale}")

    driver = None
    try:
        driver = crea_driver(headless=True)
        driver.get(url_iniziale)
        time.sleep(3)  # Aspetta il caricamento completo

        # Controlla se siamo già sulla pagina finale (sessione ancora valida)
        url_finale = macro.get("url_finale", "")
        if url_finale and driver.current_url == url_finale:
            print("[MACRO] Sessione ancora attiva, già sulla pagina giusta")
            return True

        timestamp_precedente = None

        for i, azione in enumerate(azioni):
            tipo = azione.get("tipo", "")
            selettore = azione.get("selettore", "")

            # Attesa prima dell'azione: usa 'attesa_prima' se presente (macro manuale),
            # altrimenti calcola dal timestamp (macro registrata automaticamente)
            attesa_prima = azione.get("attesa_prima", 0)
            if attesa_prima > 0:
                time.sleep(attesa_prima)
            else:
                timestamp = azione.get("timestamp", 0)
                if timestamp_precedente and timestamp > timestamp_precedente:
                    pausa = min((timestamp - timestamp_precedente) / 1000.0, 5.0)
                    if pausa > 0.1:
                        time.sleep(pausa)
                timestamp_precedente = timestamp

            print(f"[MACRO] Azione {i+1}/{len(azioni)}: {tipo}", end="")

            try:
                if tipo == "click":
                    print(f" → {selettore[:50]}")
                    elemento = WebDriverWait(driver, TIMEOUT_ELEMENTO).until(
                        EC.element_to_be_clickable((By.CSS_SELECTOR, selettore))
                    )
                    elemento.click()

                elif tipo == "input":
                    valore = azione.get("valore", "")
                    tipo_input = azione.get("tipo_input", "text")
                    valore_log = "****" if tipo_input == "password" else valore[:20]
                    print(f" → {selettore[:40]} = '{valore_log}'")
                    elemento = WebDriverWait(driver, TIMEOUT_ELEMENTO).until(
                        EC.presence_of_element_located((By.CSS_SELECTOR, selettore))
                    )
                    elemento.clear()
                    elemento.send_keys(valore)

                elif tipo == "submit":
                    print(f" → form submit")
                    elemento = driver.find_element(By.CSS_SELECTOR, selettore)
                    elemento.submit()
                    time.sleep(3)  # Aspetta dopo il submit

                elif tipo == "url_finale":
                    url = azione.get("url", "")
                    print(f" → navigazione a: {url[:50]}")
                    if url and driver.current_url != url:
                        driver.get(url)
                        time.sleep(3)

                else:
                    print(f" → tipo sconosciuto, salto")

            except TimeoutException:
                print(f" [TIMEOUT: elemento non trovato]")
                # Potrebbe essere che siamo già loggati e l'elemento non c'è
                continue
            except (StaleElementReferenceException, NoSuchElementException) as e:
                print(f" [ELEMENTO NON TROVATO: {e}]")
                continue
            except Exception as e:
                print(f" [ERRORE: {e}]")
                continue

        print(f"\n[MACRO] Riproduzione completata")
        print(f"[MACRO] Pagina finale: {driver.current_url}")
        return True

    except WebDriverException as e:
        print(f"[MACRO] ERRORE WebDriver: {e}")
        return False
    except Exception as e:
        print(f"[MACRO] ERRORE: {e}")
        traceback.print_exc()
        return False
    finally:
        if driver:
            try:
                driver.quit()
            except Exception:
                import subprocess
                subprocess.run(["pkill", "-f", "chromium.*headless"], capture_output=True)


def leggi_config():
    """Legge config.json."""
    try:
        with open(CARTELLA_PROGETTO / "config.json", "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return {}


def mostra_macro():
    """Mostra le azioni registrate in modo leggibile."""
    if not FILE_MACRO.exists():
        print("[MACRO] Nessuna macro registrata.")
        return

    with open(FILE_MACRO, "r", encoding="utf-8") as f:
        macro = json.load(f)

    print(f"Macro registrata il: {macro.get('data_registrazione', '?')}")
    print(f"URL iniziale: {macro.get('url_iniziale', '?')}")
    print(f"URL finale:   {macro.get('url_finale', '?')}")
    print(f"Azioni: {macro.get('numero_azioni', 0)}")
    print()

    for i, azione in enumerate(macro.get("azioni", [])):
        tipo = azione.get("tipo", "?")
        if tipo == "click":
            print(f"  {i+1}. CLICK → {azione.get('selettore', '?')[:60]}")
            if azione.get("testo_elemento"):
                print(f"        testo: \"{azione['testo_elemento'][:40]}\"")
        elif tipo == "input":
            valore = azione.get("valore", "")
            if azione.get("tipo_input") == "password":
                valore = "****"
            print(f"  {i+1}. INPUT → {azione.get('selettore', '?')[:50]} = \"{valore[:30]}\"")
        elif tipo == "submit":
            print(f"  {i+1}. SUBMIT form")
        elif tipo == "url_finale":
            print(f"  {i+1}. PAGINA FINALE → {azione.get('url', '?')[:60]}")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Uso:")
        print("  python3 macro_recorder.py registra   — Registra le azioni")
        print("  python3 macro_recorder.py riproduci   — Riproduce le azioni")
        print("  python3 macro_recorder.py mostra      — Mostra le azioni registrate")
        sys.exit(1)

    comando = sys.argv[1].lower()

    if comando == "registra":
        riuscito = registra()
    elif comando == "riproduci":
        riuscito = riproduci()
    elif comando == "mostra":
        mostra_macro()
        riuscito = True
    else:
        print(f"Comando sconosciuto: {comando}")
        riuscito = False

    sys.exit(0 if riuscito else 1)
