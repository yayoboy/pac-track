# pac-track v3 — M10: altri host

> Estende la spec principale `2026-10-07-pac-track-rewrite-design.md` (rev. 2) e le spec M7, M8 e M9; valgono le loro regole su motore, determinismo, UI, persistenza ed errori. Aprendo l'app l'utente ha trovato pochi dispositivi rispetto a Packet Tracer; fra i gruppi proposti ha scelto **altri host** (questa milestone) e **wireless** (M11, a parte: access point, router Wi-Fi domestico, schede wireless, tablet e smartphone). Le decisioni sono prese in autonomia; ognuna è marcata *Decisione* con il motivo. La regola guida è riusare lo stack degli host e i servizi che esistono già (client DHCP, DNS, sink del generatore, schede dell'ispettore): nessun comportamento nuovo nel motore oltre a dove è ammesso il sink.

## 1. Obiettivo
Più dispositivi finali nella palette, ognuno con la sua icona, un nome italiano e default sensati, che funzionano appena trascinati sul canvas: una stampante, una smart TV, un server DNS e un server DHCP.

**Successo M10:** SW1 con un *Server DHCP* (SRV1), una *Smart TV* (TV1), una *Stampante* (PRN1) e un PC (PC1), cavi diretti. Nessuna configurazione su SRV1 e TV1; PRN1 riceve `192.168.1.50/24`, PC1 passa in DHCP.
- TV1 e PC1 ricevono un indirizzo fra 192.168.1.100 e 192.168.1.199 da SRV1 (192.168.1.2) a 60 s: le porte dello switch passano in forwarding a 30 s (M7) e il client DHCP ritrasmette il DISCOVER a 4, 12, 28 e 60 s (M3).
- Il generatore TCP di PC1 verso `192.168.1.50` finisce con `iperf Done.`: la stampante riceve il "lavoro di stampa" e lo scarta.
- Il file si salva e si riapre uguale; un file di M9 si apre come prima.

## 2. Nuovi dispositivi
- **Stampante** (`printer`, nomi `PRN1`, `PRN2`…, icona `printer`): un host con eth0, come un PC (indirizzo statico o DHCP, gateway, server DNS, IPv6 e SLAAC).
  - Arriva con il **sink** acceso: riceve e scarta TCP e UDP del generatore di traffico, cioè fa da destinazione dei lavori di stampa. Il sink si spegne dalla scheda Servizi, che sulla stampante mostra solo lui.
  - *Decisione:* porta 9 (discard) come il sink del server, non 9100 (RAW/JetDirect). Il generatore manda sempre alla 9 e una porta diversa vorrebbe un campo porta in più; la stampante resta una destinazione di traffico, non un protocollo di stampa.
  - *Decisione:* nessun indirizzo all'arrivo, come un PC. Una stampante si indirizza a mano perché i client la trovino; con DHCP cambierebbe indirizzo.
  - Schede: Interfacce, Routing, Servizi, Tabelle, App (ping e traceroute dalla stampante servono per le verifiche).
- **Smart TV** (`tv`, nomi `TV1`…, icona `tv`): un host con eth0 e le schede di un PC.
  - Arriva con eth0 **in DHCP**. *Decisione:* come un televisore appena tolto dalla scatola; basta collegarla a una rete con un server DHCP.
- Entrambi sono host per il motore: stesso stack, client DHCP, NDP/SLAAC, ping, traceroute, nslookup, generatore. Non fanno da server DHCP o DNS.

## 3. Server preconfigurati
- **Server DNS** e **Server DHCP** sono voci della palette che creano un normale `server` con un servizio già acceso, in un solo passo di annulla.
  - *Decisione:* preset di `server` e non nuovi tipi. Nel file restano server come gli altri, le schede e i servizi sono quelli di un server, e nessun controllo del motore cambia. Il precedente è la Cloud/ISP, che arriva già configurata (§5.5 della spec principale).
  - Il nome è `SRV<n>` come per ogni server, e l'icona quella del server.
- **Server DHCP:** eth0 `192.168.1.2/24` e pool suggerito `192.168.1.100`–`192.168.1.199` (come accendere il servizio dalla scheda Servizi), senza gateway né DNS da distribuire.
  - *Decisione:* 192.168.1.0/24, la rete domestica più familiare; .1 resta libero per il router. Gateway e DNS dipendono dal laboratorio e si scrivono nella scheda Servizi.
- **Server DNS:** eth0 `192.168.1.3/24` e server DNS acceso senza record.
  - *Decisione:* nessun record di esempio, perché i nomi dipendono dal laboratorio; l'indirizzo è nella stessa rete del Server DHCP così i due preset funzionano insieme.
- Due preset uguali sullo stesso segmento hanno lo stesso indirizzo: come per la Cloud, l'editor non rifiuta un duplicato creato collegando segmenti, e la tabella ARP lo mostra.

## 4. Esclusi
- *Decisione:* niente **Telefono IP**. In Packet Tracer è definito dalla telefonia (SIP/SCCP, call manager, voice VLAN, PoE); senza chiamate sarebbe un PC con un'altra icona che promette ciò che non fa.
- *Decisione:* niente **Server web**. Il motore non ha HTTP e il sink non è un server web.
- *Decisione:* niente **host con più schede di rete**. Client DHCP, SLAAC, il campo indirizzo e il gateway degli host sono legati a eth0; una seconda scheda vuol dire moduli e regole di inoltro da decidere, quando un laboratorio ne avrà bisogno.
- Tablet e smartphone sono solo wireless (come in Packet Tracer): M11.

## 5. Palette e menu
- Sezioni: **Rete** (Router, Switch, Hub, Cloud/ISP), **Host** (PC, Laptop, Stampante, Smart TV), **Server** (Server, Server DNS, Server DHCP), **Cavi**.
- La ricerca "Cerca" filtra per nome e per sezione, come oggi: `stamp` trova la Stampante, `server` tutta la sezione Server, `tv` la Smart TV.
- L'elenco scorre quando la finestra è bassa (altezza minima 640 pt); il campo di ricerca resta in alto e il suggerimento in basso. Nessuna voce va a capo o si tronca nei 170 pt della palette.
- Il menu *Aggiungi dispositivo* del canvas elenca le stesse voci nello stesso ordine, preset compresi.

## 6. Persistenza e copie
- I nuovi tipi si salvano con il loro nome (`printer`, `tv`); `Topology.version` resta 1. I file di M1–M9 non cambiano e si aprono come prima. Un file con i nuovi tipi aperto da una versione precedente dà l'errore tipizzato di file non valido.
- Copia, incolla e duplica creano lo stesso tipo con i nomi successivi. *Decisione:* le copie ora tengono anche il **sink**, che come la modalità DHCP non è un indirizzo: la copia di una stampante resta una stampante che riceve. Vale anche per i server; pool DHCP e record DNS restano indietro come prima, perché contengono indirizzi.
- Annulla, export PNG e selftest trattano i nuovi tipi come gli altri.

## 7. Test (aggiunte al §10 della spec principale)
- **Motore:** stampante e smart TV sono host (ping, DHCP); il sink si accende su stampante e server e si rifiuta sulla smart TV; DHCP e DNS server si rifiutano su entrambe.
- **Editor:** default della stampante (sink) e della smart TV (DHCP) in un passo di annulla; i preset Server DNS e Server DHCP in un passo; le copie tengono il sink; il laboratorio del §1.
- **`.ptk`:** round-trip dei nuovi tipi con sink e modalità DHCP; i file esistenti invariati (suite esistente).
- **Selftest M10:** la ricerca della palette, il laboratorio del §1 e le immagini della palette e del laboratorio con i nuovi dispositivi.
