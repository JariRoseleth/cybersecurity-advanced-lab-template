# Lab 6 - CA en HTTPS

## Uitgevoerde onderdelen

- Eigen root-CA op `isprouter` (`192.168.62.254`).
- RSA-serverkey en CSR op `web` (`172.30.0.10`).
- SANs: `cybersec.internal`, `www.cybersec.internal`, `services.cybersec.internal` en `172.30.0.10`.
- Apache HTTPS met behoud van `/cmd`, `/assets`, `/exec` en `/services`.
- Extra virtual host `https://services.cybersec.internal/`.
- TLS 1.2-demonstratie met statische RSA-key-exchange (`AES256-SHA`).
- Veilige eindtoestand: uitsluitend TLS 1.3 met `TLS_AES_256_GCM_SHA384`.

## Wireshark - TLS 1.2

Open `10-tls12-rsa.pcap` en configureer onder **Preferences > Protocols > TLS > RSA keys list**:

- IP: `172.30.0.10`
- Port: `443`
- Protocol: `http`
- Key file: `C:\Users\jarir\CSA-Lab6-Private\webserver.key`

Na herladen toont de filter `http` de ontsleutelde HTTP-inhoud. Dit werkt omdat de demo statische RSA-key-exchange gebruikt en geen Perfect Forward Secrecy heeft.

## Wireshark - TLS 1.3

De server-private-key alleen ontsleutelt `20-tls13-pfs.pcap` niet. Configureer in **Preferences > Protocols > TLS** bij **(Pre)-Master-Secret log filename**:

`C:\Users\jarir\CSA-Lab6-Private\tls13-sslkeys.log`

Daarna kan Wireshark de TLS 1.3-sessie ontsleutelen. Het keylogbestand vereist toegang tot het client-endpoint en hoort nooit in Git.

## Veiligheidsgrens

De CA-private-key blijft uitsluitend op `isprouter` in `/etc/csa-ca/private/ca.key`. Alleen de publiek deelbare CA- en servercertificaten staan in deze evidence-map. De tijdelijk geëxporteerde webserver-private-key en TLS-keylog staan buiten de repository in `C:\Users\jarir\CSA-Lab6-Private`.
