# Lab 9 - OpenVPN

## Doel

Lab 9 bouwt een beveiligde remote-access VPN tussen `remote-employee`
en het interne bedrijfsnetwerk.

De VPN-server draait op `companyrouter`.

## Topologie

- `companyrouter`
  - extern: `192.168.62.253`
  - intern: `172.30.255.254/16`
  - OpenVPN: `10.9.0.1/24`

- `remote-employee`
  - thuisnetwerk: `172.10.10.123/24`
  - OpenVPN: `10.9.0.2/24`

- beschermd bedrijfsnetwerk:
  - `172.30.0.0/16`

De server pusht de route naar `172.30.0.0/16` naar de VPN-client.

## PKI

EasyRSA wordt gebruikt voor een aparte Lab-9-PKI.

Uitgegeven certificaten:

- CA: `CSA-Lab9-CA`
- server: `companyrouter`
- client: `remote-employee`

Het servercertificaat bevat TLS Web Server Authentication.
Het clientcertificaat bevat TLS Web Client Authentication.

Private sleutels worden uitsluitend op de VM's bewaard en worden niet
in deze repository opgeslagen.

## OpenVPN-beveiliging

De configuratie gebruikt:

- UDP/1194
- TLS-certificaatauthenticatie
- `tls-crypt`
- TLS minimaal 1.2
- AES-256-GCM / AES-128-GCM data-ciphers
- geen VPN-compressie
- certificaatrolcontrole via `remote-cert-tls`
- servernaamcontrole voor `companyrouter`

Tijdens de validatie werd AES-256-GCM onderhandeld.

## Firewall

De bestaande `inet csa_firewall` nftables-firewall blijft behouden.

Lab 9 voegt gericht regels toe voor:

- UDP/1194 van `remote-employee`
- ICMP van het VPN-subnet naar de VPN-gateway
- forwarding van `10.9.0.0/24` naar `172.30.0.0/16`
- established/related retourverkeer

`csa-openvpn-firewall.service` zorgt ervoor dat deze regels persistent
opnieuw toegepast kunnen worden.

## Validatie

`remote-employee` krijgt `10.9.0.2/24`.

De route naar het bedrijfsnetwerk wordt:

    172.30.0.0/16 via 10.9.0.1 dev tun0

Als stabiele interne validatiehost werd `172.30.0.4` gebruikt.

Deze host is vanuit `remote-employee` via `tun0` bereikbaar.

## Packet capture

Twee simultane captures tonen het verschil tussen het buitenste en
binnenste verkeer.

Op `companyrouter:eth1` is het transport zichtbaar als OpenVPN
UDP/1194 tussen `remote-employee` en `companyrouter`.

Op `companyrouter:tun0` is na decryptie het oorspronkelijke verkeer
zichtbaar tussen:

    10.9.0.2 <-> 172.30.0.4

De interne VPN-adressen en het interne doeladres zijn niet in plaintext
zichtbaar op `eth1`.

## Persistence

Na een restart van de OpenVPN-server en OpenVPN-client:

- zijn beide services opnieuw actief;
- bestaat `tun0` opnieuw;
- krijgt de client opnieuw `10.9.0.2/24`;
- wordt de route naar `172.30.0.0/16` opnieuw geïnstalleerd;
- is `172.30.0.4` opnieuw bereikbaar;
- wordt opnieuw een AES-256-GCM data-channel opgebouwd.

## Evidence

- `01-pki-validation.txt`
- `02-server-validation.txt`
- `03-client-validation.txt`
- `04-capture-traffic.txt`
- `05-capture-summary.txt`
- `05-outer-encrypted-openvpn.pcap`
- `05-inner-decrypted-tun0.pcap`
- `06-persistence-client.txt`
- `06-persistence-server.txt`