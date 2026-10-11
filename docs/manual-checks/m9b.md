# M9b — manual checks (servizi su IPv6: DNS AAAA, RDNSS, TCP e UDP, firewall)

Build and open: `scripts/bundle.sh && open build/PacTrack.app`.

**Il laboratorio della spec**
- [ ] R1 con PC1 su Gi0/0 e SRV1 (server) su Gi0/1, cavi diretti. R1: Gi0/0 `10.0.1.1/24` e IPv6 `2001:db8:1::1/64`, Gi0/1 `10.0.2.1/24` e `2001:db8:2::1/64`, *Routing IPv6* acceso. PC1: `10.0.1.10/24`, gateway `10.0.1.1`, IPv6 con SLAAC. SRV1: `10.0.2.53/24`, gateway `10.0.2.1`, IPv6 `2001:db8:2::53/64`.
- [ ] R1 ▸ Routing: sotto l'interruttore *Routing IPv6* compare *Server DNS annunciato (RDNSS)*; scrivi `2001:db8:2::53`. Spegnendo *Routing IPv6* il campo sparisce; riaccendendolo torna con il valore.
- [ ] SRV1 ▸ Servizi: accendi *Server DNS* e aggiungi `srv1.lab` con `2001:db8:2::53` e con `10.0.2.53`. Sotto *RECORD A E AAAA* le righe sono `srv1.lab  AAAA  2001:db8:2::53  TTL 3600s` e `srv1.lab  A  10.0.2.53  TTL 3600s`, ciascuna su una riga. Un doppione dà `Record srv1.lab AAAA 2001:db8:2::53 already exists`. Accendi il *Sink TCP/UDP*.
- [ ] Al più tardi alla RA successiva (o spegnendo e riaccendendo IPv6 su PC1, che manda una RS): PC1 ▸ Interfacce, il campo *Server DNS* vuoto mostra `2001:db8:2::53 (da RA)`. Un server scritto a mano (`10.0.2.53`) ha la precedenza.
- [ ] PDU di una RA di R1: oltre a SLLA, MTU e prefisso, `Opzione 25 RDNSS 2001:db8:2::53, lifetime 600 s`; la RA è di 142 B.

**Nomi, AAAA e scelta dell'indirizzo**
- [ ] App di PC1: ping `srv1.lab` → `PING srv1.lab(2001:db8:2::53) 56 data bytes`, 4 risposte `ttl=63`. Negli eventi (filtro DNS) PC1 manda `DNS Query … A srv1.lab` e subito dopo `DNS Query … AAAA srv1.lab` verso `2001:db8:2::53`; la risposta `DNS Risposta … AAAA srv1.lab → 2001:db8:2::53`. Nell'ispettore: Ethernet II, IPv6 (Next header 17), UDP, DNS con `Domanda: srv1.lab tipo AAAA, classe IN`.
- [ ] Tabelle di PC1, *Cache DNS*: `srv1.lab 10.0.2.53` e `srv1.lab 2001:db8:2::53`, ciascuna con il suo TTL.
- [ ] nslookup `srv1.lab` su PC1 → `Server: 2001:db8:2::53`, poi `Name/Address` per `10.0.2.53` e per `2001:db8:2::53`. Un nome con il solo A mostra solo l'A (l'AAAA riceve una risposta senza record); un nome sconosciuto `** server can't find …: NXDOMAIN`.
- [ ] Spegni IPv6 su PC1 e scrivi a mano il server `10.0.2.53`: il ping a `srv1.lab` usa `10.0.2.53` (`PING srv1.lab (10.0.2.53) 56(84) bytes of data.`) e negli eventi c'è la sola query A; nslookup chiede solo l'A.
- [ ] Il router smette di annunciare (campo RDNSS vuoto): PC1 tiene il server per 600 s dall'ultima RA che lo portava, poi il campo *Server DNS* torna vuoto.

**TCP e UDP su IPv6**
- [ ] App di PC1, generatore TCP verso `srv1.lab` (o `2001:db8:2::53`), 1000000 byte → `Connecting to host 2001:db8:2::53, port 9`, `[  1] local 2001:db8:1::… port … connected to 2001:db8:2::53 port 9`, `iperf Done.`. Negli eventi le SYN hanno `mss=1440`, i segmenti al massimo `len=1440`; nessun drop `mtu-exceeded`.
- [ ] Tabelle di PC1 (e di SRV1) durante e dopo il trasferimento, *Connessioni TCP*: `[2001:db8:1::…]:porta` sopra `[2001:db8:2::53]:9`, stato `ESTABLISHED` poi `TIME_WAIT`, nessuna riga va a capo. Le righe IPv4 hanno la stessa forma su due righe; SRV1 mostra `0.0.0.0:9` in `LISTEN`.
- [ ] Generatore UDP verso `2001:db8:2::53`, 1 Mb/s per 1 s → `… 0/87 (0%)` e `iperf Done.`; i datagrammi sono frame da 1512 B (1450 B di dati).
- [ ] Spegni il sink su SRV1: il TCP fallisce con `Connection refused` (RST), un datagramma UDP riceve `Destination unreachable (port)` in ICMPv6.
- [ ] Generatore verso `fe80::1` → l'errore `Traffic to link-local or multicast addresses is not supported` sotto la scheda App.

**Firewall IPv6**
- [ ] R1 ▸ Servizi: accendi il *Firewall* (policy consenti) e aggiungi `in Gi0/0 · nega any 2001:db8:1::/64 → any`. La regola si legge intera (su due righe se serve). Il ping IPv6 di PC1 a SRV1 non risponde (drop `[firewall-rule]` ICMPv6 su R1 Gi0/0), quello IPv4 a `10.0.2.53` sì.
- [ ] Una regola `nega icmp any any` blocca anche il ping IPv6 ma non il TCP. Una regola con sorgente IPv4 e destinazione IPv6 dà `A rule cannot mix IPv4 and IPv6 addresses`; il testo sotto il modulo dice "IPv4 o IPv6".
- [ ] Policy *nega* con le sole regole `in Gi0/0 consenti icmp/tcp/udp`: ping, TCP e UDP da PC1 a SRV1 funzionano (le risposte passano come flussi tracciati, il Port Unreachable di una porta chiusa arriva); SRV1 non riesce a pingare PC1. Negli eventi le RS dei PC sono scartate (`firewall-default`), le NS e NA no. Il ping di R1 stesso verso PC1 risponde.
- [ ] Nota: con M9b la policy vale anche per IPv6. Il controllo M9a "con NAT e firewall (policy nega) il ping IPv6 passa" ora richiede una regola IPv6 (per esempio `in Gi0/0 consenti any 2001:db8:1::/64 → any`); il NAT continua a non toccare IPv6.

**Route statiche (M9a)**
- [ ] R1 ▸ Routing: sotto il modulo delle route statiche c'è `IPv4 o IPv6, es. 2001:db8:9::/64 via 2001:db8:1::2`. Una route `2001:db8:9::/64` via `2001:db8:2::99` compare su una riga.
- [ ] Ping o traceroute a `fe80::1%eth0` → `Ping to link-local or multicast addresses is not supported`; a `2001:db8::1%eth0` → `Invalid IPv6 address`.

**File e copie**
- [ ] Salva, chiudi e riapri: il server RDNSS di R1, i record AAAA e le regole firewall IPv6 tornano. Un progetto M9a si apre senza server RDNSS.
- [ ] Duplica R1: la copia non ha il server RDNSS (come *Routing IPv6*). Cmd+Z annulla il cambio del server in un passo.
