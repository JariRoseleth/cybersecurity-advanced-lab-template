# OpenVPN configuration

This directory contains the persistent non-secret configuration for Lab 9.

- `server.conf`: OpenVPN server configuration for `companyrouter`.
- `client.conf`: OpenVPN client configuration for `remote-employee`.
- `csa-openvpn-firewall-apply`: idempotent nftables integration for the
  existing `inet csa_firewall` ruleset.

The EasyRSA PKI and all private key material are generated and stored on
the virtual machines. Private keys are intentionally not committed.

The temporary development installers used while building the lab are not
part of the final configuration because the submitted state is validated
through the live configuration, systemd services and evidence files.
