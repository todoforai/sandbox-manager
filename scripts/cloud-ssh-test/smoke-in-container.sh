#!/bin/bash
# Runs inside the throwaway container built by scripts/test-cloud-ssh.sh.
# Fake backend + real sshd login/SFTP/rsync against oci/cloud-ssh.
set -u
fail() { echo "FAIL: $*"; exit 1; }
mkdir -p /root/.config/todoforai
ssh-keygen -q -t ed25519 -N '' -f /tmp/pc; ssh-keygen -q -t ed25519 -N '' -f /tmp/other
ssh-keygen -q -t rsa -b 2048 -N '' -f /tmp/rsa
echo '{"sets":{"dev":{"deviceId":"dev-1","deviceSecret":"s3cret"}}}' > /root/.config/todoforai/credentials.json
ALLOWED=$(cut -d' ' -f1,2 /tmp/pc.pub) python3 - <<'PY' &
import http.server, json, os
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        b = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        open('/tmp/reqs', 'a').write(json.dumps(b) + '\n')
        ok = self.path == '/api/cloud-ssh/authorized-key' and b == {"deviceId": "dev-1", "secret": "s3cret", "key": os.environ['ALLOWED']}
        out = (os.environ['ALLOWED'] + '\n').encode() if ok else b''
        self.send_response(200); self.end_headers(); self.wfile.write(out)
    def log_message(self, *a): pass
http.server.HTTPServer(('127.0.0.1', 8080), H).serve_forever()
PY
sleep 0.5
URL=http://127.0.0.1:8080/api/cloud-ssh/authorized-key
k1=$(cloud-ssh-setup $URL | tail -1) || fail "setup 1"
k2=$(cloud-ssh-setup $URL | tail -1) || fail "setup 2 (idempotent)"
[ "$k1" = "$k2" ] && echo "$k1" | grep -Eq '^ssh-ed25519 [A-Za-z0-9+/]{68}$' || fail "host key $k1 / $k2"
[ "$(stat -c %a:%U /root/.todoforai/ssh-host)" = 700:root ] || fail "host key dir perms"
[ "$(stat -c %a:%U /root/.todoforai/ssh-host/ssh_host_ed25519_key)" = 600:root ] || fail "host key perms"
ls /etc/ssh/ssh_host_* 2>/dev/null && fail "image host keys present"
echo "127.0.0.1 $k1" > /tmp/kh
S="ssh -F /dev/null -o BatchMode=yes -o UserKnownHostsFile=/tmp/kh -o StrictHostKeyChecking=yes -o IdentitiesOnly=yes"
[ "$($S -i /tmp/pc workspace@127.0.0.1 'id -un; pwd; echo $HOME')" = "$(printf 'workspace\n/workspace\n/workspace')" ] || fail "login as workspace"
$S -i /tmp/other workspace@127.0.0.1 true 2>/dev/null && fail "unknown key accepted"
$S -i /tmp/rsa workspace@127.0.0.1 true 2>/dev/null && fail "rsa accepted"
$S -i /tmp/pc root@127.0.0.1 true 2>/dev/null && fail "root accepted"
$S -i /tmp/pc workspace@127.0.0.1 'sudo -n true' 2>/dev/null && fail "sudo works"
chmod 755 /root; chmod 600 /root/.config/todoforai/credentials.json  # as on home.img
$S -i /tmp/pc workspace@127.0.0.1 'cat /root/.config/todoforai/credentials.json' 2>/dev/null && fail "creds readable"
$S -i /tmp/pc workspace@127.0.0.1 'cat /root/.todoforai/ssh-host/ssh_host_ed25519_key' 2>/dev/null && fail "host key readable"
$S -i /tmp/pc -R 9999:127.0.0.1:8080 -o ExitOnForwardFailure=yes workspace@127.0.0.1 true 2>/dev/null && fail "remote forward allowed"
$S -i /tmp/pc -W 127.0.0.1:8080 workspace@127.0.0.1 </dev/null 2>/dev/null | grep -q . && fail "stdio forward allowed"
echo hello > /tmp/f
printf 'put /tmp/f up.txt\n' | sftp -F /dev/null -b - -o BatchMode=yes -o UserKnownHostsFile=/tmp/kh -o IdentitiesOnly=yes -i /tmp/pc workspace@127.0.0.1 >/dev/null || fail sftp
mkdir -p /tmp/src && echo r > /tmp/src/a
rsync -a -e "$S -i /tmp/pc" /tmp/src/ workspace@127.0.0.1:dir/ || fail rsync
[ "$(cat /root/.todoforai/ssh-workspace/up.txt /root/.todoforai/ssh-workspace/dir/a)" = "$(printf 'hello\nr')" ] || fail "persisted under ssh-workspace"
grep -q '"s3cret"' /tmp/reqs || fail "helper did not send dev-profile creds"
ps -eo args | grep -q '[s]3cret' && fail "secret in argv"
# restart sshd: kill and setup again (readiness recovery)
kill "$(cat /run/cloud-sshd.pid)"; sleep 0.3
[ "$(cloud-ssh-setup $URL | tail -1)" = "$k1" ] || fail "setup after sshd death"
$S -i /tmp/pc workspace@127.0.0.1 true || fail "login after restart"
echo SMOKE_OK
