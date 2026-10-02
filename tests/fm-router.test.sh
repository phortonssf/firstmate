#!/usr/bin/env bash
# Public CLI behavior, with isolated homes, git repositories and launch-owner fixtures.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP=$(fm_test_tmproot fm-router)
export TEST_ROUTER_ROOT="$ROOT" TEST_ROUTER_TMP="$TMP"
python3 - <<'PY'
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
root = Path(os.environ['TEST_ROUTER_ROOT'])
tmp = Path(os.environ['TEST_ROUTER_TMP'])
home = tmp / 'home'
repo = tmp / 'demo'
repo.mkdir()
subprocess.run(['git', 'init', '-q', str(repo)], check=True)
(repo / 'package.json').write_text('{}')
subprocess.run(['git', '-C', str(repo), 'add', 'package.json'], check=True)
(home / 'config').mkdir(parents=True)
(home / 'state').mkdir()
(home / 'data').mkdir()
fakebin = tmp / 'fakebin'
fakebin.mkdir()
for worker in ('codex', 'claude', 'opencode', 'pi'):
    (fakebin / worker).write_text('#!/usr/bin/env bash\nexit 0\n')
(fakebin / 'curl').write_text("""#!/usr/bin/env bash
# Fake Fastino HTTP for the configured resolver: records the request body, replies from files.
set -u
out=''
while [ $# -gt 0 ]; do
  case "$1" in -o) out=$2; shift 2 ;; *) shift ;; esac
done
printf 'call\n' >> "$FAKE_CURL_LOG/calls"
cat > "$FAKE_CURL_LOG/body"
cp "$FAKE_CURL_RESPONSE" "$out"
printf '%s' "${FAKE_CURL_HTTP:-200}"
""")
(fakebin / 'quota-axi').write_text('#!/usr/bin/env bash\ncat "$QUOTA_AXI_FIXTURE"\n')
for tool in fakebin.iterdir():
    tool.chmod(0o755)
curl_log = tmp / 'curl-log'
curl_log.mkdir()
quota = tmp / 'quota.json'
quota.write_text(json.dumps({'generatedAt': '2030-01-01T00:00:00Z', 'schemaVersion': 5, 'providers': [
    {'provider': name, 'state': {'status': 'fresh'}, 'quotaSemantics': {'status': 'known', 'effectiveAvailability': [
        {'scope': 'all_models', 'status': 'known', 'effectivePercentRemaining': remaining,
         'runway': {'status': 'through_reset'}, 'selection': {'spendPriority': 0.5}}]}}
    for name, remaining in (('claude', 80), ('codex', 31))]}))
env = dict(os.environ, FM_HOME=str(home), PATH=str(fakebin) + os.pathsep + os.environ['PATH'],
           FAKE_CURL_LOG=str(curl_log), FAKE_CURL_RESPONSE=str(tmp / 'response.json'), QUOTA_AXI_FIXTURE=str(quota))
env.pop('FASTINO_API_KEY', None)
env.pop('TYPESAFE_API_KEY', None)
def run(*args, code=0, cli=root / 'bin/fm', cwd=None):
    result = subprocess.run([str(cli), *args], env=env, text=True, capture_output=True, cwd=cwd)
    assert result.returncode == code, (args, result.returncode, result.stderr, result.stdout)
    return result
for request, kind in [('design multiplayer architecture', 'reasoning'), ('fix race deadlock', 'reasoning'), ('fix off-by-one bug', 'bugfix'), ('rename typo', 'mechanical'), ('add feature', 'feature')]:
    value = json.loads(run('route', request, '--project', str(repo), '--worker', 'codex', '--dry-run').stdout)
    assert value['task_class'] == kind
    assert value['profile']['harness'] == 'codex'
    assert 'bypass' in value['permission_posture']
    assert value['repository']['manifests'] == ['package.json']
assert list((home / 'data').iterdir()) == []
assert list((home / 'state').iterdir()) == []
assert json.loads(run('sessions').stdout) == []
run('route', 'fix', '--project', str(repo), '--no-route', code=2)
run('task', '# Task\ninjected', '--project', str(repo), '--worker', 'codex', code=2)
run('task', 'fix', '--project', str(repo), '--worker', 'codex', '--id', 'x' * 65, code=2)
assert list((home / 'data').iterdir()) == []
run('status', '../escape', code=2)
(home / 'state' / 'known.meta').write_text('endpoint_task_id=known\nharness=codex\nworktree=/tmp/not-running\n')
assert json.loads(run('status', 'known').stdout)['liveness'] == 'unknown'
run('resume', 'known', code=2)
assert json.loads(run('resume', 'known', '--note', 'preserve current work', '--dry-run').stdout)['session'] == 'known'
(home / 'state' / 'known.meta').write_text('endpoint_task_id=known\nharness=codex\nproject=' + str(repo) + '\nworktree=/tmp/not-running\n')
assert json.loads(run('resume', '--note', 'explicit progress', '--dry-run', cwd=repo).stdout)['session'] == 'known'
assert json.loads(run(cwd=repo).stdout)[0]['session'] == 'known'
(home / 'state' / 'other.meta').write_text('endpoint_task_id=other\nharness=codex\nproject=' + str(repo) + '\n')
run('resume', '--note', 'explicit progress', '--dry-run', cwd=repo, code=2)
(home / 'state' / 'other.meta').unlink()
(home / 'config' / 'crew-dispatch.json').write_text('{bad')
doctor = json.loads(run('doctor').stdout)
assert doctor['configuration']['dispatch'] == 'invalid'
assert all(w['authentication'] == 'unknown' for w in doctor['workers'])
run('route', 'fix', '--worker', 'codex', '--project', str(repo), code=2)
(home / 'config' / 'crew-dispatch.json').unlink()
# Dirty reports tracked and untracked normal work, never ignored files.
dirty_repo = tmp / 'dirty'
dirty_repo.mkdir()
git = ['git', '-C', str(dirty_repo), '-c', 'user.name=t', '-c', 'user.email=t@example.test']
subprocess.run(['git', 'init', '-q', str(dirty_repo)], check=True)
(dirty_repo / 'tracked.txt').write_text('one')
(dirty_repo / '.gitignore').write_text('ignored.log\n')
subprocess.run([*git, 'add', '.'], check=True)
subprocess.run([*git, 'commit', '-q', '-m', 'init'], check=True)
def dirty():
    return json.loads(run('route', 'fix', '--project', str(dirty_repo), '--worker', 'codex', '--dry-run').stdout)['repository']['dirty']
assert dirty() is False
(dirty_repo / 'ignored.log').write_text('x')
assert dirty() is False
(dirty_repo / 'new.txt').write_text('x')
assert dirty() is True
(dirty_repo / 'new.txt').unlink()
(dirty_repo / 'tracked.txt').write_text('two')
assert dirty() is True
# Simulated HTTP transport drives the actual finite-class public routing path.
hook = tmp / 'pyhook'
hook.mkdir()
(hook / 'sitecustomize.py').write_text("""import json, os, urllib.request
class Reply:
    def __enter__(self): return self
    def __exit__(self, *args): pass
    def read(self, maximum): return os.environ['FAKE_FASTINO_REPLY'].encode()
def open_request(req, timeout):
    assert timeout == 5
    assert req.has_header("Authorization") and "Authorization" not in req.headers
    with open(os.environ['FAKE_FASTINO_REQUEST'], 'w') as f: json.dump(json.loads(req.data), f)
    return Reply()
urllib.request.urlopen = open_request
""")
env['PYTHONPATH'] = str(hook)
env['FASTINO_API_KEY'] = 'private-routing-key'
env['FASTINO_MODEL'] = 'custom-routing-model'
env['FAKE_FASTINO_REQUEST'] = str(tmp / 'request.json')
classes = ['reasoning', 'investigation', 'refactor', 'mechanical', 'bugfix', 'feature', 'general']
answer = {'choice': 'reasoning', 'confidence': .01, 'probabilities': {key: 1 if key == 'reasoning' else 0 for key in classes}}
env['FAKE_FASTINO_REPLY'] = json.dumps({'answers': {'task_class': answer}})
value = json.loads(run('route', 'general request', '--project', str(repo)).stdout)
assert value['task_class'] == 'reasoning' and value['source'] == 'custom-routing-model'
request = json.loads((tmp / 'request.json').read_text())
assert request['model'] == 'custom-routing-model'
assert request['questions']['task_class']['type'] == 'choice'
assert 'private-routing-key' not in json.dumps(value) + json.dumps(request)
answer['probabilities'] = classes
env['FAKE_FASTINO_REPLY'] = json.dumps({'answers': {'task_class': answer}})
value = json.loads(run('route', 'fix bug', '--project', str(repo)).stdout)
assert value['task_class'] == 'bugfix' and value['evidence']['status'] == 'error'
def reply(choice):
    return json.dumps({'answers': {'task_class': {'choice': choice, 'confidence': .9,
                       'probabilities': {key: 1 if key == choice else 0 for key in classes}}}})
never = home / 'config' / 'dispatch-never-send'
request_file = tmp / 'request.json'
env['FAKE_FASTINO_REPLY'] = reply('reasoning')
def withheld(text, listed, label):
    request_file.unlink(missing_ok=True)
    if listed is not None:
        never.write_text(listed)
    result = run('route', text, '--project', str(repo))
    value = json.loads(result.stdout)
    assert value['evidence']['status'] == 'off' and 'nothing sent' in value['evidence']['reason'], label
    assert value['task_class'] == 'bugfix' and value['status'] == 'clear', label
    assert not request_file.exists(), label
    assert 'ledger' not in (result.stdout + result.stderr).lower(), label
withheld('fix the Acme\nLEDGER bug', '# comment\n\n  acme   ledger \n', 'task text, normalized and case-insensitive')
withheld('fix the bug', 'package.json\n', 'repository fact strings are checked too')
never.unlink()
never.mkdir()
withheld('fix the bug', None, 'unreadable list')
never.rmdir()
never.write_text('unrelated-value\n')
assert json.loads(run('route', 'fix the bug', '--project', str(repo)).stdout)['evidence']['status'] == 'clear'
assert request_file.exists()
never.unlink()
env['FASTINO_ENDPOINT'] = 'https://user:SECRET@example.test/api'
refused = run('route', 'general request', '--project', str(repo), code=2)
assert 'SECRET' not in refused.stderr
for key in ('PYTHONPATH', 'FASTINO_ENDPOINT', 'FASTINO_MODEL', 'FASTINO_API_KEY'):
    env.pop(key, None)
assert list((home / 'data').iterdir()) == []
# Configured routing runs the real resolver against fake curl, quota and worker executables.
for key in ('PYTHONPATH', 'FASTINO_ENDPOINT', 'FASTINO_MODEL'):
    env.pop(key, None)
env['FASTINO_API_KEY'] = 'configured-routing-key'
rules = home / 'config' / 'crew-dispatch.json'
calls = curl_log / 'calls'
def configure(value):
    rules.write_text(json.dumps(value))
    calls.unlink(missing_ok=True)
def respond(choice, probabilities=None, http='200'):
    keys = ['rule_1', 'rule_2', 'default']
    env['FAKE_CURL_HTTP'] = http
    (tmp / 'response.json').write_text(json.dumps({'model': 'fixture-glide', 'answers': {'rule': {
        'type': 'choice', 'choice': choice, 'confidence': .9,
        'probabilities': {key: .9 if key == choice else .05 for key in keys}}}}))
language_rules = {'rules': [
    {'when': 'Bug fixes.', 'use': {'harness': 'claude', 'model': 'sonnet'}},
    {'when': 'Heavy lifting.', 'floor': {'scope': 'all_models', 'min_percent': 50, 'provider': 'codex'}, 'use': {'harness': 'codex'}}],
    'default': {'harness': 'claude', 'model': 'opus'}}
configure(language_rules)
respond('rule_1')
value = json.loads(run('route', 'fix the pager', '--project', str(repo)).stdout)
assert value['status'] == 'clear' and value['profile']['harness'] == 'claude' and value['profile']['model'] == 'sonnet' and value['source'] == 'fixture-glide'
assert calls.read_text().count('call') == 1
assert 'configured-routing-key' not in json.dumps(value) + (curl_log / 'body').read_text()
# A model answer that selects a floor-blocked rule is gated: the quota floor falls through to the default.
respond('rule_2')
value = json.loads(run('route', 'heavy work', '--project', str(repo)).stdout)
assert value['profile']['harness'] == 'claude' and 'below 50%' in value['evidence']['note']
# Manual selection bypasses the model but keeps the floor gate.
calls.unlink()
value = json.loads(run('route', 'heavy work', '--project', str(repo), '--worker', 'codex', code=3).stdout)
assert value['status'] == 'needs-decision' and not calls.exists()
value = json.loads(run('route', 'heavy work', '--project', str(repo), '--worker', 'claude', '--model', 'sonnet').stdout)
assert value['status'] == 'clear' and value['source'] == 'manual' and not calls.exists()
# Language-rule outage falls back to nothing silently: configured rules are never bypassed.
respond('rule_1', http='500')
value = json.loads(run('route', 'fix the pager', '--project', str(repo), code=3).stdout)
assert value['status'] == 'needs-decision' and value['routing_failure']['status'] == 'error'
assert 'http 500' in value['routing_failure']['reason']
# A never-send match withholds the configured request with structured off evidence and no network.
never.write_text('Acme Ledger\n')
calls.unlink(missing_ok=True)
respond('rule_1')
refused = run('route', 'fix acme   ledger', '--project', str(repo), code=3)
value = json.loads(refused.stdout)
assert value['routing_failure']['status'] == 'off' and not calls.exists()
assert 'ledger' not in (refused.stdout + refused.stderr).lower()
never.unlink()
# Default-only configuration resolves locally without the network.
configure({'default': {'harness': 'claude'}})
value = json.loads(run('route', 'fix the pager', '--project', str(repo)).stdout)
assert value['status'] == 'clear' and value['profile']['harness'] == 'claude' and not calls.exists()
rules.unlink()
env['FASTINO_API_KEY'] = 'never-in-worker-env'
# Copied CLI calls fixture owners instead of launching any real worker.
code = tmp / 'code'
(code / 'bin').mkdir(parents=True)
shutil.copy2(root / 'bin/fm', code / 'bin/fm')
log = tmp / 'owners.log'
env['ROUTER_OWNER_LOG'] = str(log)
env['FASTINO_API_KEY'] = 'never-in-worker-env'
for name, body in {
'fm-project-mode.sh': 'case "$1" in --branch-prefix) echo fm/;; --forge) echo none;; *) echo "no-mistakes off";; esac',
'fm-tasks-axi.sh': 'mkdir -p "$FM_HOME/data"',
'fm-brief.sh': 'test "${FIXTURE_BRIEF_EXIT:-0}" = 0 || exit "$FIXTURE_BRIEF_EXIT"; mkdir -p "$FM_HOME/data/$1"; printf "# Task\\n## Captain\x27s intent\\n{TASK}\\n## Firstmate spec\\n{FIRSTMATE_SPEC}\\n" > "$FM_HOME/data/$1/brief.md"',
'fm-spawn.sh': 'test -z "${FASTINO_API_KEY:-}"; exit "${FIXTURE_SPAWN_EXIT:-0}"',
'fm-control.sh': 'test -z "${FASTINO_API_KEY:-}"; test "$1" = known; test "$2" = relaunch'
}.items():
    path = code / 'bin' / name
    path.write_text('#!/usr/bin/env bash\nset -eu\nprintf "%s\\n" "' + name + ' $*" >> "$ROUTER_OWNER_LOG"\n' + body + '\n')
    path.chmod(0o755)
(home / 'data' / 'projects.md').write_text('- demo [no-mistakes] - fixture\n')
result = run('task', 'fix harmless fixture', '--project', str(repo), '--worker', 'codex', '--id', 'launched', cli=code / 'bin/fm')
assert 'Permission posture: Codex bypass' in result.stderr
assert json.loads(result.stdout)['launch_outcome'] == 'launched'
assert json.loads((home / 'data' / 'launched' / 'route.json').read_text())['home'] == str(home)
assert '{TASK}' not in (home / 'data' / 'launched' / 'brief.md').read_text()
(home / 'data' / 'known').mkdir()
env['FIXTURE_SPAWN_EXIT'] = '7'
failed = run('task', 'fix fixture failure', '--project', str(repo), '--worker', 'codex', '--id', 'failed', cli=code / 'bin/fm', code=2)
assert 'Task identity: failed' in failed.stderr and 'task failed preserved' in failed.stderr
assert json.loads((home / 'data' / 'failed' / 'route.json').read_text())['launch_outcome'] == 'failed'
assert log.read_text().count('fm-spawn.sh failed ') == 1
assert any(value['session'] == 'failed' for value in json.loads(run('sessions', cli=code / 'bin/fm').stdout))
env.pop('FIXTURE_SPAWN_EXIT')
env['FIXTURE_BRIEF_EXIT'] = '9'
run('task', 'fix brief failure', '--project', str(repo), '--worker', 'codex', '--id', 'nobrief', cli=code / 'bin/fm', code=2)
env.pop('FIXTURE_BRIEF_EXIT')
early = json.loads(run('status', 'nobrief', cli=code / 'bin/fm').stdout)
assert early['session'] == 'nobrief' and early['routing']['launch_outcome'] == 'failed' and 'record' not in early
assert early == next(v for v in json.loads(run('sessions', cli=code / 'bin/fm').stdout) if v['session'] == 'nobrief')
run('status', 'absent-task', cli=code / 'bin/fm', code=2)
run('status', 'nobrief/../x', cli=code / 'bin/fm', code=2)
(home / 'data' / 'damaged').mkdir()
(home / 'data' / 'damaged' / 'route.json').write_text('{"task_class": "bug')
(home / 'data' / 'nonfinite').mkdir()
(home / 'data' / 'nonfinite' / 'route.json').write_text('{"confidence": NaN}')
for command in ('sessions', 'status'):
    listed = {value['session']: value for value in json.loads(run(command, cli=code / 'bin/fm').stdout)}
    assert 'damaged routing evidence' in listed['damaged']['error']
    assert 'damaged routing evidence' in listed['nonfinite']['error']
    assert 'routing' in listed['failed'] and 'routing' in listed['launched'] or 'record' in listed['launched']
for name in ('damaged', 'nonfinite'):
    assert 'damaged routing evidence' in json.loads(run('status', name, cli=code / 'bin/fm').stdout)['error']
run(cli=code / 'bin/fm')
assert (home / 'data' / 'damaged' / 'route.json').read_text() == '{"task_class": "bug'
shutil.rmtree(home / 'data' / 'damaged')
shutil.rmtree(home / 'data' / 'nonfinite')
run('resume', 'known', '--note', 'saved progress', cli=code / 'bin/fm')
assert (home / 'data' / 'known' / 'progress.md').read_text().strip() == 'saved progress'
assert 'fm-control.sh known relaunch --note saved progress' in log.read_text()
# Native supports remain exclusively the existing owner's responsibility.
print('ok: router dry-run, override, classification, state isolation, launch and continuation')
PY
pass "router public CLI fixtures"
