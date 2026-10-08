# pac-track v3 — M7: VLAN 802.1Q e Spanning Tree per VLAN (PVST+)

> Estende la spec principale `2026-10-07-pac-track-rewrite-design.md` (rev. 2), che elenca VLAN 802.1Q e STP tra le fasi successive all'MVP (§3). Valgono le sue regole su motore, determinismo, UI, persistenza ed errori. Scelta dell'utente (2026-10-08): **PVST+** (802.1D per VLAN, come Cisco di default). Le altre decisioni sono state prese in autonomia su richiesta dell'utente; ognuna è marcata *Decisione* con il motivo.

## 1. Obiettivo
Segmentare una LAN in VLAN e vedere lo Spanning Tree convergere per ogni VLAN, pacchetto per pacchetto: porte access/trunk con tag 802.1Q, MAC table per VLAN, routing inter-VLAN con router-on-a-stick, BPDU, elezione della root, stati delle porte con i timer reali, topology change. I loop L2 su switch smettono di essere solo un avviso: STP li blocca.

**Successo:** due VLAN su due switch collegati da un trunk; i PC della stessa VLAN si pingano, quelli di VLAN diverse solo passando dal router con sottointerfacce; un secondo cavo tra gli switch non crea broadcast storm perché una porta va in blocking; staccando il primo cavo, la porta bloccata passa a forwarding e il ping riprende: dopo 2 × forward delay (30 s simulati) se il guasto tocca direttamente lo switch con la porta bloccata, dopo max age + 2 × forward delay (50 s) se è indiretto.

## 2. VLAN 802.1Q
- **Frame:** `EthernetFrame` acquista un tag opzionale (`vlan: Int?`). Con il tag la dimensione cresce di 4 B (TPID 0x8100 + TCI con VID; PCP e DEI a 0). L'ispettore PDU mostra il livello "802.1Q" con il VID.
- **Porte dello switch:** ogni porta è `access` (una VLAN, default 1) o `trunk` (VLAN ammesse: default tutte, oppure una lista come `10,20,30-35`; VLAN nativa: default 1). Sulle porte access i frame entrano ed escono senza tag. Sul trunk, la VLAN nativa viaggia senza tag e le altre con il tag. Un frame taggato con una VLAN non ammessa viene scartato con un evento di drop motivato. Lo stesso vale per un frame taggato che arriva su una porta access.
- **Inoltro:** MAC table con chiave (VLAN, MAC). Flooding e unicast restano nella VLAN del frame: escono solo dalle porte di quella VLAN in stato forwarding.
- *Decisione:* nessun database delle VLAN da creare a mano (niente `vlan 10` / VTP); una VLAN esiste se una porta la usa. Il motivo è che in un simulatore senza CLI quel passo non insegna nulla. Niente DTP: il ruolo della porta si sceglie a mano. Niente voice VLAN né QinQ.
- **Host, server e Cloud:** non usano tag. Un frame taggato che arriva a un host viene scartato.
- **Hub:** inoltra i frame così come arrivano, tag compreso.

## 3. Routing inter-VLAN (router-on-a-stick)
- Un router può avere **sottointerfacce** `<fisica>.<n>` (es. `Gi0/0.10`) con `encapsulation dot1q <VID>`, un indirizzo IPv4 e un MAC uguale a quello della fisica, come su IOS. L'interfaccia fisica può avere anche un indirizzo suo, che resta sulla nativa/untagged.
- In ricezione, un frame con tag VID viene consegnato alla sottointerfaccia con quel VID. Un VID senza sottointerfaccia corrispondente dà un drop con motivo. In trasmissione, ciò che esce da una sottointerfaccia viene taggato con il suo VID.
- Le sottointerfacce funzionano come interfacce L3 a tutti gli effetti: route connesse, ARP, DHCP server, NAT inside/outside, regole firewall.
- *Decisione:* niente switch L3/SVI, perché router-on-a-stick è il laboratorio classico e riusa il router esistente. Gli switch L3 si aggiungono quando servono.

## 4. Spanning Tree per VLAN (PVST+, 802.1D)
- **Istanze:** una per ogni VLAN attiva su almeno una porta dello switch.
- **Bridge ID:** priorità (default 32768) + VLAN (sys-id-ext) + MAC dello switch. La priorità si imposta per switch e per VLAN, in multipli di 4096 (0–61440).
- **BPDU di configurazione:**
  - campi 802.1D: root ID, costo verso la root, bridge ID, port ID (priorità 128 + numero di porta), message age, max age 20 s, hello 2 s, forward delay 15 s;
  - inviate ogni hello time dalle porte designated;
  - destinazione Cisco SSTP `01:00:0C:CC:CC:CD`, con il tag della VLAN sui trunk (senza tag sulla nativa e sulle porte access);
  - decodificate nell'ispettore PDU come livello "STP".
- *Decisione:* le BPDU sono solo nel formato PVST+ e non c'è la copia IEEE `01:80:C2:00:00:00` per la VLAN 1. Nel simulatore tutti gli switch parlano PVST+, quindi la copia IEEE servirebbe solo a interoperare con switch IEEE che qui non esistono.
- **Costi:** 802.1D-1998, quelli usati di default da Cisco: 10 Mb/s 100, 100 Mb/s 19, 1 Gb/s 4, 10 Gb/s 2. Per i cavi personalizzati si prende il valore della fascia di banda più vicina, arrotondando per difetto. Non si può impostare un costo per porta.
- **Algoritmo 802.1D:**
  - elezione della root (bridge ID minore);
  - scelta della root port in quest'ordine: costo minore, poi bridge ID del mittente minore, poi port ID del mittente minore;
  - una porta designated per segmento; tutte le altre restano in blocking.
- **Stati e timer:**
  - un guasto del cavo (*Simula guasto*, *Scollega* o vicino spento) viene rilevato subito da entrambe le estremità, che vedono la porta giù; se era la root port, lo switch ricalcola subito, senza aspettare max age;
  - una porta nuova o riattivata parte in **blocking**;
  - se diventa root o designated passa a **listening**, dopo forward delay a **learning** (impara i MAC ma non inoltra), dopo un altro forward delay a **forwarding**;
  - una porta in blocking che smette di ricevere BPDU migliori ricomincia il processo dopo max age.
  - Ogni cambio di stato è un evento in lista.
- **Topology change:**
  1. Uno switch che porta una porta in forwarding, o la toglie da forwarding, manda una **TCN** dalla root port.
  2. Chi la riceve risponde con il bit TCA e la inoltra verso la root.
  3. La root mette il flag **TC** nelle sue BPDU per max age + forward delay (35 s).
  4. Per tutto quel tempo, gli switch che ricevono TC usano forward delay (15 s) come aging della MAC table invece di 300 s.
- **PortFast:** opzione per singola porta access, spenta di default come su IOS. Con PortFast la porta va subito in forwarding e un suo cambio di stato non genera TCN. *Decisione:* senza questa opzione ogni PC collegato aspetterebbe 30 s prima di comunicare; la si lascia spenta di default per fedeltà a IOS.
- *Decisione:* fuori da M7 BPDU guard, root guard, loop guard, UplinkFast/BackboneFast, RSTP/MST e EtherChannel.
- **Avviso di loop L2:** resta attivo. Ora scatta solo se il loop c'è davvero, per esempio con degli hub o con STP ancora in convergenza.

## 5. Interfaccia (testi in italiano)
- **Scheda Porte dello switch:** per ogni porta, modalità Access/Trunk; VLAN access oppure VLAN ammesse e nativa sul trunk; PortFast. Gli errori sono mostrati sul campo: VLAN fuori da 1–4094, lista non valida, nativa non ammessa.
- **Scheda Servizi dello switch:** sezione *Spanning Tree* con la priorità per ciascuna VLAN attiva (scelta fra 0 e 61440 in passi di 4096).
- **Scheda Tabelle dello switch:**
  - la MAC table guadagna la colonna VLAN;
  - nuova tabella *Spanning Tree* per VLAN: root ID, costo, root port e, per ogni porta, ruolo (root/designated/blocked) e stato (blocking/listening/learning/forwarding).
- **Router, scheda Interfacce:** "Aggiungi sottointerfaccia" (interfaccia fisica, VID, IPv4/prefisso) e "Elimina" sulla sottointerfaccia.
- **Canvas:** i cavi mostrano lo stato STP alle estremità. Un pallino ambra indica listening o learning, un pallino rosso indica blocking (convenzione Packet Tracer); forwarding non ha indicatori. L'etichetta di un trunk dice "trunk".
- **Lista eventi:** filtro protocollo "STP" e colore dedicato.

## 6. Persistenza ed errori
- Nel `.ptk`, sul nodo:
  - switch: le porte con modalità, VLAN, VLAN ammesse, nativa e PortFast, più le priorità STP per VLAN;
  - router: le sottointerfacce.
- Lo stato STP (ruoli, stati, timer) e le MAC table non si salvano. A ogni caricamento la convergenza riparte, come per ARP e DHCP.
- Un file M6, che non ha queste chiavi, si apre con tutte le porte access in VLAN 1, PortFast spento e priorità 32768. Un file vecchio con un loop di switch quindi converge.
- Errori tipizzati: VID fuori intervallo, VID duplicato sulla stessa interfaccia fisica, nome della sottointerfaccia già in uso, sottointerfaccia su un dispositivo che non è un router, priorità non multipla di 4096. Il controllo "IP duplicato nello stesso segmento" ora tiene conto delle VLAN: segmento = dominio di broadcast.

## 7. Test (aggiunte al §10 della spec principale)
- Access/trunk:
  - tag presente o assente sul cavo, dimensione +4 B;
  - inoltro limitato alla VLAN;
  - VLAN non ammessa scartata;
  - nativa senza tag.
- Router-on-a-stick: ping tra due VLAN con TTL decrementato di 1; ARP sulla sottointerfaccia giusta.
- PVST+:
  - elezione della root per VLAN con priorità diverse (root diverse per VLAN 10 e 20);
  - root port e porta bloccata sul triangolo di tre switch;
  - sequenza degli stati con i tempi esatti (15 s + 15 s);
  - due switch con due cavi: nessuna broadcast storm;
  - failover diretto (30 s) e indiretto (50 s);
  - TCN/TC che riduce l'aging;
  - PortFast in forwarding immediato.
- `.ptk`: round-trip della configurazione VLAN/STP/sottointerfacce; apertura di un file M6.
- Selftest: immagini della scheda Porte, della tabella STP e di un canvas con una porta bloccata.
