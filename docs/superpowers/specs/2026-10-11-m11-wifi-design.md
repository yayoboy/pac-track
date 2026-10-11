# pac-track v3 — M11: Wi-Fi

> Estende la spec principale `2026-10-07-pac-track-rewrite-design.md` (rev. 2), che mette il Wi-Fi fuori dall'MVP (§3), e le spec M7, M8, M9 e M10; valgono le loro regole su motore, determinismo, UI, persistenza ed errori. Fra i gruppi di dispositivi proposti dopo M10 l'utente ha scelto **wireless**: access point, router Wi-Fi domestico, schede wireless, tablet e smartphone. La milestone si divide come M7–M9: **M11a** il nucleo (access point, host wireless, mezzo radio, scansione, autenticazione aperta, associazione, percorso dei dati, UI), **M11b** WPA2-PSK, il router Wi-Fi domestico e la portata sul canvas. Le decisioni sono prese in autonomia; ognuna è marcata *Decisione* con il motivo. Riferimenti di fedeltà: IEEE 802.11-2016 (§9 formati, §11 gestione della MAC, §17 e §18 tempi OFDM/ERP), RFC 1042 per LLC/SNAP, IEEE 802.11i per il 4-way handshake (M11b); gli access point autonomi Cisco IOS e i client Linux/Android per i default.

## 1. Obiettivo
Vedere una rete Wi-Fi lavorare frame per frame come una cablata: il client cerca la rete con una Probe Request, si autentica, si associa, prende l'indirizzo dal DHCP attraverso l'access point e da lì ping, DNS e traffico passano in aria con l'intestazione 802.11 e LLC/SNAP. Sul canvas una linea tratteggiata unisce ogni client all'access point a cui è associato.

**Successo M11a:** SW1 con un *Access point* (AP1) su un cavo e un *Server DHCP* (SRV1, preset M10) su un altro; un *Tablet* (TAB1) e uno *Smartphone* (PHONE1) appoggiati sul canvas; LAPTOP1 con la scheda Wi-Fi e la rete `pac-track` scritte nella scheda Wi-Fi, in DHCP. Nessun'altra configurazione.
- A t = 0 ogni client manda una Probe Request per `pac-track` sui canali 1, 6 e 11, uno alla volta. AP1, sul canale 6, risponde con una Probe Response. Seguono Authentication (Open System) e Association Request/Response: entro pochi ms la linea tratteggiata collega ogni client ad AP1 e la scheda Tabelle mostra "associato" con il BSSID di AP1.
- All'associazione parte il client DHCP. Il DISCOVER va in aria verso AP1 (To DS), AP1 lo porta su Ethernet e lo ripete in aria agli altri client (From DS). La porta di SW1 verso AP1 passa in forwarding a 30 s (M7), quindi i client hanno un indirizzo fra 192.168.1.100 e .199 a 60 s, come i PC di M10.
- Un ping da TAB1 a PHONE1 passa due volte in aria: TAB1 → AP1, poi AP1 → PHONE1. Un ping da TAB1 a SRV1 passa in aria e poi sul cavo.
- Il generatore UDP da TAB1 a SRV1 a 50 Mb/s ottiene circa 30 Mb/s: in aria un solo frame alla volta, con DIFS, backoff e ACK (§4).
- Spegnendo AP1 i client perdono l'associazione e la linea sparisce; riaccendendolo si riassociano alla scansione successiva (§5).
- Il file si salva e si riapre uguale; un file di M10 si apre come prima.

**Successo M11b:** un *Router Wi-Fi domestico* (HR1) con la porta Internet sulla Cloud/ISP e la rete `casa` in WPA2-PSK. Un tablet con la password giusta si associa, fa il 4-way handshake e prende l'indirizzo dal DHCP di HR1; con la password sbagliata il messaggio 2 non passa il controllo del MIC e HR1 lo deautentica. Allontanando il tablet oltre la portata di HR1 l'associazione cade; avvicinandolo torna, con una velocità che dipende dalla distanza.

## 2. Dispositivi (M11a)
- **Access point** (`accessPoint`, nomi `AP1`, `AP2`…, sezione Wireless): un bridge fra la porta Ethernet `Gi0` e la radio `Dot11Radio0` (i nomi di un Aironet IOS), con un solo SSID.
  - Arriva con SSID `pac-track` sul canale 6. *Decisione:* il canale più usato come default dagli access point; l'SSID è lo stesso dei client nuovi, così AP e tablet appena appoggiati si trovano senza scrivere nulla, come la Smart TV di M10 arriva in DHCP.
  - Nessun indirizzo IP. *Decisione:* l'interfaccia BVI di gestione di un Aironet serve solo a configurarlo da remoto, cosa che qui si fa dall'ispettore; l'access point resta un dispositivo di livello 2, come lo switch.
  - Schede: Wi-Fi, Tabelle.
- **Tablet** (`tablet`, nomi `TAB1`…) e **Smartphone** (`smartphone`, nomi `PHONE1`…), sezione Wireless: host con la sola interfaccia `wlan0`, come in Packet Tracer. Arrivano con la rete `pac-track` e `wlan0` in DHCP.
  - Sono host per il motore: stesso stack di un PC, client DHCP, IPv6 e SLAAC, ping, traceroute, nslookup, generatore. Schede: Interfacce, Routing, Wi-Fi, Tabelle, App.
- **Scheda Wi-Fi per PC e Laptop:** nella scheda Wi-Fi si sceglie *Scheda di rete: Ethernet / Wi-Fi*. Con Wi-Fi l'interfaccia `eth0` lascia il posto a `wlan0`, con un MAC nuovo, come quando si cambia il modulo in Packet Tracer.
  - Rifiutato mentre il cavo è collegato. *Decisione:* un host ha una sola scheda (M10 §4); due schede vorrebbero dire due interfacce con le regole di inoltro da decidere.
  - La scheda nuova parte senza indirizzo, statica, IPv6 spento. *Decisione:* è un'altra scheda; l'editor però riporta la modalità DHCP nello stesso passo di annulla, perché non è un indirizzo (come le copie, M10 §6).
  - Stampante, Smart TV e server restano cablati. *Decisione:* Packet Tracer dà loro schede wireless solo come modulo opzionale; nessun laboratorio di M11 ne ha bisogno.

## 3. Frame 802.11
- **Intestazione MAC** (24 B, §9.2.3): Frame Control (versione 0, tipo, sottotipo, To DS, From DS), Duration, tre indirizzi, Sequence Control (numero di sequenza a 12 bit per trasmettitore, frammento 0).
  - Dati da client ad AP: To DS, Indirizzo 1 = BSSID, 2 = sorgente, 3 = destinazione. Da AP a client: From DS, 1 = destinazione, 2 = BSSID, 3 = sorgente. Gestione: né To né From DS, 1 = destinazione, 2 = sorgente, 3 = BSSID.
  - Il BSSID è il MAC della radio dell'access point.
  - Duration: il tempo di SIFS + ACK in µs per i frame unicast, 0 per quelli di gruppo (NAV, §9.2.5).
- **Dati:** sottotipo Data (0x20), senza QoS. Dopo l'intestazione c'è LLC/SNAP (8 B, RFC 1042: DSAP/SSAP 0xAA, controllo 0x03, OUI 00-00-00, poi l'EtherType) e il pacchetto come su Ethernet (ARP, IPv4, IPv6).
  - *Decisione:* niente QoS Data (802.11e/WMM): una sola coda di accesso al mezzo, nessuna priorità da mostrare.
- **Gestione:** Probe Request (SSID, velocità supportate), Probe Response (timestamp, intervallo di beacon 100 TU, capability ESS + short slot, SSID, velocità, canale nel DS Parameter Set), Authentication (algoritmo 0 Open System, numero di transazione 1 e 2, stato), Association Request (capability, intervallo di ascolto, SSID, velocità), Association Response (capability, stato, AID), Deauthentication (motivo).
  - Velocità supportate: 6, 9, 12, 18, 24, 36, 48, 54 Mb/s, con 6, 12 e 24 di base.
- **ACK:** non compaiono nella lista eventi; il loro tempo in aria sì (§4). *Decisione:* senza perdite in aria (§9) un ACK c'è sempre e raddoppierebbe gli eventi senza insegnare niente in più del campo Duration.
- **Beacon:** non trasmessi. *Decisione:* i client trovano la rete con la scansione attiva (§5), che ogni client reale fa. Un beacon ogni 102,4 ms sarebbero 10 eventi al secondo per access point: riempirebbero la lista e in Simulation ogni Passo si fermerebbe su un beacon. La Probe Response porta gli stessi campi di un beacon, intervallo di 100 TU compreso, e l'ispettore li mostra.
- **Dimensioni** (convenzione di Wireshark, senza FCS): intestazione 24 B + corpo per la gestione; 24 + 8 + pacchetto per i dati.
- **Ispettore PDU:** livelli *IEEE 802.11* (tipo e sottotipo per nome, flag, Duration, i tre indirizzi con il loro ruolo — ricevitore, trasmettitore, BSSID, sorgente, destinazione —, numero di sequenza), poi *LLC/SNAP* e il resto come oggi, oppure *Gestione 802.11* con i campi del corpo.
- **Filtro eventi:** un nuovo chip **802.11** per i frame di gestione; i frame dati restano sotto il loro protocollo (ICMP, DHCP…).

## 4. Mezzo radio
- **Un mezzo per canale**, condiviso da tutte le radio sintonizzate su quel canale: un solo frame alla volta, half duplex. Canali 1, 6 e 11.
  - *Decisione:* solo i tre canali che non si sovrappongono a 2,4 GHz. Gli altri servirebbero solo a mostrare l'interferenza fra canali adiacenti, che resta fuori (§9).
- **Accesso al mezzo:** CSMA/CA semplificato ma con i tempi veri di 802.11g (ERP-OFDM, slot corto): ogni frame occupa il mezzo per DIFS (28 µs) + backoff + il frame + per gli unicast SIFS (10 µs) e ACK.
  - Durata di un frame: 20 µs di preambolo e intestazione PLCP + simboli da 4 µs per 16 bit di servizio, i byte del frame con l'FCS e 6 bit di coda (§17.4.3).
  - Backoff: sempre 7 slot da 9 µs, la metà di CWmin = 15. *Decisione:* un valore fisso al posto del sorteggio. Senza collisioni il sorteggio cambierebbe solo il jitter e romperebbe la ripetibilità a parità di seme meno di quanto confonda; il valore medio dà il throughput giusto.
  - *Decisione:* niente collisioni, RTS/CTS e ritrasmissioni. Le radio in attesa si mettono in coda e il mezzo le serve nell'ordine di arrivo: è un CSMA/CA che non sbaglia mai. Quello che si vede è il punto didattico: un mezzo solo, condiviso, con il costo fisso di ogni frame.
  - Velocità: 54 Mb/s per i dati unicast, 6 Mb/s per gestione e frame di gruppo, per l'ACK la velocità di base più alta non superiore a quella del frame (§10.7.6.5.2): 24 Mb/s dopo i dati, 6 Mb/s dopo la gestione. Ogni PPDU ha anche i 6 µs di signal extension di ERP (clausola 18). Con 1470 B di UDP un frame occupa 389 µs: circa 30 Mb/s di throughput utile.
- **Coda:** al massimo 1000 frame in attesa per radio, come la coda di default di un cavo; oltre si scarta (`queue-full`).
- **Eventi:** TX sulla radio che trasmette quando il frame comincia, RX su ogni radio a cui il frame è indirizzato (Indirizzo 1 suo o di gruppo, BSSID suo) quando finisce. Le radio che sentono un frame non loro lo scartano in silenzio, come il filtro MAC di una scheda.
- **Portata (M11a):** ogni radio sente tutte quelle del suo canale. La distanza conta solo in M11b (§8).

## 5. Associazione (M11a)
- **Stati del client:** *nessuna rete* (SSID vuoto o scheda spenta), *scansione*, *autenticazione*, *associazione*, *associato*.
- **Scansione attiva** (§11.1.4.3): una Probe Request con l'SSID configurato su ciascun canale, 1, 6 e 11 nell'ordine, restando 20 ms in ascolto su ognuno. Rispondono gli access point con quell'SSID sul canale. Finita la scansione il client sceglie il primo che ha risposto.
  - Nessuna risposta: nuova scansione dopo 5 s. *Decisione:* senza beacon è la scansione periodica a far trovare un access point acceso o configurato più tardi; 5 s sono pochi da aspettare e restano 3 frame ogni 5 s per client.
- **Autenticazione Open System** (transazione 1 e 2, stato 0) e **associazione** (stato 0 e AID da 1 in su). Senza risposta entro 1 s il client ricomincia la scansione.
- **Associato:** la linea di `wlan0` è su (`lineUp`), come un cavo collegato. IPv6 rifà la DAD (M9 §5); il client DHCP parte all'associazione e non prima.
  - *Decisione:* come NetworkManager e Android, il DHCP aspetta il link; senza, il primo DISCOVER andrebbe perso e il lease arriverebbe solo al tentativo dopo 4 s. Sui cavi resta il comportamento di M3.
- **Frame prima dell'associazione:** i frame dati di un client non associato si scartano con il nuovo motivo `not-associated`.
- **Fine dell'associazione:**
  - SSID o canale dell'access point cambiato: l'access point manda una Deauthentication di gruppo (motivo 3, "lascia il BSS") e i client ricominciano la scansione;
  - rete del client cambiata: il client manda una Deauthentication (motivo 3) all'access point e cerca la rete nuova;
  - access point spento o tolto, oppure client spento o tolto: l'altro lato lo sa subito, senza frame. *Decisione:* come un cavo staccato (M7 §4); un client reale se ne accorgerebbe dopo alcuni beacon persi, che qui non ci sono. Il client ricomincia la scansione.
- Nessuna riassociazione automatica fra access point: un client resta su quello scelto finché l'associazione non cade. *Decisione:* in M11a tutti sentono tutti, quindi non c'è un "più vicino"; il roaming arriva con la portata (M11b).

## 6. Bridge dell'access point (M11a)
- Due porte: Ethernet e radio. La tabella delle associazioni fa da tabella MAC della radio.
  - Da un client verso un altro client associato: ritrasmesso in aria From DS.
  - Da un client verso un MAC di gruppo: su Ethernet e ritrasmesso in aria From DS (il mittente lo riconosce come suo dalla sorgente e lo ignora).
  - Da un client verso un altro MAC: su Ethernet, con l'intestazione 802.3.
  - Da Ethernet verso un client associato o un MAC di gruppo: in aria From DS. Verso altri MAC: ignorato.
- **VLAN:** l'access point manda e riceve frame senza tag; un frame con tag che arriva da Ethernet si scarta (`unknown-vlan`, come un host). La VLAN dei client è quella della porta di accesso dello switch. *Decisione:* niente SSID per VLAN né trunk verso l'access point; serve solo con più SSID, che restano fuori.
- **STP:** l'access point non esegue lo spanning tree e non inoltra BPDU. *Decisione:* è il default di un Aironet autonomo; dal lato radio ci sono solo host, quindi nessun anello passa da lui.
- Il controllo dei duplicati IPv4 (M1) attraversa l'aria: dal client al suo access point, dall'access point ai suoi client associati.

## 7. UI (M11a)
- **Palette:** nuova sezione **Wireless** fra Server e Cavi: Access point, Tablet, Smartphone. La ricerca trova `wireless`, `wifi`, `ap`… come per le altre sezioni. Il menu *Aggiungi dispositivo* del canvas ha le stesse voci.
- **Canvas:** una linea tratteggiata sottile unisce ogni client associato al suo access point; non si seleziona e non si cancella (non è un cavo). I frame in aria viaggiano lungo quella linea come sui cavi.
  - Gli access point non hanno un cavo verso i client: trascinare un cavo da un tablet dà l'errore "nessuna porta libera".
- **Scheda Wi-Fi:**
  - access point: SSID e canale (1, 6, 11); l'errore di un SSID vuoto o più lungo di 32 byte compare sotto il campo;
  - client: per PC e Laptop *Scheda di rete* Ethernet / Wi-Fi; poi la rete (SSID) a cui collegarsi e lo stato: "Associato a pac-track · AP1 · canale 6", "Scansione…", "Nessuna rete trovata".
- **Tabelle:** sull'access point *Client associati* (AID, MAC, nome del client); su un client wireless la riga Wi-Fi con stato, SSID, BSSID e canale.
- **Eventi:** il chip 802.11 si aggiunge agli altri. Oggi la riga dei chip è già piena e alla larghezza del selftest NDP esce tagliato: la riga dei filtri si divide in due, i chip sopra su tutta la larghezza e sotto il nodo e il conteggio degli eventi. *Decisione:* la correzione più piccola che lascia ogni chip visibile e cliccabile; uno stile più compatto guadagnerebbe pochi punti e un menu nasconderebbe i colori dei protocolli. Lo scorrimento laterale resta come riserva sotto la larghezza minima.
- **Metriche:** i grafici restano per i cavi e per i flussi; il mezzo radio non ha un grafico. *Decisione:* i flussi del generatore mostrano già il throughput in aria.

## 8. M11b (sintesi delle decisioni, dettagli nel suo piano)
- **WPA2-PSK:** sull'access point *Sicurezza* Aperta / WPA2-PSK e la password (8–63 caratteri); sul client la password. Probe Response e Association Request portano l'RSN (CCMP, PSK). Dopo l'associazione il 4-way handshake: quattro frame EAPOL-Key (EtherType 0x888E su LLC/SNAP) con ANonce, SNonce, MIC e Install. Niente crittografia vera: il MIC è un'impronta deterministica di password, SSID e nonce, e l'access point lo ricalcola. MIC sbagliato: il messaggio 2 si scarta, il messaggio 1 si ripete fino a 3 volte a 1 s di distanza, poi Deauthentication motivo 15 (timeout del 4-way handshake) e il client si ferma su "Password errata" finché la rete o la password non cambiano. I dati passano solo dopo il messaggio 4; nei frame protetti il flag Protected è acceso e il contenuto resta leggibile (*Decisione:* la lezione è l'handshake, non il CCMP).
- **Router Wi-Fi domestico** (`homeRouter`): porta `Internet` (WAN) in DHCP, quattro porte LAN e la radio in un unico bridge con l'indirizzo 192.168.0.1/24, server DHCP 192.168.0.100–149, NAT da LAN a Internet, SSID e sicurezza come un access point. Riusa router, switch, DHCP e NAT del motore.
- **Portata:** un cerchio intorno a ogni access point (raggio di default sul canvas) e la distanza fra client e access point decide se si sentono, il segnale e la velocità (54 → 6 Mb/s). Spostare un dispositivo aggiorna l'associazione: fuori portata cade, rientrando si riassocia, e fra più access point con lo stesso SSID il client sceglie il segnale più forte.

## 9. Esclusi (tutta M11)
- *Decisione:* controller WLC/CAPWAP, 802.1X/RADIUS ed EAP enterprise, WEP, WPA3, mesh e WDS, più SSID per access point, ad hoc/IBSS, 5 GHz, 802.11n/ac/ax (MIMO, canali larghi, aggregazione), risparmio energetico, frammentazione, collisioni e interferenza fra canali, perdite e ritrasmissioni in aria. Ognuno vorrebbe un modello che nessun laboratorio delle due milestone usa.

## 10. Persistenza e copie
- I nuovi tipi si salvano con il loro nome (`accessPoint`, `tablet`, `smartphone`); `Topology.version` resta 1. Nuove chiavi facoltative su `TopologyNode`: la configurazione dell'access point (SSID, canale) e quella del client (SSID); un PC o un laptop con la scheda Wi-Fi ha `wlan0` al posto di `eth0` fra le interfacce. I file di M1–M10 non cambiano e si aprono come prima.
- Associazioni e numeri di sequenza sono stato di esecuzione: non si salvano. Riaprendo il file i client si riassociano da soli.
- Copia, incolla e duplica tengono SSID e canale dell'access point, la rete del client e la scheda Wi-Fi di un PC o laptop. *Decisione:* non sono indirizzi; due access point con lo stesso SSID formano una rete sola.
- Annulla, export PNG (con le linee tratteggiate) e selftest trattano i nuovi tipi come gli altri.

## 11. Test (aggiunte al §10 della spec principale)
- **PDU:** dimensioni e indirizzi dei frame dati e di gestione, durata in aria (preambolo, simboli, DIFS, backoff, ACK), Duration.
- **Motore:** scansione sui tre canali e scelta; autenticazione e associazione; scansione ripetuta dopo 5 s; DHCP all'associazione; ping client–client (due passaggi in aria) e client–cavo; frame di gruppo ripetuti dall'access point; `not-associated`; Deauthentication al cambio di SSID; access point spento; coda piena; nessun cavo su `wlan0` né su `Dot11Radio0`; scheda Wi-Fi di PC e laptop (rifiutata con il cavo); throughput UDP ~30 Mb/s; nessun BPDU inoltrato; frame con tag scartato.
- **Editor:** default di access point, tablet e smartphone in un passo di annulla; cambio di scheda con la modalità DHCP; copie; il laboratorio del §1.
- **`.ptk`:** round-trip dei nuovi tipi e della scheda Wi-Fi; i file esistenti invariati (suite esistente).
- **Selftest M11a:** il laboratorio del §1 con le linee tratteggiate, la scheda Wi-Fi di un client e dell'access point, le Tabelle, un frame 802.11 nell'ispettore e la riga dei chip con 802.11 tutta visibile.
