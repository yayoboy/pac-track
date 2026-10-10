# pac-track v3 — M8: routing dinamico (RIPv2, OSPFv2)

> Estende la spec principale `2026-10-07-pac-track-rewrite-design.md` (rev. 2), che elenca il routing dinamico (RIP/OSPF) tra le fasi successive all'MVP (§3), e la spec M7 (`2026-10-08-m7-vlan-stp-design.md`) per sottointerfacce e VLAN. Valgono le loro regole su motore, determinismo, UI, persistenza ed errori. La milestone si divide come M7: **M8a** RIPv2 (RFC 2453) con le parti comuni che servono a RIP, **M8b** OSPFv2 (RFC 2328) in area singola. Su richiesta dell'utente le decisioni sono prese in autonomia; ognuna è marcata *Decisione* con il motivo. Riferimenti di fedeltà: le RFC e i default di Cisco IOS 15.

## 1. Obiettivo
Far imparare le route ai router da soli e vedere il protocollo lavorare pacchetto per pacchetto: update RIP periodici e triggered, split horizon, metrica 16 come infinito, timeout; in M8b hello OSPF, adiacenze, elezione di DR e BDR, scambio del database, SPF. La tabella di routing dice da dove viene ogni route (C, S, R, O) con distanza amministrativa e metrica, come `show ip route`.

**Successo M8a:** tre router a triangolo (R1–R2 10.0.12.0/30, R1–R3 10.0.13.0/30, R2–R3 10.0.23.0/30), PC1 su R1 (192.168.1.0/24) e PC2 su R2 (192.168.2.0/24), RIP attivo su tutte le interfacce e passivo verso i PC; il file si apre a t = 0.
- A t = 0 ogni router manda una Request e un update con le sue reti connesse; pochi µs dopo R1 ha `R 192.168.2.0/24 [120/1] via 10.0.12.2`. A t = 1 s partono i triggered update con quanto appreso. Un ping da PC1 a PC2 a t = 2 s riceve risposta con TTL 62.
- Gli update periodici partono a t = 30, 60, 90 s…
- *Simula guasto* sul cavo R1–R2 a t = 40 s: R1 e R2 vedono subito la linea giù, mettono a metrica 16 le route che passavano da lì e mandano un triggered update. A t = 60 s l'update periodico di R3 porta `192.168.2.0/24` con metrica 2 e R1 installa `[120/2] via 10.0.13.2`: il ping riprende, 20 s dopo il guasto (in generale entro 30 s).
- Se invece un vicino smette di parlare senza che la linea cada (RIP spento su R2, oppure R2 dietro uno switch e spento), la sua route scade 180 s dopo l'ultimo update ricevuto e sparisce 120 s dopo.

**Successo M8b:** la stessa rete con OSPF al posto di RIP. Sui cavi router–router (rete broadcast, il default IOS su Ethernet) i router si vedono (Init) con i primi hello a t = 0, diventano 2-Way al secondo hello (10 s), eleggono DR e BDR allo scadere del wait timer (40 s) e arrivano a Full pochi ms dopo. Con le interfacce in point-to-point le adiacenze vanno in Full a 10 s, senza elezione. L'SPF parte 5 s dopo il primo cambio del database, quindi a 45 s R1 ha `O 192.168.2.0/24 [110/2]`. Con *Simula guasto* su R1–R2 a t = 50 s l'adiacenza cade subito, i router riemettono la loro router-LSA e a 55 s R1 passa per R3 con `[110/3]`. Spegnendo R2 dietro uno switch, l'adiacenza cade dopo il dead interval (40 s).

## 2. Parti comuni (M8a, poi estese in M8b)
- **Distanza amministrativa** (default IOS): connessa 0, statica 1, OSPF 110, RIP 120, default da DHCP 254. Prima vince il prefisso più lungo; a parità di prefisso vince la distanza minore. Una statica il cui next hop non è raggiungibile non conta, quindi a quel prefisso vince la route dinamica.
- **RIB:** un protocollo installa al massimo una route per prefisso, quella con metrica migliore. Una route dinamica oscurata da una connessa o da una statica con lo stesso prefisso resta nel database del protocollo ma non compare in tabella. Il protocollo non la annuncia, perché senza redistribuzione IOS annuncia solo le sue route installate.
- *Decisione:* niente ECMP: un solo next hop per destinazione, il primo appreso a parità di metrica. RFC 2453 conserva una sola route; IOS ne installa fino a 4, ma il bilanciamento per pacchetto o per flusso renderebbe l'inoltro meno leggibile.
- **Linea su/giù:** per i protocolli dinamici un'interfaccia è operativa se il dispositivo è acceso, il cavo è collegato e senza guasto, e il dispositivo all'altra estremità è acceso. Per una sottointerfaccia conta la sua interfaccia fisica. È lo stato `up/up` di IOS.
- *Decisione:* le route connesse della tabella restano quelle di oggi, presenti anche a cavo staccato. Solo i protocolli dinamici guardano lo stato della linea, quindi non annunciano una rete connessa a linea giù. Il motivo è che togliere le connesse cambierebbe i motivi di drop di tutti i laboratori esistenti, da `link-down` a `no-route`.
- **Abilitazione senza CLI:** nella scheda Servizi del router, un interruttore per protocollo e, per ogni interfaccia, la partecipazione (spenta, attiva, passiva). Equivale a `router rip` + `network` per le interfacce scelte + `passive-interface`.
  - *Decisione:* la partecipazione si sceglie per interfaccia invece che con istruzioni `network` classful. In un simulatore senza CLI è più chiaro e con gli indirizzi di un laboratorio porta allo stesso risultato. Se un'interfaccia cambia indirizzo, partecipa con quello nuovo.
  - *Decisione:* all'accensione del protocollo partecipano tutte le interfacce che hanno un indirizzo, attive e non passive. È il caso più comune; le reti verso i PC si rendono passive a mano.
  - Un'interfaccia passiva non manda nulla, nemmeno in risposta a una Request, ma la sua rete viene annunciata dalle altre e ciò che arriva su di essa viene elaborato, come con `passive-interface` di IOS.
  - Solo i router (non il Cloud) hanno RIP e OSPF, come NAT e firewall.
- **NAT, firewall, sottointerfacce (M5/M7a):**
  - le sottointerfacce partecipano come le interfacce fisiche e i loro pacchetti escono con il tag della VLAN;
  - il firewall filtra in ingresso anche i pacchetti di routing, come un'ACL di IOS: con policy di default *nega* bisogna consentire UDP 520 (RIP) o il protocollo IP 89 (OSPF, regola *qualsiasi*), altrimenti il vicino non viene appreso e il drop compare in lista;
  - i pacchetti di routing generati dal router non passano dal NAT;
  - l'interfaccia outside di solito non partecipa.
- *Decisione:* una sottointerfaccia che partecipa a un protocollo non si può eliminare, come succede già quando ha un ruolo NAT o regole firewall.
- **Indirizzi multicast:** il router accetta il MAC multicast del gruppo (01:00:5e:…) solo se il protocollo è acceso; host e router senza protocollo lo scartano alla NIC, come chi non si è iscritto al gruppo. Gli switch lo inoltrano in flooding nella VLAN, perché non c'è IGMP snooping.
- *Decisione:* i pacchetti di routing hanno TTL 1. Gli indirizzi 224.0.0.0/24 sono link-local (RFC 5771) e non vengono mai inoltrati.

## 3. RIPv2 (M8a, RFC 2453)
- **Pacchetti:** UDP 520 → 520, verso 224.0.0.9 (MAC 01:00:5e:00:00:09) con sorgente l'indirizzo dell'interfaccia di uscita. Header di 4 B (comando, versione 2, zero) più voci da 20 B (AFI 2, route tag 0, indirizzo, maschera, next hop 0.0.0.0, metrica), al massimo 25 per messaggio; gli update più grandi si dividono in più messaggi.
  - Request: una voce con AFI 0 e metrica 16, cioè "mandami tutta la tabella".
  - Response: update periodici, triggered o di risposta. La risposta a una Request va in unicast all'indirizzo e alla porta di chi l'ha chiesta.
- **Metrica:** hop count, 16 = irraggiungibile.
  - *Decisione:* come IOS, la metrica salvata è quella ricevuta e il router aggiunge 1 quando annuncia. Le connesse valgono 0 e partono con 1. Sul cavo i valori sono identici alla RFC, che invece aggiunge 1 in ricezione, e la tabella mostra `[120/1]` per una rete a un router di distanza, come IOS.
  - Una route ricevuta con metrica 15 è installata e annunciata con 16.
- **Avvio:** all'accensione del protocollo, del router o di una nuova interfaccia, il router manda subito una Request su ogni interfaccia attiva e un update con le sue reti connesse.
- **Update periodici:** ogni 30 s dall'avvio, con l'intera tabella su ogni interfaccia attiva, non passiva e con la linea su.
  - *Decisione:* nessun jitter casuale sui 30 s. Senza deriva degli orologi non serve a evitare la sincronizzazione, e i tempi restano esatti e ripetibili come quelli di STP.
- **Split horizon semplice**, il default IOS: una route non esce dall'interfaccia da cui è stata appresa, e una rete connessa non esce dalla sua interfaccia.
  - *Decisione:* niente poisoned reverse. È il default IOS e gli update restano piccoli; la RFC lo raccomanda ma non lo impone.
- **Triggered update:** quando una route cambia (nuova, metrica diversa, irraggiungibile), il router manda subito solo le route cambiate, con lo split horizon. Un update periodico azzera le modifiche in sospeso.
  - *Decisione:* dopo un triggered update, il successivo aspetta almeno 1 s. La RFC chiede un'attesa casuale fra 1 e 5 s; il valore fisso, il minimo dell'intervallo, mantiene i tempi esatti.
- **Elaborazione di una Response** (RFC 2453 §3.9.2):
  - viene ignorata se la porta sorgente non è 520, se la sorgente non sta nella subnet dell'interfaccia di arrivo, se viene dal router stesso o se arriva su un'interfaccia che non partecipa;
  - si ignorano le voci con metrica fuori da 1–16 e quelle per una rete connessa del router;
  - una rete nuova con metrica < 16 viene aggiunta;
  - dallo stesso next hop: il timeout riparte e la metrica si aggiorna; con metrica 16 parte la cancellazione;
  - da un altro router: la route si sostituisce solo se la metrica è strettamente migliore.
- **Timer:** timeout 180 s dall'ultimo update; poi la route passa a metrica 16, parte la garbage collection di 120 s e viene annunciata a 16 (route poisoning); allo scadere è cancellata. Una route in garbage collection viene subito sostituita da una qualsiasi con metrica < 16.
  - *Decisione:* timer RFC 2453 (timeout 180 s, garbage collection 120 s) e non quelli IOS (invalid 180, holddown 180, flush 240). L'holddown viene da IGRP e non è nello standard; senza holddown il failover è visibile in decine di secondi invece che in minuti. Per la convergenza normale i due comportamenti coincidono.
- **Linea giù:** quando cade la linea di un'interfaccia (guasto, cavo staccato, vicino spento), le route apprese da lì e la rete connessa vanno subito a metrica 16 e parte un triggered update. Quando la linea torna, la rete connessa torna con metrica 0, parte un triggered update e il router manda una Request su quell'interfaccia.
  - *Decisione:* la RFC lascia scadere le route; IOS le toglie subito quando l'interfaccia va giù. Si segue IOS perché il guasto di un cavo è il caso didattico più comune.
- *Decisione:* `auto-summary` spento e non configurabile, come in IOS 15: RIPv2 annuncia le subnet con la loro maschera e le reti discontigue funzionano.
- *Decisione:* niente eventi di stato per le route RIP. I cambi si vedono nella tabella e nei triggered update, a differenza degli stati STP che non producono pacchetti.
- *Decisione:* fuori da M8a l'autenticazione (RFC 2453 §4.1, MD5), RIPv1 e la compatibilità di versione, RIPng, `default-information originate`, la redistribuzione, offset-list, timer configurabili, l'holddown IOS e il campo next hop diverso da 0.0.0.0 (sempre inviato a zero e ignorato in ricezione).

## 4. OSPFv2 (M8b, RFC 2328, area singola)
- **Pacchetti:** protocollo IP 89, TTL 1, verso 224.0.0.5 (AllSPFRouters) e, dai non-DR verso DR e BDR, 224.0.0.6 (AllDRouters). Header OSPF di 24 B (versione 2, tipo, lunghezza, router ID, area 0.0.0.0, checksum, autenticazione nulla). Tipi: Hello, Database Description, Link State Request, Link State Update, Link State Acknowledgment. L'ispettore PDU li decodifica come livello "OSPF".
- **Router ID:** il più alto indirizzo IPv4 fra le interfacce con la linea su, scelto all'avvio di OSPF, come IOS senza loopback. *Decisione:* si può anche impostare a mano nella scheda Servizi (`router-id`), perché gli esercizi sull'elezione del DR lo richiedono. Cambia solo al riavvio del processo, cioè allo spegnimento e riaccensione di OSPF o del router, come `clear ip ospf process`.
- **Tipi di rete:** broadcast (default IOS su Ethernet) con elezione di DR/BDR; point-to-point scelto per interfaccia (`ip ospf network point-to-point`), senza elezione, che conviene su un cavo diretto fra due router.
- **Timer:** hello 10 s, dead 40 s, wait 40 s, ritrasmissione 5 s, InfTransDelay 1 s, LSRefreshTime 1800 s, MaxAge 3600 s. Non sono configurabili.
- **Adiacenze:** gli stati Down, Init, 2-Way, ExStart, Exchange, Loading e Full seguono la macchina a stati della RFC, con master/slave nella DBD e LSR/LSU/LSAck. Ogni cambio di stato del vicino è un evento di tipo STATO con protocollo OSPF (per esempio `10.0.0.2 Gi0/1: Loading → Full`).
  - *Decisione:* gli LSAck partono subito, senza ack ritardati; le ritrasmissioni restano quelle della RFC.
  - *Decisione (M8b):* anche i cambi di stato dell'interfaccia sono eventi STATO OSPF (per esempio `Waiting → DR`), perché rendono visibile l'elezione.
  - *Decisione (M8b):* un nuovo vicino non riceve un hello di risposta immediato. Si aspetta l'hello periodico, come IOS su Ethernet: per questo il 2-Way arriva al secondo hello.
  - *Decisione (M8b):* i vicini si identificano con il router ID su entrambi i tipi di rete, come mostra `show ip ospf neighbor`.
  - *Decisione (M8b):* il numero di sequenza DD iniziale è il tempo simulato in ms invece di un valore casuale: è deterministico e diverso a ogni tentativo.
  - *Decisione (M8b):* il riepilogo del database viaggia in una sola DBD (il bit M resta quello della RFC). Il database di un laboratorio sta in un pacchetto da 1500 B.
- *Decisione (M8b):* niente MinLSInterval né MinLSArrival. Le LSA proprie si riemettono appena cambia qualcosa, raccogliendo i cambi dello stesso istante. In un laboratorio non serve frenare l'origine delle LSA, e i tempi restano leggibili.
- *Decisione (M8b):*
  - una LSA di un altro router esce dal database quando raggiunge MaxAge, senza flooding;
  - una LSA ritirata in anticipo esce subito dopo essere stata inoltrata, senza aspettare gli ack;
  - una network-LSA propria viene ritirata quando il router non è più DR o non ha più vicini Full.
- *Decisione (M8b):* una LSA propria più recente che torna indietro dopo un riavvio fa riemettere la LSA con un numero di sequenza successivo (RFC §13.4), anche se il contenuto è identico.
- *Decisione (M8b):* le modifiche alla configurazione hanno effetti diversi:
  - il tipo di rete fa ripartire l'interfaccia e le sue adiacenze;
  - la priorità vale dalla prossima elezione;
  - una nuova banda del cavo ricalcola il costo e riemette la router-LSA, senza far cadere le adiacenze.
- *Decisione (M8b):* le interfacce passive non mandano hello e compaiono nella router-LSA come stub, come con `passive-interface`.
- *Decisione (M8b):* con RIP e OSPF sullo stesso router vince la route OSPF (110 contro 120). RIP non annuncia le reti che conosce solo tramite OSPF, perché non c'è redistribuzione.
- **Elezione DR/BDR** (RFC 2328 §9.4): priorità per interfaccia (default 1, 0 = mai DR, impostabile 0–255), poi router ID maggiore. Allo scadere del wait timer, nessuna preemption: un router con priorità più alta che arriva dopo non toglie il ruolo a chi ce l'ha. Su una rete broadcast i DROther restano in 2-Way fra loro e vanno in Full solo con DR e BDR.
- **LSA:** tipo 1 (router-LSA, con link point-to-point, transit e stub) e tipo 2 (network-LSA, generata dal DR). Flooding affidabile, sequence number, età, checksum Fletcher calcolato davvero, refresh a 1800 s e MaxAge a 3600 s.
- **SPF:** Dijkstra sul database (RFC 2328 §16.1), le route vanno in tabella con distanza 110 e il costo totale come metrica.
  - *Decisione:* l'SPF parte 5 s dopo il primo cambio, che è il ritardo iniziale IOS (`timers throttle spf`), e i cambi arrivati nel frattempo confluiscono in un solo calcolo. Niente backoff esponenziale: in un laboratorio non serve.
- **Costo:** reference bandwidth 100 Mb/s (default IOS) diviso la banda del cavo, minimo 1. 10 Mb/s costa 10, 100 Mb/s e oltre costano 1, come su IOS. *Decisione:* il costo non si imposta per interfaccia, lo si cambia con la banda del cavo; reference bandwidth fissa.
- **Linea giù:** l'adiacenza cade subito (evento KillNbr), la router-LSA viene riemessa e parte l'SPF. Un vicino che sparisce senza che la linea cada viene perso al dead interval.
- *Decisione:* fuori da M8b più aree e ABR/ASBR, LSA 3/4/5/7, aree stub/NSSA, virtual link, autenticazione, reti NBMA e point-to-multipoint, `default-information originate`, redistribuzione, ECMP, costi e timer configurabili, OSPFv3.

## 5. Interfaccia (testi in italiano)
- **Router, scheda Servizi:**
  - sezione *RIP v2*: interruttore e, per ogni interfaccia, un selettore — / attiva / passiva, con gli errori sotto la sezione (M8a);
  - sezione *OSPF (area 0)*: interruttore, router ID (vuoto = automatico), per ogni interfaccia — / attiva / passiva, tipo di rete broadcast/point-to-point e priorità (M8b).
- **Router e host, scheda Tabelle:**
  - la tabella di routing guadagna la colonna del tipo (C connessa, S statica o da DHCP, R RIP, O OSPF) e quella `[AD/metrica]` (`[1/0]` statica, `[254/0]` da DHCP, `[120/n]` RIP, `[110/n]` OSPF; vuota per le connesse);
  - M8b aggiunge le tabelle *Vicini OSPF* (router ID, priorità, stato, ruolo DR/BDR, indirizzo, interfaccia) e *Database OSPF* (tipo, link ID, router che l'ha generata, età, sequence number).
- **Lista eventi:** filtro protocollo "RIP" (M8a) e "OSPF" (M8b), ciascuno con un colore dedicato; i pacchetti sul canvas usano lo stesso colore.
- **Ispettore PDU:**
  - livello "RIPv2" con comando, versione e una riga per voce (indirizzo/prefisso, maschera, next hop, metrica, tag); la Request mostra "intera tabella";
  - livello "OSPF" con l'header e il corpo del tipo; nelle LSU, una riga per LSA (M8b).
- *Decisione:* il canvas non guadagna indicatori nuovi. Le route si leggono in Tabelle e i pacchetti di routing sono già colorati per protocollo.

## 6. Persistenza ed errori
- Nel `.ptk`, sul nodo router:
  - `rip`: interfacce attive e passive (M8a);
  - `ospf`: router ID manuale, interfacce attive e passive, tipo di rete e priorità per interfaccia (M8b).
  - Le chiavi assenti vogliono dire protocollo spento.
- Le tabelle apprese, gli stati dei vicini e il database non si salvano: a ogni caricamento, e con Annulla/Ripeti, la rete riparte e riconverge, come per ARP, DHCP e STP.
- Un file M7 o precedente si apre con i protocolli spenti.
- *Decisione:* le copie di un router non mantengono RIP né OSPF, come per NAT e firewall: la configurazione dei servizi riguarda gli indirizzi, e le copie non hanno indirizzi.
- Errori tipizzati (messaggi del motore in inglese, mostrati sul campo):
  - protocollo su un dispositivo che non è un router;
  - interfaccia sconosciuta;
  - interfaccia passiva che non partecipa;
  - sottointerfaccia che partecipa e che si vuole eliminare;
  - M8b: router ID non valido, priorità fuori da 0–255.

## 7. Test (aggiunte al §10 della spec principale)
- RIPv2 (M8a):
  - pacchetti: dimensione 4 + 20 × voci, MAC e IP multicast, TTL 1, porte 520, divisione oltre 25 voci;
  - apprendimento all'avvio con Request e risposta unicast, `[120/1]` in µs, triggered update a 1 s, ping;
  - update periodici esattamente ogni 30 s;
  - split horizon;
  - metrica 15 installata e 16 irraggiungibile;
  - timeout a 180 s e cancellazione a 300 s dall'ultimo update;
  - guasto del cavo: metrica 16 subito e failover al prossimo update periodico del vicino alternativo;
  - interfacce passive e non partecipanti;
  - distanza amministrativa (statica e connessa vincono su RIP, RIP vince sul default da DHCP);
  - spegnimento e riaccensione;
  - sottointerfacce su un trunk;
  - firewall che blocca e poi consente UDP 520;
  - errori tipizzati.
- OSPF (M8b): pacchetti e checksum, stati delle adiacenze con i tempi esatti (2-Way, wait 40 s, Full), elezione con priorità e router ID, nessuna preemption, point-to-point senza elezione, LSA 1 e 2, SPF con costi da banda, dead interval, guasto del cavo.
- `.ptk`: round-trip della configurazione, apertura di un file M7, copie senza protocolli.
- Selftest:
  - M8a: immagini della sezione RIP nella scheda Servizi e della tabella di routing con le route R, più la PDU RIPv2;
  - M8b: immagini della sezione OSPF, dei vicini e del database.
