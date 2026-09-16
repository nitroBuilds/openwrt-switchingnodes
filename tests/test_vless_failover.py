"""Run from the repository root: python3 -m unittest discover -s tests -v.

Lua tests use lua/luajit, or the optional Python lupa package (Lua 5.1).
HTTP responses and service operations are mocked; no router/network is required.
"""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "luci-app-passwall2/root/usr/share/passwall2/vless_failover.sh"


class FailoverTests(unittest.TestCase):
    def shell(self, body, env=None):
        source = SCRIPT.read_text().replace('. /usr/share/passwall2/utils.sh', '')
        source = source.rsplit('\nmain\n', 1)[0]
        source = source.replace('/usr/bin/curl', 'fake_curl')
        source = source.replace('/etc/init.d/passwall2 vless_failover', 'fake_switch')
        return subprocess.run(['/bin/sh'], input=source + '\n' + body, text=True,
                              capture_output=True, env={**os.environ, **(env or {})})

    def test_http_body(self):
        for response, code, expected in [('200 123', 0, 0), ('204 0', 0, 1),
                                         ('200 0', 0, 1), ('403 300', 22, 1),
                                         ('000 0', 28, 1), ('200 123', 18, 1),
                                         ('302 100', 0, 1)]:
            with self.subTest(response=response, code=code):
                result = self.shell('''
fake_curl() { printf '%s' "$RESPONSE"; return "$CURL_CODE"; }
probe 127.0.0.1:1070 https://www.youtube.com/ 10
''', {'RESPONSE': response, 'CURL_CODE': str(code)})
                self.assertEqual(result.returncode, expected, result.stderr)

    def test_proxy_and_timeout_arguments(self):
        with tempfile.TemporaryDirectory() as folder:
            args = Path(folder) / 'args'
            result = self.shell('''
fake_curl() { printf '%s\n' "$@" > "$ARGS"; printf '200 42'; }
probe 127.0.0.1:1070 https://www.youtube.com/ 10
''', {'ARGS': str(args)})
            self.assertEqual(result.returncode, 0, result.stderr)
            arguments = args.read_text().splitlines()
            self.assertIn('socks5h://127.0.0.1:1070', arguments)
            self.assertNotIn('-I', arguments)
            self.assertNotIn('-k', arguments)
            self.assertEqual(arguments[arguments.index('--max-time') + 1], '10')
            self.assertEqual(arguments[arguments.index('--noproxy') + 1], '')

    def test_monitor(self):
        for healthy, cache, expected in [('0', 'a1', 1), ('1', 'a1', 0),
                                         ('0', 'outdated', 0), ('0', '', 1)]:
            with self.subTest(healthy=healthy, cache=cache):
                result = self.shell('''
CONFIG=passwall2
LOCK_PATH=/nonexistent-passwall2-test
config_n_get() {
    case "$2" in
        enabled|vless_failover) echo 1;;
        node) echo a1;; protocol) echo vless;; add_mode) echo 2;;
        vless_failover_url) echo https://www.youtube.com/;;
        vless_failover_failures) echo 2;;
    esac
}
get_cache_var() {
    case "$1" in ACL_GLOBAL_node) echo "$CACHE";; *) echo 127.0.0.1:1070;; esac
}
checks=0
sleep() { checks=$((checks + 1)); [ "$checks" -lt 5 ] || exit 0; }
log() { :; }
probe() { [ "$HEALTHY" = 1 ]; }
fake_switch() { echo "switch:$1:$checks"; }
main
''', {'HEALTHY': healthy, 'CACHE': cache})
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.count('switch:'), expected)
                if expected:
                    self.assertIn('switch:a1:2', result.stdout)

    def test_service_switch(self):
        source = (ROOT / 'luci-app-passwall2/root/etc/init.d/passwall2').read_text()
        source = source.replace('. $IPKG_INSTROOT/usr/share/passwall2/utils.sh', '')
        source = source.replace('$APP_FILE stop', 'fake_app stop')
        source = source.replace('$APP_FILE start', 'fake_app start')
        for selection_code in [0, 1]:
            with self.subTest(selection_code=selection_code):
                result = subprocess.run(['/bin/sh'], input=source + '''
CONFIG=passwall2
LOCK_PATH=/nonexistent-passwall2-test
set_lock() { echo lock; }
unset_lock() { echo unlock; }
lua() { echo b1; return "$SELECTION_CODE"; }
log() { :; }
fake_app() { echo "$1"; }
vless_failover a1
''', text=True, capture_output=True,
                    env={**os.environ, 'SELECTION_CODE': str(selection_code)})
                self.assertEqual(result.returncode, selection_code, result.stderr)
                self.assertEqual(result.stdout.splitlines(),
                                 ['lock', 'stop', 'start', 'unlock'] if selection_code == 0
                                 else ['lock', 'unlock'])

    def test_lua(self):
        interpreter = shutil.which('lua') or shutil.which('luajit')
        if interpreter:
            subprocess.run([interpreter, 'tests/test_vless_failover.lua'], cwd=ROOT,
                           check=True)
        else:
            try:
                from lupa.lua51 import LuaRuntime
            except ImportError:
                self.skipTest('Install Lua 5.1 or lupa to run the Lua tests')
            runtime = LuaRuntime()
            original = os.getcwd()
            try:
                os.chdir(ROOT)
                runtime.execute((ROOT / 'tests/test_vless_failover.lua').read_text())
                for relative in ['luci-app-passwall2/luasrc/model/cbi/passwall2/client/global.lua']:
                    runtime.execute('assert(loadfile(...))', str(ROOT / relative))
            finally:
                os.chdir(original)


if __name__ == '__main__':
    unittest.main()
