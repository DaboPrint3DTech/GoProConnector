# GoPro Connector

App nativa macOS (SwiftUI) per sfogliare e scaricare via WiFi i file di una **GoPro HERO8 Black**
(compatibile anche con HERO5–HERO7, che usano la stessa API), senza collegare il cavo USB.

## Funzioni

- **Connessione WiFi**: si collega alla camera su `10.5.5.9`; può anche collegare il Mac alla rete della GoPro
  (nome rete + password salvata nel Portachiavi).
- **Anteprime**: griglia di miniature. Doppio clic o barra spaziatrice per l'anteprima a schermo intero:
  le foto si caricano in qualità originale, i video sono riprodotti in streaming dal proxy `.LRV` a bassa
  risoluzione (oppure dal file originale con l'interruttore "Qualità originale"). Frecce ← → per scorrere.
- **Vista**: icone o elenco (tabella ordinabile); dimensione icone con lo slider o con ⌘+ / ⌘- / ⌘0;
  raggruppamento per giorno.
- **Filtri e ricerca**: per tipo (video, foto, burst, time lapse), per giorno, per stato (da scaricare / già
  scaricati), ricerca per nome, data o tipo; ordinamento per data, nome, dimensione.
- **Copia** (⌘D): scarica sul Mac nella cartella predefinita o in una a scelta. I file già presenti con la stessa
  dimensione vengono saltati.
- **Sposta** (⇧⌘D): scarica, verifica la dimensione e solo allora cancella dalla camera.
- **Elimina** (⌫): cancella dalla scheda SD, con conferma.
- I burst e i time lapse vengono scaricati come gruppo in una sottocartella; le date dei file sul Mac vengono
  impostate all'ora della ripresa; opzionalmente si scaricano anche i file `.LRV`.
- Coda dei trasferimenti con avanzamento, velocità, **tempo stimato** (e ora di fine), annulla e riprova.
  La prima stima usa la velocità dei download precedenti e si affina dopo un paio di secondi.

## Compilare e installare

Servono solo i Command Line Tools di Xcode (Swift 5.9+) e macOS 14 o successivo.

```bash
scripts/build-app.sh
```

Crea `build/GoPro Connector.app`. Per installarla in /Applications (così compare nel Launchpad e in Spotlight):

```bash
scripts/build-app.sh --install
```

L'icona è generata da `tools/make_icon.swift` (`swift tools/make_icon.swift Resources/AppIcon.icns`).

Al primo avvio macOS può chiedere il permesso di accedere alla **rete locale**: va concesso.

## Uso con la HERO8

La prima volta: sulla camera Preferenze › Connessioni › Connetti dispositivo › App GoPro, poi
**Accendi WiFi via Bluetooth e connetti**. Dalla volta successiva basta aprire l'app (o premere ⌘K):
accende il WiFi della camera via Bluetooth e collega il Mac da sola.
**Disconnetti e spegni WiFi GoPro** riporta il Mac sulla rete di casa.

### Restare su Internet mentre scarichi

Il Mac ha una sola scheda WiFi e può essere collegato a una sola rete WiFi alla volta (2,4 o 5 GHz non
cambia: è la stessa radio). Per restare online serve una seconda connessione:

- **cavo Ethernet** dal Mac al router (consigliato: Ethernet è già prima del WiFi nell'ordine dei servizi,
  quindi Internet passa dal cavo e il WiFi resta libero per la GoPro);
- oppure iPhone collegato via USB con Hotspot personale attivo.

Nella barra laterale l'app mostra "Internet via …" quando c'è una seconda connessione attiva.
L'app interroga la camera ogni 5 secondi, il che la tiene sveglia durante i download lunghi.

## Prova senza camera

Il finto server in `tools/` imita l'API HTTP della HERO8:

```bash
swift tools/make_mock_assets.swift tools/mock_assets
```

```bash
python3 tools/mock_gopro.py --port 18765
```

Poi in Impostazioni › Connessione imposta host `127.0.0.1` e porte `18765` / `18765`
(ricordati di rimettere `10.5.5.9`, 80, 8080 per la camera vera, oppure usa "Ripristina valori predefiniti").

## Struttura

- `Sources/GoProConnector/Services/GoProClient.swift`: API HTTP della camera (lista media, miniature, cancellazione, stato)
- `Services/TransferManager.swift` + `Downloader.swift`: coda download, sposta, verifica, cronologia
- `Services/ThumbnailLoader.swift`: miniature con cache su disco e massimo 3 richieste in parallelo
- `ViewModels/LibraryViewModel.swift`: stato, filtri, selezione, azioni
- `Views/`: interfaccia SwiftUI

## API GoPro usate (HERO5–HERO8)

| Funzione | Richiesta |
|---|---|
| Info camera | `GET :80/gp/gpControl/info` |
| Stato (batteria, SD) | `GET :80/gp/gpControl/status` |
| Lista file | `GET :8080/gp/gpMediaList` |
| Miniatura / screennail | `GET :8080/gp/gpMediaMetadata?p=100GOPRO/FILE[&t=screennail]` |
| Download | `GET :8080/videos/DCIM/100GOPRO/FILE` |
| Elimina file / gruppo | `GET :80/gp/gpControl/command/storage/delete[/group]?p=100GOPRO/FILE` |
