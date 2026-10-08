# Pac-Track v3 — Design spec (riscrittura)

Data: 2026-10-07 · Branch: `rewrite/v3` (da `main`)

> **Revisione 2 (2026-10-07): app nativa macOS in Swift.** L'utente usa solo Mac: la piattaforma passa da Electron a Swift/SwiftUI. Le sezioni 2, 4, 6, 8, 10 e 11 sono aggiornate; il comportamento del motore (§5), l'UX (§7) e la gestione errori (§9) restano validi. La M1 in TypeScript è il riferimento eseguibile per il porting.

## 1. Obiettivo

App desktop che simula una rete in modo fedele ai protocolli e realistico nei tempi, utilizzabile per:

- **didattica** (stile Packet Tracer): vedere ARP, MAC learning, routing, DHCP, DNS, TCP pacchetto per pacchetto, ispezionare ogni header;
- **progettazione/validazione**: disegnare una rete e verificare raggiungibilità, subnet, NAT, firewall;
- **prestazioni**: banda, latenza, code, congestione, perdita, throughput.

Criterio di successo: uno scenario da manuale (es. ping tra due subnet via router, DHCP, traceroute, download TCP su link lento) produce in Pac-Track la stessa sequenza di pacchetti, gli stessi campi e tempi coerenti con il calcolo a mano.

## 2. Decisioni prese

| Tema | Decisione |
|---|---|
| Piattaforma | App nativa macOS (solo Mac), minimo macOS 15 |
| Codice esistente | Riscrittura da zero; v1 (root) rimossa a fine MVP |
| Stack | Swift 6 + SwiftUI, Swift Package Manager (compilabile senza Xcode), Swift Testing |
| Motore | Swift puro (porting 1:1 della M1 TypeScript), simulatore a eventi discreti, in un actor dedicato |
| Interazione | Solo GUI (nessuna CLI per dispositivo) |
| Tempo | Modalità Realtime (velocità 0.1×–100×) + modalità Simulation (pausa/step, lista eventi, ispettore PDU) |
| Stile | "IDE scuro" (JetBrains/VS Code), monospace per dati tecnici, colore solo per stato e protocolli |

## 3. Perimetro

**MVP (tutto incluso):** L2 Ethernet, hub, switch con MAC learning, ARP · IPv4, routing statico, ICMP (ping, traceroute) · DHCP, DNS · UDP, TCP · NAT/PAT, firewall stateful · generatore di traffico e metriche.

**Fuori dall'MVP (fasi successive):** Wi-Fi, VLAN 802.1Q, STP, routing dinamico (RIP/OSPF), IPv6, CLI per dispositivo, HTTP/applicazioni L7 oltre DNS/DHCP.

## 4. Architettura

```
PacTrack (app SwiftUI, @MainActor) ── async ── SimulationActor ── PacEngine
 finestre documento, canvas,                    possiede la Sim,     motore puro
 ispettore, menu, UndoManager                   clock, snapshot
```

- **Unica fonte di verità**: il motore possiede tutto lo stato di rete. La UI possiede solo presentazione (posizioni, zoom, selezione, pannelli) e uno snapshot immutabile (`Sendable`) ricevuto dall'actor.
- **Swift Package** con tre target:
  - `PacEngine` — libreria, motore puro: solo Foundation, nessun import di SwiftUI/AppKit.
  - `PacKit` — libreria: comandi, snapshot, formato file, `SimulationActor`, modello documento e logica di undo. Testabile senza UI.
  - `PacTrack` — eseguibile SwiftUI. Uno script (`scripts/bundle.sh`) crea `PacTrack.app` con `Info.plist` (tipo documento `.ptk`) e firma ad-hoc.
- Si compila con `swift build` e si testa con `swift test` usando i soli Command Line Tools; Xcode è opzionale.

## 5. Motore di simulazione

### 5.1 Tempo e determinismo
- Tempo simulato in **nanosecondi** (`number`, intero; sicuro fino a ~104 giorni simulati).
- Coda eventi: min-heap ordinato per `(time, seq)`; `seq` crescente garantisce ordine stabile a parità di tempo.
- Ogni casualità (perdita, jitter, MAC, ISN TCP, transaction id DHCP/DNS) usa un PRNG con seed (es. mulberry32) salvato nel progetto. Stesso seed + stessa topologia + stessi comandi ⇒ stessa simulazione.

### 5.2 Modello fisico
- `Node { id, kind, name, powered, interfaces[], modules }`
- `Interface { id, name, mac, ipv4?: {addr, prefix}, mode: 'static'|'dhcp', up, mtu=1500 }`
- `Link { id, a: IfaceRef, b: IfaceRef, bandwidthBps, propDelayNs, lossRate, queueLimit=1000, up }`
- Ogni direzione del link ha una coda FIFO di trasmissione. Tempo di serializzazione = `wireBytes × 8 / bandwidth`, con `wireBytes` = frame + FCS 4 + preambolo/SFD 8 + IFG 12, e padding al minimo di 64 B. Coda piena ⇒ tail drop (evento `drop` con motivo).
- La dimensione mostrata nell'ispettore segue la convenzione Wireshark (senza FCS/preambolo): un ICMP echo standard è 98 B.
- Link down o nodo spento ⇒ frame scartati, evento `drop`.

### 5.3 PDU
Header tipizzati con tutti i campi reali: Ethernet II, ARP, IPv4 (ver, ihl, tos, totalLength, id, flags, fragOffset, ttl, protocol, checksum, src, dst), ICMP, UDP, TCP (porte, seq, ack, flags, window, MSS option), DHCP (BOOTP + options 53/50/51/54/1/3/6), DNS (header, question, answer A). La lunghezza è calcolata dai campi; i checksum vengono calcolati realmente. Frammentazione IPv4: fuori MVP; pacchetto > MTU con DF ⇒ ICMP "fragmentation needed", senza DF ⇒ drop con avviso.

### 5.4 Moduli di protocollo e valori di default

| Modulo | Comportamento |
|---|---|
| NIC | accetta frame per proprio MAC o broadcast, scarta il resto |
| Hub | ripete il frame su tutte le porte tranne l'ingresso (stesso dominio di collisione semplificato: nessuna collisione simulata) |
| Switch | MAC learning, aging 300 s, flooding per destinazioni sconosciute/broadcast; rilevamento loop (stesso frame visto > N volte in finestra breve) ⇒ avviso UI |
| ARP | cache con timeout 300 s; richiesta ripetuta 3 volte a 1 s; pacchetti in attesa accodati (max 3 per IP) e scartati con ICMP host unreachable al timeout |
| IPv4 | forwarding longest-prefix-match; route connesse automatiche; TTL iniziale 64 (host) / 255 (router); TTL=0 ⇒ ICMP Time Exceeded; nessuna route ⇒ ICMP Net Unreachable |
| ICMP | echo request/reply, time exceeded, destination unreachable (net/host/port/fragmentation-needed) |
| UDP | socket con porte; porta chiusa ⇒ ICMP port unreachable |
| TCP | handshake a 3 vie, seq/ack, MSS 1460, finestra ricevente, RTO iniziale 1 s (RFC 6298) con backoff, fast retransmit su 3 dup-ACK, congestion control Reno (slow start, congestion avoidance), FIN/RST; ISN dal PRNG |
| DHCP server | pool, esclusioni, gateway, DNS, lease default 86400 s; DORA completo; rinnovo T1/T2 lato client |
| DNS | server con record A; resolver client con cache rispettosa del TTL; NXDOMAIN |
| NAT/PAT | su router: interfacce inside/outside, traduzione sorgente con porte, tabella con timeout (TCP 7440 s, UDP 300 s, ICMP 60 s) |
| Firewall | ACL ordinate per interfaccia/direzione (allow/deny su proto, IP/prefisso, porte), default policy, stateful (risposte a connessioni stabilite ammesse) |

### 5.5 Tipi di dispositivo (composizione di moduli)
- **PC, Laptop**: host stack (NIC, ARP, IPv4, ICMP, UDP, TCP, client DHCP, resolver DNS).
- **Server**: host stack + servizi attivabili (DHCP, DNS, server TCP/UDP "sink/echo").
- **Switch** (8/24/48 porte), **Hub** (8 porte).
- **Router**: N interfacce L3 + DHCP server, NAT, firewall attivabili.
- **Cloud/ISP**: router preconfigurato con un'uscita "Internet" simulata (risponde a ping, ospita DNS pubblico).

### 5.6 Applicazioni
- `ping` (count, intervallo, size, TTL), `traceroute` (UDP probe stile Linux, 3 probe per hop, max 30 hop), `nslookup`.
- **Generatore di traffico**: flusso UDP a bitrate costante oppure trasferimento TCP di N byte, tra due host. Produce metriche per flusso.
- **Metriche**: per link (utilizzo %, occupazione coda, drop), per flusso (throughput, RTT/latenza, jitter, perdita). Campionate ogni 100 ms di tempo simulato.

## 6. Protocollo UI ↔ motore

`enum Command` e struct `Snapshot` in `PacKit`, tutti `Sendable`. La UI chiama `await simulation.apply(command)` (lancia l'errore tipizzato del motore) e osserva gli snapshot pubblicati ~20 volte al secondo. I nomi qui sotto sono indicativi del perimetro completo; ogni fase introduce solo i comandi che le servono.

- **UI → motore**: `addNode`, `removeNode`, `updateNode`, `connect`, `disconnect`, `updateLink`, `configureInterface`, `configureService`, `setPower`, `runApp`, `stopApp`, `play`, `pause`, `step`, `setSpeed`, `setMode`, `load`, `serialize`.
- **Motore → UI**: `ack {reqId}` / `error {reqId, code, message, field?}`, `stateDelta`, `events` (lotto per frame), `appOutput`, `metrics`, `clock {simTimeNs, effectiveSpeed}`, `warning`.
- Ogni `apply` restituisce dopo aver aggiornato lo snapshot, così la UI non lavora mai su stato vecchio.

### Modalità di tempo
- **Realtime**: tick ~16 ms; l'actor avanza il tempo di `Δwall × speed` ed esegue gli eventi fino al target. Se un tick richiede troppo, la velocità effettiva cala e viene notificata (`clock.effectiveSpeed`), nessun blocco.
- **Simulation**: clock fermo; `step` esegue il prossimo evento; `play` avanza lentamente con animazione; la UI evidenzia la PDU corrente.
- Log eventi: buffer circolare, default 100 000 voci, configurabile.

## 7. UI

### 7.1 Layout (approvato in mockup)
1. **Barra superiore**: menu (File/Modifica/Vista), strumento (Sposta/Collega), interruttore Realtime/Simulation, ⏮ ▶ ⏭, velocità, clock simulato.
2. **Palette** a sinistra: dispositivi per categoria (Rete, Host) e cavi (Ethernet 1 Gb/s, Fibra 10 Gb/s, Personalizzato), con ricerca; drag sul canvas.
3. **Canvas** (SwiftUI, disegnato su misura): nodi con nome, IP, LED stato; link con banda/ritardo; pacchetti come etichette colorate per protocollo; pan, zoom, griglia con snap, minimappa, selezione multipla.
4. **Ispettore** a destra, schede: Interfacce · Tabelle (ARP, MAC, routing, NAT, lease DHCP, live) · Servizi (DHCP, DNS, NAT, firewall, server) · App (ping, traceroute, nslookup, generatore traffico). Per i link: banda, ritardo, perdita, coda, stato.
5. **Pannello inferiore** ridimensionabile: Eventi (lista filtrabile per protocollo/nodo, clic ⇒ ispettore PDU ad albero header per header) · Output app · Metriche (grafici).

### 7.2 Menu contestuali
- **Canvas vuoto**: Aggiungi dispositivo ▸ (categorie palette, inserito nel punto cliccato), Incolla, Seleziona tutto, Adatta alla vista, Griglia on/off.
- **Nodo**: Apri ispettore, Ping verso ▸, Traceroute verso ▸ (altri nodi con IP), Mostra tabelle, Spegni/Accendi, Rinnova DHCP, Duplica, Copia, Elimina.
- **Link**: Proprietà, Simula guasto / Ripristina, Mostra metriche, Scollega.
- **Selezione multipla**: solo azioni valide per più nodi (Duplica, Copia, Spegni/Accendi, Elimina).

### 7.3 Stile
Token colore scuri stile JetBrains (sfondo `#1e1f22`, pannelli `#2b2d30`, bordi `#393b40`, testo `#bcbec4`, accento `#3574f0`). Colori protocollo fissi: ARP `#f0a732`, ICMP `#e5507a`, DHCP `#56a8f5`, DNS `#b083f0`, TCP `#5fb865`, UDP `#2fbfc4`. Monospace per IP, MAC, tempi, tabelle, PDU.

### 7.4 Scorciatoie
Comandi di menu nativi (`.commands`) con le scorciatoie macOS standard: V sposta, C collega, Canc elimina, Cmd+Z/Cmd+Shift+Z, Cmd+C/V/D, Cmd+S/O, Spazio play/pausa, `.` step.

## 8. Persistenza e cronologia
- File progetto `.ptk` (JSON): `{ version, seed, nodes, links, services, layout, view }`. Versione esplicita per migrazioni.
- *Decisione 2026-10-08:* zoom e pan (`view`) non vengono salvati, perché ogni pan segnerebbe il documento come modificato; i servizi stanno nei nodi (decisione M3), non in una chiave `services`.
- Documento macOS nativo (`DocumentGroup` + `FileDocument`, tipo `.ptk`): apri, salva, recenti, salvataggio automatico, versioni e finestre multiple vengono dal sistema (sostituisce l'autosave/recovery manuale). Export PNG del canvas con `ImageRenderer`.
- Undo/redo con l'`UndoManager` di sistema. Ogni modifica registra lo snapshot della topologia precedente (memento): annullare una modifica di rete ricarica la rete (clock, cache ARP/MAC e app ripartono); annullare uno spostamento ripristina solo le posizioni. Le azioni di simulazione non entrano in cronologia. Eliminare un nodo con i suoi cavi è un solo passo.

## 9. Gestione errori
- **Configurazione**: validazione nel motore; risposta `error` tipizzata (IP malformato, IP duplicato nello stesso segmento, gateway fuori subnet, porta occupata, self-link, pool DHCP fuori subnet). La UI mostra l'errore sul campo; stato invariato.
- **Errori di rete**: simulati come nella realtà (ARP senza risposta, ICMP unreachable, timeout TCP, broadcast storm), non bloccati. I loop L2 generano un avviso.
- **File**: `.ptk` corrotto o versione non supportata ⇒ messaggio chiaro, progetto aperto intatto.
- **Motore**: un errore inatteso in un comando viene riportato come errore del comando; lo stato resta quello precedente.

## 10. Test
- **Motore (Swift Testing, deterministico)** — scenari:
  ARP request/reply e cache · switch learning/flooding/aging · ping tra due subnet via due router (TTL atteso) · traceroute con Time Exceeded per hop · DHCP DORA, rinnovo e scadenza lease · DNS risoluzione e NXDOMAIN · TCP handshake, ritrasmissione dopo perdita, fast retransmit · NAT PAT inside→outside e ritorno · firewall deny/allow e stateful · throughput TCP su link 10 Mb/s che converge al goodput teorico (±5%) · tail drop con coda piena.
- **Valori noti**: ICMP echo = 98 B; ritardo singolo hop = serializzazione + propagazione calcolati a mano; checksum IPv4/ICMP confrontati con valori di riferimento.
- **Logica dell'app** (`PacKit`, Swift Testing): comandi, undo/redo, formato file, validazioni, nomi e porte — l'equivalente dei test di `actions.ts`.
- **UI** (senza Xcode): le viste restano sottili e tutta la logica sta in `PacKit`. A ogni fase: avvio reale dell'app con screenshot di controllo e una checklist manuale dei flussi. Con Xcode installato si aggiungono test XCUITest per gli stessi flussi.

## 11. Fasi di consegna

1. **M1 — Motore L2/L3 headless (TypeScript)**: completata, fa da riferimento eseguibile.
1. **M1s — Porting del motore in Swift** (`PacEngine`) con tutti i test della M1; poi rimozione del codice TypeScript.
2. **M2a — App SwiftUI**: documento `.ptk`, layout (palette, canvas, ispettore, output), canvas con drag/zoom/cavi/selezione, ispettore Interfacce/Routing/Tabelle/App, menu contestuali, undo/redo.
2. **M2b — Simulazione visiva**: Realtime/Simulation con step, lista eventi + ispettore PDU, animazione pacchetti, proprietà dei link, accensione/spegnimento, copia/incolla, ricerca nella palette, avviso loop.
3. **M3 — DHCP e DNS** (motore + scheda Servizi).
4. **M4 — TCP, generatore di traffico, Metriche**.
5. **M5 — NAT e firewall**.
6. **M6 — Rifinitura**: export immagini, icona e packaging `.app` firmato, rimozione v1 (`legacy/`), README.

Ogni fase si chiude con test verdi e app avviabile.
