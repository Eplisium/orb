"""Opt-in offline SIGKILL recovery checks; build tests before running."""
import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import time
import uuid

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--workspace', required=True, type=Path, help='Disposable scratch directory for fixtures and logs')
parser.add_argument('--health-url', help='Optional hosting health endpoint; require HTTP 200 after each phase')
args = parser.parse_args()
root = args.workspace.expanduser().resolve()
root.mkdir(parents=True, exist_ok=True)
repo = Path(__file__).resolve().parents[1]
phases = ['afterRename', 'acknowledge', 'afterUnlink']
results = []


def guard():
    print(subprocess.check_output(['uptime'], text=True).strip(), flush=True)
    if os.getloadavg()[0] > 8:
        raise RuntimeError('Load exceeds 8; retry later')
    names = {'swift-build', 'swift-test', 'swift-frontend', 'xcodebuild', 'cargo', 'xctest', 'ORBTests', 'swiftpm-testing-helper'}
    commands = subprocess.check_output(['ps', '-axo', 'comm'], text=True).splitlines()
    if any(Path(c.strip()).name in names for c in commands):
        raise RuntimeError('Competing heavy job')


def health():
    if not args.health_url:
        return
    code = subprocess.check_output(['curl', '-sS', '--max-time', '20', '-o', '/dev/null', '-w', '%{http_code}', args.health_url], text=True)
    if code != '200':
        raise RuntimeError('Site health degraded: ' + code)


def kill_owned(process):
    if process.poll() is None:
        os.killpg(process.pid, signal.SIGKILL)
    process.wait(timeout=15)


for phase in phases:
    guard()
    fixture = root / ('ORB-job-crash-' + str(uuid.uuid4()))
    fixture.mkdir(mode=0o700)
    (fixture / 'probe-permitted').write_text(fixture.name)
    (fixture / 'temp').mkdir()
    (fixture / 'home').mkdir()
    env = os.environ.copy()
    for key in ['RUN_OPENROUTER_INTEGRATION', 'ORB_STREAM_SNAPSHOT_DIR', 'ORB_REASONING_SNAPSHOT']:
        env.pop(key, None)
    env.update(ORB_JOB_CRASH_ROOT=str(fixture), ORB_JOB_CRASH_PHASE=phase,
               ORB_JOB_CRASH_MODE='writer', TMPDIR=str(fixture / 'temp') + '/',
               CFFIXED_USER_HOME=str(fixture / 'home'))
    command = ['nice', '-n', '10', 'swift', 'test', '--skip-build', '-j', '4', '--no-parallel', '--filter', 'JobProcessCrashTests']
    with (fixture / 'writer.log').open('x') as output:
        process = subprocess.Popen(command, cwd=repo, env=env, stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            deadline = time.monotonic() + 45
            while not (fixture / 'reached').exists():
                if process.poll() is not None:
                    raise RuntimeError('Writer exited before barrier; inspect ' + str(fixture / 'writer.log'))
                if time.monotonic() >= deadline:
                    raise RuntimeError('Writer barrier timed out')
                time.sleep(0.05)
            reached = json.loads((fixture / 'reached').read_text())
            assert reached['phase'] == phase
            # SwiftPM may launch its testing helper in a different process group.
            # Kill the PID reported by this fresh, bounded fixture itself, not an
            # inferred process name or a possibly shared helper process group.
            writer_pid = reached['pid']
            assert isinstance(writer_pid, int) and writer_pid > 1 and writer_pid != os.getpid()
            os.kill(writer_pid, signal.SIGKILL)
            kill_owned(process)
        finally:
            kill_owned(process)
    health()
    # Killed descendants must release locks before the verifier. This is a
    # bounded foreground wait on this run, never a background polling daemon.
    time.sleep(0.3)
    env['ORB_JOB_CRASH_MODE'] = 'verify'
    with (fixture / 'verify.log').open('x') as output:
        process = subprocess.Popen(command, cwd=repo, env=env, stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            code = process.wait(timeout=60)
        finally:
            kill_owned(process)
    log = (fixture / 'verify.log').read_text(errors='replace')
    if code != 0 or 'Test run with 1 test in 1 suite passed' not in log:
        raise RuntimeError('Fresh verifier failed or ran no test: ' + str(fixture / 'verify.log'))
    result = json.loads((fixture / 'verified.json').read_text())
    assert result['phase'] == phase
    result['fixture'] = str(fixture)
    results.append(result)
    print(json.dumps(result), flush=True)
    health()
(root / 'process-crash-results.json').write_text(json.dumps(results, indent=2))
print('PASS', len(results), 'process-kill boundaries; not a power-loss test', flush=True)
