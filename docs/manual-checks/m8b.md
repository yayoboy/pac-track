# M8b — manual checks (OSPFv2, area 0)

Build and open: `scripts/bundle.sh && open build/PacTrack.app`.

**Due router, rete broadcast**
- [ ] R1 e R2 collegati (Gi0/1–Gi0/1, 10.0.12.1/30 e 10.0.12.2/30), PC1 su R1 Gi0/0 (192.168.1.0/24), PC2 su R2 Gi0/0 (192.168.2.0/24), gateway sui PC. R1 ▸ Servizi: *OSPF (area 0)* spento. Accendilo: Gi0/0 e Gi0/1 *attiva* (broadcast, priorità 1), Gi0/2 e Gi0/3 *—*; rendi passiva Gi0/0. Stesso su R2.
- [ ] Eventi, filtro OSPF: `Down → Waiting` su Gi0/1, `vicino 192.168.2.1: Down → Init` subito, `Init → 2-Way` a 10 s. A 40 s `Waiting → …`: R2 diventa DR e R1 BDR; poi `ExStart → Exchange → Loading → Full`.
- [ ] Tabelle di R1: *Vicini OSPF · router ID 192.168.1.1* con `192.168.2.1 1 Full/DR 10.0.12.2 Gi0/1`; *Database OSPF* con due LSA di tipo 1 (192.168.1.1 e 192.168.2.1) e una di tipo 2 (`10.0.12.2`, di 192.168.2.1), ogni riga su una sola linea. Dopo 45 s la tabella di routing mostra `O 192.168.2.0/24 [110/2] 10.0.12.2 Gi0/1`; un ping da PC1 a PC2 risponde con ttl=62.
- [ ] PDU di un Hello: *IPv4* protocollo 89 (OSPF), TTL 1, destinazione 224.0.0.5; *OSPF* con Versione 2, Tipo 1 (Hello), Router ID, Area 0.0.0.0, Checksum, Maschera, Hello interval 10 s, Priorità, Dead interval 40 s, DR, BDR e i vicini. Una LS Update mostra ogni LSA con seq, età, checksum e i link.
- [ ] Il colore OSPF è suo; i nove chip dei filtri stanno su una riga accanto al selettore dei nodi, e la barra scorre in orizzontale se la finestra è più stretta.

**Point-to-point, priorità, router ID**
- [ ] Imposta *point-to-point* su Gi0/1 di entrambi: l'adiacenza riparte, va in Full a 10 s senza elezione; il vicino è `Full/-`.
- [ ] Tre router su un hub (10.0.0.0/24): priorità 0 su R1 → mai DR né BDR. Aggiungi più tardi R3 con priorità 255: il DR resta quello di prima, R3 prende solo il posto libero di BDR.
- [ ] Router ID 1.1.1.1 su R1 mentre OSPF gira: la tabella dei vicini di R2 mostra ancora quello vecchio; spegni e riaccendi OSPF su R1 (o il router) e compare 1.1.1.1. Un router ID "1.2.3" o una priorità 300 danno l'errore sotto il campo.

**Triangolo e guasti**
- [ ] R3 collegato a R1 (Gi0/2, 10.0.13.0/30) e a R2 (Gi0/2, 10.0.23.0/30), OSPF ovunque. *Simula guasto* su R1–R2: l'adiacenza cade subito (`→ Down`), R1 riemette la router-LSA, la network-LSA di 10.0.12.2 sparisce dal database e 5 s dopo R1 passa per R3 con `[110/3]`; il ping riprende con ttl=61.
- [ ] Porta il cavo R1–R2 (ripristinato) a 10 Mb/s: costo 10; dopo 5 s R1 passa per R3 senza che l'adiacenza cada.
- [ ] Tre router su un hub: spegni R2. R1 lo perde dopo 40 s (dead interval). Riaccendilo: dopo il nuovo wait timer le sue LSA hanno un numero di sequenza più alto di prima.
- [ ] RIP e OSPF accesi insieme su R1 e R2: la tabella mostra `O … [110/2]`, non la `R`.

**File e copie**
- [ ] Salva, chiudi e riapri: OSPF, router ID, ruoli, tipo di rete e priorità tornano; la rete riconverge da capo (40 s + 5 s). Un progetto M8a si apre con OSPF spento. Duplica un router con OSPF: la copia ha OSPF spento. Cmd+Z annulla una modifica OSPF in un passo.
- [ ] Eliminare una sottointerfaccia che partecipa a OSPF dà l'errore "… takes part in OSPF".
