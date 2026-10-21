# Distribuzione RDP

- **[send.ps1](send.ps1)**: script autonomo per i client Windows 10/11.
- **[run.txt](run.txt)**: tutti i comandi pronti per MeshCentral, Pastebin e PowerShell locale, con il nome RDP risultante per ogni esempio.
- **[README.md](README.md)**: questa guida.

Carica su Pastebin il contenuto completo di `send.ps1` e usa l'URL **raw** negli esempi di `run.txt`. Lo script non contiene password.

## Avvio e valori predefiniti

In MeshCentral seleziona i PC → **Run Commands → Windows PowerShell → Run as agent**. Nel tuo ambiente l'agente esegue come **NT AUTHORITY\SYSTEM**: non serve scegliere un utente né avere utenti collegati. Identità e SID effettivi compaiono nell'output.

Manualmente, usa **PowerShell come amministratore**. Da una finestra non elevata viene richiesta elevazione UAC; un utente standard deve fornire credenziali amministrative. Su Windows a 64 bit il deploy passa automaticamente da PowerShell 32 bit a 64 bit, mantenendo gli argomenti.

| Impostazione | Parametro | Predefinito |
| --- | --- | --- |
| Nome sul Desktop | `--nome` / `--nomefile` | `Infinity2027.rdp` |
| Server | `--ip` / `--server` | `192.168.10.201` |
| Dominio RDP | `--dominio` | `CONIGLIARO.local` |

Ogni parametro omesso usa il predefinito: cambiando solo il nome, l'IP resta quello indicato. Non vengono recuperate personalizzazioni precedenti. `.rdp` viene aggiunto se manca; il server accetta IPv4 o DNS, anche con porta. Gli esempi sono tutti in **[run.txt](run.txt)**.

## Verifica e distribuzione

**`--anteprima`** mostra configurazione e contenuto RDP previsto. **`--verifica`** controlla Credential Guard, alcuni divieti locali sulle credenziali e i processi RDP aperti. Sono modalità separate, senza modifiche né elevazione. La verifica non prova la connessione o l'accessibilità di tutti i Desktop; un controllo illeggibile resta sconosciuto. `NoKnownBlockers` non garantisce l'accesso riuscito.

Il deploy aggiorna e rilegge le impostazioni client, firma il nuovo RDP e lo pubblica nel **Desktop pubblico**. Salva backup verificati di **tutti i `.rdp` direttamente nei Desktop individuati**, poi elimina i vecchi file con backup riuscito. Sottocartelle e altri tipi di file restano intatti. Le funzioni interne separano configurazione, avvio, diagnostica, profili, firma e pubblicazione.

**Nessun riavvio del PC, logout, riavvio dei servizi o chiusura delle connessioni viene richiesto.** Gli utenti devono aprire il nuovo file in una **nuova finestra RDP**; quelle già aperte possono mantenere le impostazioni precedenti.

Il dominio è preimpostato nel file, senza eseguire il join al dominio. Il collegamento usa il dominio DNS (`domain:s:CONIGLIARO.local`) e il prefisso NetBIOS (`username:s:CONIGLIARO\`) come nello script storico già collaudato. Nella finestra credenziali l'utente deve completare il nome con il proprio account di dominio e inserire la password. Il prompt viene sempre richiesto per evitare il riuso ambiguo di un nome locale o di credenziali precedenti. Il client può quindi restare in workgroup. Ogni utente può scegliere **Memorizza credenziali**, se consentito. Prima della distribuzione al gruppo, prova accesso, credenziali salvate e reindirizzamenti su un client.

## Profili offline e limiti

Lo script legge i profili registrati sul PC e carica temporaneamente `NTUSER.DAT` per gli utenti disconnessi. Risolve anche i Desktop OneDrive usando i dati del singolo utente, quindi funziona come SYSTEM.

Un RDP disponibile **solo nel cloud** può restare illeggibile: viene conservato e segnalato, mentre gli altri file vengono elaborati. Rendilo disponibile localmente e rilancia per completare la pulizia. Le cancellazioni OneDrive possono sincronizzarsi sul cloud. Desktop di rete e profili devono essere accessibili all'identità di esecuzione; container non montati non sono gestiti.

Credential Guard, GPO/MDM e policy del server possono impedire password salvate o reindirizzamenti. Lo script non garantisce l'eliminazione di ogni avviso e non disattiva Credential Guard, Defender, firewall o UAC. La firma identifica l'autore del file; `authentication level:i:0` sopprime l'avviso sul certificato del server per questa connessione. NLA/CredSSP resta attivo. Distribuisci lo script ai PC e rigenera i file firmati quando cambi configurazione.

## Backup e risultato

I backup sono in **`%ProgramData%\SendRDP`**, nella cartella indicata nell'output, accessibile ad amministratori e SYSTEM. `files.json` associa originali, copie e hash; `registry.jsonl` registra i valori precedenti; `readiness.json` contiene la diagnostica. Gli eventuali `profile-errors.txt` e `cleanup-errors.txt` indicano operazioni incomplete.

`result.json` riporta `Deployed`, `DeployedWithWarnings` o `FailedOrPartial`. Per ripristinare gli RDP, ricopia ogni `Backup` nel percorso `Original` di `files.json` e rimuovi separatamente il nuovo file pubblico, se necessario. Registro e certificati richiedono ripristino manuale: **non esiste rollback automatico completo**. Gli errori precedenti alla creazione della cartella compaiono solo nell'output.
