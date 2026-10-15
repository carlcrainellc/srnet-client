"""Windows CI check: the installed `srnet ui` and `srnet snapps` start and answer on loopback."""
import json, os, subprocess, sys, tempfile, time, urllib.request


def kill(p):  # cmd /c spawns python as a child: end the whole tree
    subprocess.run(["taskkill", "/T", "/F", "/PID", str(p.pid)], capture_output=True)
from pathlib import Path

srnet = Path(os.environ["LOCALAPPDATA"]) / "srnet-client" / "bin" / "srnet.cmd"
home = Path(tempfile.mkdtemp())
env = dict(os.environ, SRNET_HOME=str(home))

ui = subprocess.Popen(["cmd", "/c", str(srnet), "--home", str(home), "ui", "--no-browser"],
                      stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=env)
url = None
for _ in range(120):
    line = ui.stdout.readline()
    if "http://127.0.0.1:" in line:
        url = line.split("srnet ui: ", 1)[1].strip(); break
assert url, "srnet ui did not print its URL"
page = urllib.request.urlopen(url, timeout=10).read().decode()
assert "Wallet / Top up" in page and "Exits" in page and "SNApps" in page
print("PASS srnet ui", url.split("?")[0])
kill(ui)

# snapps: a local testbed config, then the installed launcher serves the shell page
sys.path.insert(0, str(Path(os.environ["LOCALAPPDATA"]) / "srnet-client" / "app" / "snapps"))
from typed import testbed as T  # noqa: E402
tb = T.start(mirror=False)
cfgp = home / "client.json"
cfgp.write_text(json.dumps(T.client_config(tb)))
sn = subprocess.Popen(["cmd", "/c", str(srnet), "--home", str(home), "snapps", "--config", str(cfgp), "--port", "48931"],
                      stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=env)
ok = False
for _ in range(60):
    try:
        ok = b"SRNet" in urllib.request.urlopen("http://127.0.0.1:48931/", timeout=3).read(); break
    except OSError:
        time.sleep(1)
kill(sn)
assert ok, "srnet snapps did not serve"
print("PASS srnet snapps")

# snapps with no --config: shipped defaults only (placeholders -> empty sidebar), served from the installed app
home2 = Path(tempfile.mkdtemp())
sn = subprocess.Popen(["cmd", "/c", str(srnet), "--home", str(home2), "snapps", "--port", "48932"],
                      stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=dict(env, SRNET_HOME=str(home2)))
side = None
for _ in range(60):
    try:
        req = urllib.request.Request("http://127.0.0.1:48932/api/sidebar", headers={"X-Core": "1"})
        side = json.loads(urllib.request.urlopen(req, timeout=3).read()); break
    except OSError:
        time.sleep(1)
kill(sn)
assert side == {"groups": []}, f"srnet snapps without --config: {side}"
print("PASS srnet snapps (shipped defaults, no --config)")
