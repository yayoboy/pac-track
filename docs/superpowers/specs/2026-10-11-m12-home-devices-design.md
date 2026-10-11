# pac-track v3 — M12: dispositivi di casa

> Estende la spec principale `2026-10-07-pac-track-rewrite-design.md` (rev. 2) e le spec M7–M11; valgono le loro regole su motore, determinismo, UI, persistenza ed errori. L'utente ha chiesto "aggiungi modem, NAS, console e IoT": i dispositivi di una rete di casa. Il router Wi-Fi domestico e WPA2-PSK sono di M11b, sviluppata in parallelo; questa milestone non li tocca. Le decisioni sono prese in autonomia; ognuna è marcata *Decisione* con il motivo. La regola guida è quella di M10: riusare lo stack degli host, la scheda wireless di M11a e i servizi che esistono già; nel motore entra solo il modem, un bridge a due porte con la velocità della sua linea.

## 1. Obiettivo
Sei voci nuove nella palette, ognuna con la sua icona, un nome italiano e default sensati, che funzionano appena trascinate: un modem DSL, un NAS, una console di gioco e tre dispositivi IoT (lampadina, termostato e smart speaker).

**Successo M12:** una *Cloud/ISP* (ISP1) cablata a un *Modem DSL* (MODEM1), MODEM1 a un router (R1), R1 a uno switch (SW1); su SW1 un *NAS* (NAS1), una *Console* (CONSOLE1) e un *Access point* (AP1); vicino ad AP1 una *Lampadina smart* (LAMP1), un *Termostato* (THERM1) e uno *Smart speaker* (SPK1). R1 si configura come nel quinto dei Primi passi del README (Gi0/0 `203.0.113.2/24`, route `0.0.0.0/0` via `203.0.113.1`, NAT) più Gi0/1 `192.168.1.1/24` con il server DHCP (pool .100–.199, gateway .1, DNS 8.8.8.8). Nessuna configurazione sui dispositivi nuovi.
- MODEM1 si attacca con `dsl0` a ISP1 e con `eth0` a R1, in qualunque ordine si tirino i cavi. Il cavo fra ISP1 e MODEM1 mostra `100/20 Mb/s`.
- A 60 s NAS1, CONSOLE1, LAMP1, THERM1 e SPK1 hanno un indirizzo da R1 (le porte di SW1 in forwarding a 30 s, i DISCOVER a 4, 12, 28 e 60 s; i dispositivi IoT chiedono all'associazione, M11 §5).
- Il generatore TCP di CONSOLE1 verso l'indirizzo di NAS1 finisce con `iperf Done.`. Un ping da CONSOLE1 a `www.example.com` risponde attraverso il modem e il NAT di R1.
- Il file si salva e si riapre uguale; un file di M11a si apre come prima.

## 2. Modem DSL
- **Modem DSL** (`modem`, nomi `MODEM1`…, sezione Casa): due porte, `dsl0` (la linea verso il provider) e `eth0` (verso il router di casa). Nessun indirizzo IP, nessun servizio. Scheda: Porte.
  - *Decisione:* DSL e non via cavo. In Italia la linea di casa più diffusa è FTTC (VDSL2 dall'armadio in strada); il modem via cavo (DOCSIS) qui quasi non esiste. I nomi `dsl0`/`eth0` sono quelli di un modem con Linux (OpenWrt).
  - *Decisione:* **modalità bridge**. Il modem porta i frame da una porta all'altra così come sono (VLAN, BPDU e broadcast compresi), come un ripetitore a due porte; l'indirizzo pubblico, il NAT e il DHCP restano al router dietro. È il modem "puro" che si mette davanti al proprio router; un modem-router sarebbe un router Wi-Fi domestico (M11b).
  - *Decisione:* niente PPPoE né ATM/PTM. La Cloud/ISP dà già l'indirizzo sulla rete del cliente (`203.0.113.0/24`); una sessione PPPoE sarebbe un protocollo nuovo che nessun laboratorio chiede.
- **Velocità della linea:** `dsl0` si allinea a **VDSL2 100/20 Mb/s**: i frame che `dsl0` trasmette (upstream) partono a 20 Mb/s, quelli che riceve (downstream) arrivano a 100 Mb/s, qualunque sia il cavo. Se il cavo è più lento vale il cavo.
  - *Decisione:* la velocità appartiene alla porta del modem e non al cavo, come la velocità di sincronizzazione che il modem negozia con l'armadio; così l'asimmetria (upload più lento) si vede senza un cavo a due velocità. Profilo 17a, l'offerta FTTC "fino a 100 Mega" più comune; fisso, senza scelta del profilo.
  - *Decisione:* il ritardo è quello del cavo; niente interleaving. È il "fast path" di una linea VDSL2 e non cambia la lezione (il collo di bottiglia è in upload).
  - Il collo di bottiglia si vede dove è davvero: la coda di `dsl0` del modem in upload, quella della porta della Cloud in download. Le Metriche dei cavi lo mostrano già (l'utilizzo è tempo occupato).
- **Cavi:** collegando un modem, l'editor sceglie `dsl0` se dall'altra parte c'è una Cloud/ISP, altrimenti `eth0`; se quella porta è occupata usa l'altra. *Decisione:* il primo libero metterebbe il router su `dsl0` quando lo si cabla per primo, e la velocità della linea finirebbe dal lato di casa.
- **Canvas:** l'etichetta di un cavo su `dsl0` mostra la linea, `100/20 Mb/s` (giù/su), al posto della velocità del cavo; la scheda Porte del modem scrive sotto `dsl0` "VDSL2 · 100/20 Mb/s".

## 3. NAS
- **NAS** (`nas`, nomi `NAS1`…, sezione Casa): un host con eth0, come un server, che arriva con il **sink** acceso e eth0 **in DHCP**. Schede come la stampante: Interfacce, Routing, Servizi (solo il sink), Tabelle, App.
  - *Decisione:* la condivisione di file è il sink del generatore: una copia o un backup verso il NAS è traffico TCP che arriva e resta lì. Nessun protocollo nuovo (SMB, NFS, AFP restano fuori).
  - *Decisione:* DHCP all'arrivo, come un NAS appena tolto dalla scatola (lo si trova poi fra i lease del router); la stampante resta statica (M10 §2).
  - *Decisione:* niente server DHCP o DNS sul NAS, anche se alcuni NAS li offrono: per quelli c'è il server.

## 4. Console
- **Console** (`console`, nomi `CONSOLE1`…, sezione Casa): un host con eth0 in DHCP all'arrivo, con la scheda Wi-Fi opzionale di PC e laptop (M11 §2): nella scheda Wi-Fi *Scheda di rete: Ethernet / Wi-Fi*. Schede come un PC.
  - *Decisione:* arriva in Ethernet, come la si collega per giocare in rete; il passaggio al Wi-Fi è quello di un laptop.

## 5. Dispositivi IoT
- **Lampadina smart** (`smartBulb`, `LAMP1`…), **Termostato** (`thermostat`, `THERM1`…), **Smart speaker** (`smartSpeaker`, `SPK1`…), sezione Casa: host con la sola `wlan0`, come tablet e smartphone; arrivano con la rete `pac-track` e `wlan0` in DHCP. Schede come il tablet.
  - *Decisione:* solo wireless, come i dispositivi reali; un cavo da una lampadina dà l'errore già esistente "LAMP1 has no free port".
  - *Decisione:* nessun comportamento proprio (niente MQTT, Matter, comandi o letture): per il motore sono host Wi-Fi. La lezione è che anche loro sono host della rete, con un indirizzo dal DHCP, che si possono pingare e vedere fra i lease.
  - La scheda App resta: è lo strumento del simulatore, non del dispositivo (come per la stampante, M10 §2).

## 6. Palette e menu
- Nuova sezione **Casa** fra Wireless e Cavi: Modem DSL, NAS, Console, Lampadina smart, Termostato, Smart speaker.
  - *Decisione:* una sezione sola per i dispositivi di casa invece di spargerli fra Rete, Server e Wireless: chi costruisce la rete di casa li trova insieme, e le sezioni esistenti restano come le conosce.
- La ricerca trova `casa`, `iot` e `home` (tutta la sezione), `dsl`, `smart` (Smart TV, Lampadina smart, Smart speaker) e i nomi.
- La palette ora ha 23 voci: nella finestra del selftest (860 pt) e alla minima (640 pt) l'elenco scorre; nessuna voce va a capo o si tronca nei 170 pt.
- Il menu *Aggiungi dispositivo* elenca le stesse voci nello stesso ordine.

## 7. Persistenza e copie
- I nuovi tipi si salvano con il loro nome (`modem`, `nas`, `console`, `smartBulb`, `thermostat`, `smartSpeaker`); `Topology.version` resta 1, nessuna chiave nuova. I file di M1–M11a si aprono come prima.
- Copia, incolla e duplica tengono il sink del NAS, la modalità DHCP, la rete e la scheda Wi-Fi (M10 §6, M11 §10), senza regole nuove.
- Annulla, export PNG e selftest trattano i nuovi tipi come gli altri.

## 8. Esclusi
- *Decisione:* modem via cavo e ONT in fibra (stesso modello con un'altra velocità, nessun laboratorio li distingue), modem-router (è M11b), PPPoE, protocolli di condivisione file, protocolli IoT, hub IoT/Zigbee, console in rete con altri giocatori (nessun protocollo di gioco).

## 9. Test (aggiunte al §10 della spec principale)
- **Motore:** il modem ripete i frame fra le due porte (ping attraverso il modem); `dsl0` trasmette a 20 Mb/s e riceve a 100 Mb/s, il cavo più lento vince; NAS con il sink, console con la scheda Wi-Fi, IoT solo Wi-Fi; sink rifiutato su console e IoT.
- **Editor:** default di ogni tipo in un passo di annulla; la porta del modem scelta verso la Cloud e verso il router, in entrambi gli ordini; l'etichetta della linea; round-trip; il laboratorio del §1.
- **Selftest M12:** la ricerca della palette, il laboratorio del §1 e le immagini della palette (anche nella finestra minima), del modem, del NAS e di un dispositivo IoT.
