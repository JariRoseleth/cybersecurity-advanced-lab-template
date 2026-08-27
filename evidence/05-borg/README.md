# Lab 5 - BorgBackup

## Architecture

- Backup client: web
- Active data: `/home/vagrant/important-files`
- Backup server: database
- Remote repository: `/home/vagrant/backups`
- Transport: SSH
- Repository encryption: repokey
- Compression: LZ4
- Automation: systemd timer every five minutes

## Security properties

Borg encrypts and authenticates data on the client before storing it on the remote backup server. SSH additionally protects the transport connection.

The repository server cannot read the plaintext data without the repository key and passphrase.

The repository key export was stored outside this Git repository. For automation, the passphrase is stored on web in /home/vagrant/.config/borg/passphrase with mode 0600. A separate recovery copy should be kept in a password manager.

## Archives

- `first`: original four files
- `second`: original files plus `test.txt`
- `auto-*`: automated archives created by systemd

## Restore test

The active data directory was deleted completely. Archive `first` was extracted to the original location. All four original files were restored and `test.txt` was correctly absent.

## Retention

Automated archives use:

- last 12 archives
- 24 hourly archives
- 7 daily archives
- 4 weekly archives
- 6 monthly archives

After pruning, `borg compact` releases repository space that is no longer referenced.

## Validation

See `05-borg-validation.txt`.

## Rollback

Disable automation:

    sudo systemctl disable --now csa-borg-backup.timer

Remove the service files:

    sudo rm /etc/systemd/system/csa-borg-backup.service
    sudo rm /etc/systemd/system/csa-borg-backup.timer
    sudo systemctl daemon-reload

The repository on database can be removed separately after confirming it is no longer needed.
## Command and theory notes

### Curl options

- `--location` follows HTTP redirects.
- `--remote-name-all` uses the remote filename for every supplied URL.

### Deduplication and chunks

Borg splits files into content-defined chunks. Identical chunks are stored only once and are referenced by multiple archives.

Archive `first` stored approximately 110.78 MB of unique data. Archive `second` contained the same large files plus `test.txt`, but required only approximately 619 B of additional deduplicated storage.

### Integrity checking

The repository was checked using:

    borg check --verbose --verify-data "$BORG_REPO"

A normal check validates repository and archive structures. `--verify-data` additionally reads and cryptographically verifies the stored data chunks.

### Active databases

Directly copying live database files can produce an inconsistent backup because the files may change during the backup.

A safer approach is to create a consistent SQL dump, use a database-native backup tool, or create a filesystem snapshot after temporarily quiescing the database. The resulting dump or snapshot can then be stored with Borg.

### Borgmatic

Borgmatic is an automation and configuration layer around Borg. It can define repositories, source directories, retention rules, integrity checks and pre/post-backup hooks in a configuration file.

### Recovery requirements

Recovery requires both:

- the exported repository key;
- the Borg passphrase.

The exported key is stored outside Git. The automated passphrase file on `web` is protected with mode `0600`; an additional recovery copy should be stored in a password manager.
