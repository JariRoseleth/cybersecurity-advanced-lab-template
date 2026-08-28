# Regulatory Compliance

Regulatory compliance betekent dat een organisatie aantoonbaar voldoet aan relevante wetgeving, normen en beveiligingsvereisten. Wazuh ondersteunt dit door security-events centraal te verzamelen, analyseren, correleren en bewaren als technisch auditbewijs.

## PCI-DSS

PCI-DSS richt zich op organisaties die betaalkaartgegevens verwerken, opslaan of verzenden. Logging, monitoring, toegangscontrole en detectie van ongeautoriseerde wijzigingen zijn belangrijke onderdelen. Wazuh ondersteunt zulke controles met onder meer centrale loganalyse, File Integrity Monitoring en endpointdetectie.

## NIST SP 800-53

NIST SP 800-53 bevat een uitgebreide catalogus van security- en privacycontrols. Voor deze lab zijn vooral Audit and Accountability, Configuration Management, System and Information Integrity en Incident Response relevant.

## Mapping naar Lab 7

- Linux FIM detecteert het aanmaken, wijzigen en verwijderen van bestanden.
- Linux Auditd registreert uitgevoerde CLI-processen.
- Sysmon Event ID 1 registreert Windows process creation inclusief command line.
- PowerShell Event ID 4104 registreert uitgevoerde Script Blocks.
- Wazuh centraliseert deze events voor analyse, detectie en threat hunting.

Wazuh maakt een organisatie niet automatisch compliant. Het platform helpt wel technische controls en auditbewijs aantoonbaar te maken.
