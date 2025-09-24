# STZ script
---

This is the universal Bash script for full-cycle via "tar to ssh" with zstd:
- backup (remote local .tar.zst)
- list (view the contents of the archive as a tree)
- test-restore (local sample decompression)
- restore (local remote with metadata recovery)
The script shows progress (pv), validates the environment, prints understandable errors and has a help.

# How to use
---

1. Backup from remote server to local archive:

```bash
./stz.sh backup -H myuser@server -f nginx.tar.zst etc/nginx
```

2. View archive contents by tree:

```bash
./stz.sh list -f nginx.tar.zst
```

3. Test unpacking locally:

```bash
./stz.sh test-restore -f nginx.tar.zst -o . /restore-test
```

4. Restore to remote server (root):

```bash
./stz.sh restore -f nginx.tar.zst -H myuser@server
```

5. Restore to alternative prefix on remote:

```bash
./stz.sh restore -f nginx.tar.zst -H myuser@server --prefix /tmp/restore-root
```

### Notes

- The script preserves metadata: owners/permissions (`-p -numeric-owner`), ACL (`--acls`), xattrs (`--xattrs`). You can disable through `--no-acls`, `-no-xattrs`.
- For correct restoration of rights/owners root is needed (locally with `test-restore`; remotely with `restore` - through `sudo`).
- Progress: `pv` is used (if available). Disable: `-no-pv`.
- Exceptions set `--exclude` PATTERN (can be done multiple times).
- If `sudo -n` on the remote side requires a password, correct sudoers or change `--sudo-remote`.

