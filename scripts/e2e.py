#!/usr/bin/env python3
"""Binary-driven end-to-end acceptance. No unit tests or alternate app model."""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import signal
import socket
import struct
import subprocess
import sys
import time
import urllib.request
import wave

ROOT = Path(__file__).resolve().parent.parent

def free_port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--playback', action='store_true', help='Exercise owned real afplay early-stop/reap without recording; requires a working output device')
    parser.add_argument('--synthetic-microphone', action='store_true', help='Explicit synthetic E2E microphone PCM; requires --capture and retains real system tap/playback')
    parser.add_argument('--compatibility-evidence', type=Path, help='Open encrypted mock/Keychain roots and restore backup from a previous product E2E run without relocating its keys')
    capture_mode = parser.add_mutually_exclusive_group()
    capture_mode.add_argument('--capture', action='store_true', help='Exercise capture PCM, live quit, busy stop and owned-device faults; real microphone is default')
    capture_mode.add_argument('--capture-off', action='store_false', dest='capture', help='Run deterministic binary/HTTP acceptance without requesting capture permissions')
    parser.set_defaults(capture=False)
    args = parser.parse_args()
    if args.synthetic_microphone and not args.capture:
        parser.error('--synthetic-microphone requires --capture')
    evidence = ROOT / '.e2e' / time.strftime('%Y%m%d-%H%M%S')
    evidence.mkdir(parents=True)
    vault = evidence / 'vault'
    fixture = evidence / 'planning.wav'
    with wave.open(str(fixture), 'wb') as wav:
        wav.setnchannels(1); wav.setsampwidth(2); wav.setframerate(16000)
        # Deterministic nonsilent PCM exercises the real audio file reader/chunker.
        samples = [int(6000 * math.sin(2 * math.pi * 440 * i / 16000)) for i in range(4 * 16000)]
        wav.writeframes(struct.pack('<' + 'h' * len(samples), *samples))
    long_fixture = evidence / 'long-meeting.wav'
    silent_fixture = evidence / 'silent.wav'
    with wave.open(str(long_fixture), 'wb') as wav:
        wav.setnchannels(1); wav.setsampwidth(2); wav.setframerate(16000)
        one_second = struct.pack('<' + 'h'*16000, *samples[:16000])
        for _ in range(65): wav.writeframes(one_second)
    with wave.open(str(silent_fixture), 'wb') as wav:
        wav.setnchannels(1); wav.setsampwidth(2); wav.setframerate(16000)
        wav.writeframes(bytes(32000))
    backup = evidence / 'meeting.backup'
    phrase = 'a' * 64
    port = free_port()
    sentinel = 'SYNTHETIC_E2E_KEY_MUST_NEVER_REACH_MOCK'
    server = subprocess.Popen([sys.executable, str(ROOT / 'proxy/server.py'), '--mock', '--delay-ms', '250', '--forbid-credential', sentinel, '--port', str(port)], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    url = f'http://127.0.0.1:{port}'
    binary = ROOT / 'dist/Hush.app/Contents/MacOS/Hush'
    binary_hash = hashlib.sha256(binary.read_bytes()).hexdigest()
    results = []
    compatibility_checks = []
    def group_exists(process):
        try:
            os.killpg(process.pid, 0)
            return True
        except ProcessLookupError:
            return False

    def terminate_group(process, phase):
        phase('checking-owned-group')
        if group_exists(process):
            phase('signalling-owned-group-TERM')
            try: os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError: pass
            deadline = time.monotonic() + 2
            while group_exists(process) and time.monotonic() < deadline: time.sleep(.02)
            if group_exists(process):
                phase('signalling-owned-group-KILL')
                try: os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError: pass
        phase('reaping-owned-app-and-draining-pipes')
        output = process.communicate(timeout=5)
        deadline = time.monotonic() + 2
        while group_exists(process) and time.monotonic() < deadline: time.sleep(.02)
        if group_exists(process):
            raise RuntimeError('Owned app/playback process group survived bounded termination')
        phase('owned-group-exit-observed')
        return output

    def launch(name, commands, demo=False, keychain=False, vault_root=None, appearance=None, unregistered_store=False):
        command_path = evidence / f'{name}-commands.json'
        result_path = evidence / f'{name}-results.json'
        log_path = evidence / f'{name}-process.log'
        process_path = evidence / f'{name}-process.json'
        command_path.write_text(json.dumps(commands))
        root = vault_root or (evidence / 'keychain-vault' if keychain else vault)
        original_mode = root.stat().st_mode & 0o7777 if root.exists() else 0o700
        process = None
        stdout = stderr = ''
        primary_failure = None
        cleanup_failures = []
        started_at = time.monotonic()
        process_evidence = {'name':name, 'phase':'launching', 'pid':None, 'ownedProcessGroup':None, 'phases':[]}

        def phase(value):
            process_evidence.update(phase=value, elapsedSeconds=time.monotonic() - started_at)
            process_evidence['phases'].append({'phase':value, 'elapsedSeconds':process_evidence['elapsedSeconds']})
            process_path.write_text(json.dumps(process_evidence, indent=2))

        def text(value):
            return value.decode(errors='replace') if isinstance(value, bytes) else value or ''

        try:
            phase('launching')
            child_env = dict(os.environ, HUSH_UPSTREAM_API_KEY=sentinel)
            executable = [str(ROOT / 'scripts/start.sh'), '--mock'] if demo else [str(binary)]
            flags = ['--keychain-vault'] if keychain else []
            if unregistered_store:
                if not keychain:
                    raise RuntimeError('Unregistered-store proof requires the real original Keychain path')
                flags.append('--e2e-unregistered-store')
            if appearance:
                flags.extend(['-appearance', appearance])
            if args.synthetic_microphone and root in (evidence / 'capture-vault', evidence / 'pause-vault'):
                flags.append('--synthetic-microphone')
            process = subprocess.Popen([*executable, '--e2e', *flags, '--root', str(root), '--endpoint', url, '--commands', str(command_path), '--results', str(result_path)],
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=child_env, start_new_session=True)
            process_evidence.update(pid=process.pid, ownedProcessGroup=process.pid)
            phase('waiting-for-app')
            stdout, stderr = process.communicate(timeout=120)
            log_path.write_text(stderr)
            phase('app-exit-observed')
            if group_exists(process):
                primary_failure = RuntimeError('App exited without reaping its owned playback process group')
        except subprocess.TimeoutExpired as error:
            stdout, stderr = text(error.stdout), text(error.stderr)
            # Preserve the original timeout output before ANY group probe or signal,
            # since macOS may reject that teardown with EPERM.
            log_path.write_text(stderr)
            authorization = ''
            try:
                if result_path.exists():
                    partial = json.loads(result_path.read_text())
                    authorization = next((r['detail'] for r in partial if r['action'] == 'captureAuthorization'), '')
            except (OSError, ValueError, TypeError) as diagnostic_error:
                authorization = f'Partial authorization evidence unreadable: {diagnostic_error}'
            prerequisite = f'; real authorization diagnostic: {authorization}' if authorization else ''
            primary_failure = RuntimeError(f'Timed out after 120 seconds{prerequisite}; last runner activity: {stderr[-2000:]}')
            process_evidence['primaryFailure'] = str(primary_failure)
            phase('timeout-output-preserved')
        except Exception as error:
            primary_failure = error
        finally:
            try:
                if process is not None:
                    try:
                        phase('checking-cleanup')
                        if group_exists(process):
                            stdout, stderr = terminate_group(process, phase)
                    except Exception as error:
                        cleanup_failures.append(f'{process_evidence["phase"]}: {type(error).__name__}: {error}')
                        if isinstance(error, subprocess.TimeoutExpired):
                            stdout, stderr = text(error.stdout), text(error.stderr)
            finally:
                if any(c['action'] in ('recordStartFailure', 'recordQuitWriteFailure') for c in commands) and root.exists():
                    try:
                        phase('restoring-owned-vault-permissions')
                        root.chmod(original_mode)
                    except Exception as error:
                        cleanup_failures.append(f'Restoring isolated vault permissions: {type(error).__name__}: {error}')
                log_path.write_text(stderr)
                (evidence / f'{name}-stdout.log').write_text(stdout)
                process_evidence.update(returncode=process.poll() if process is not None else None,
                                        primaryFailure=str(primary_failure) if primary_failure else None,
                                        cleanupFailures=cleanup_failures)
                phase('failed' if primary_failure or cleanup_failures else 'complete')
        if primary_failure or cleanup_failures:
            primary = f'{type(primary_failure).__name__}: {primary_failure}' if primary_failure else 'No primary execution failure'
            cleanup = '; '.join(cleanup_failures) or 'none'
            raise RuntimeError(f'{name}: owned PID={process_evidence["pid"]}, group={process_evidence["ownedProcessGroup"]}; {primary}; cleanup failures: {cleanup}; evidence {process_path}')
        if not result_path.exists():
            raise RuntimeError(f'{name}: binary emitted no evidence (exit {process.returncode}): {stderr[-2000:]}')
        rows = json.loads(result_path.read_text())
        results.extend(rows)
        for row in rows:
            print(('PASS' if row['passed'] else 'FAIL') + ' ' + row['action'] + ': ' + row['detail'][:180])
        if process.returncode != 0 or len(rows) != len(commands) or not all(row['passed'] for row in rows):
            raise RuntimeError(f'{name}: E2E failed (exit {process.returncode}); evidence {result_path}')
        if not result_path.with_suffix('.png').exists():
            raise RuntimeError(f'{name}: actual app screenshot missing')
        identity = json.loads(result_path.with_suffix('.identity.json').read_text())
        expected_identity = {'windowTitle':'Hush', 'executableName':'Hush',
                             'bundleName':'Hush', 'bundleExecutable':'Hush',
                             'bundleIdentifier':'ai.privategranola.local'}
        if identity != expected_identity:
            raise RuntimeError(f'{name}: actual AppKit/bundle identity mismatch: {identity}')
        presentation = json.loads(result_path.with_suffix('.presentation.json').read_text())
        if presentation.get('ui') != 'Muesli' or presentation.get('synchronized') is not True:
            raise RuntimeError(f'{name}: native Muesli presentation did not match the encrypted meeting state')
        if presentation.get('meetingCount') != rows[-1]['meetingCount']:
            raise RuntimeError(f'{name}: native meeting list differs from the secure coordinator')
        return rows
    try:
        for _ in range(100):
            if server.poll() is not None: raise RuntimeError('Mock server exited: ' + server.stderr.read().decode())
            try:
                with urllib.request.urlopen(url + '/health', timeout=1) as response:
                    if response.status == 200: break
            except OSError: time.sleep(.1)
        else: raise RuntimeError('Mock server did not become ready')
        from proxy_e2e import exercise
        service_checks = exercise(url, sentinel)
        (evidence / 'proxy-security-results.json').write_text(json.dumps(service_checks, indent=2))
        if args.compatibility_evidence:
            previous = args.compatibility_evidence.resolve()
            previous_summary = json.loads((previous / 'summary.json').read_text())
            if not previous_summary.get('passed'):
                raise RuntimeError('Compatibility evidence must come from a successful previous application run')
            if previous_summary.get('uiFoundation') == 'Muesli' or previous_summary.get('binarySHA256') == binary_hash:
                raise RuntimeError('Migration compatibility requires pre-migration Hush evidence, not this native fork')

            def previous_snapshot(name):
                rows = json.loads((previous / f'{name}-results.json').read_text())
                return json.loads(next(row['detail'] for row in reversed(rows)
                                       if row['action'] == 'snapshot' and row['passed']))

            for name, root_name, keychain in [('demo-entrypoint', 'vault', False),
                                              ('keychain-restart', 'keychain-vault', True)]:
                previous_root = previous / root_name
                if not (previous_root / 'vault.pgenc').is_file():
                    raise RuntimeError(f'Previous encrypted root missing: {previous_root}')
                expected = previous_snapshot(name)
                reopened = launch(f'previous-{root_name}', [{'action':'snapshot','expectCount':len(expected)}],
                                  keychain=keychain, vault_root=previous_root)
                if json.loads(reopened[-1]['detail']) != expected:
                    raise RuntimeError(f'Hush changed previous {root_name} IDs, transcripts, notes or embeddings')
                compatibility_checks.append({'kind':root_name, 'path':str(previous_root),
                                             'originalKeyIdentity':True, 'exactSnapshotPreserved':True})
            previous_backup = previous / 'meeting.backup'
            expected_backup = previous_snapshot('feature-flow')
            restored_previous = launch('previous-backup', [
                {'action':'restore','path':str(previous_backup),'phrase':phrase,'expectCount':len(expected_backup)},
                {'action':'snapshot','expectCount':len(expected_backup)},
            ], vault_root=evidence / 'previous-backup-vault')
            if json.loads(restored_previous[-1]['detail']) != expected_backup:
                raise RuntimeError('Hush changed previous backup IDs, transcripts, notes or embeddings')
            compatibility_checks.append({'kind':'backup', 'path':str(previous_backup),
                                         'exactSnapshotPreserved':True})
            (evidence / 'compatibility-results.json').write_text(json.dumps(compatibility_checks, indent=2))
        if args.playback:
            playback_rows = launch('owned-playback-lifecycle', [{'action':'playbackLifecycle','path':str(fixture)}])
            playback_detail = json.loads(playback_rows[0]['detail'])
            if not playback_detail['playbackReaped'] or not playback_detail['stoppedEarly'] or not 0 < playback_detail['elapsedSeconds'] < 3:
                raise RuntimeError('Real binary playback did not prove bounded early stop and reap')
        first = launch('feature-flow', [
            {'action':'verify','expectContains':'mock'},
            {'action':'configureMock','value':sentinel,'expectContains':'mock'},
            {'action':'quota','expectError':True,'expectContains':'Connect your wallet'},
            {'action':'login','value':'alice.testnet','expectContains':'quota'},
            {'action':'stake','value':'2000000000000000000000000','expectContains':'2000000000000000000000000'},
            {'action':'quota','expectContains':'credits'},
            {'action':'importAudio','path':str(fixture),'value':'E2E planning meeting','expectCount':1,'expectContains':'Alice'},
            {'action':'notes','value':'Follow up with Alice on Friday. Private scratch note.'},
            {'action':'summarize','expectContains':'Friday'},
            {'action':'summarize','value':'Sales','expectContains':'Alice'},
            {'action':'summarize','value':'1:1','expectContains':'Alice'},
            {'action':'summarize','value':'Use sections Evidence and Follow-ups.','expectContains':'Alice'},
            {'action':'search','value':'planning','expectContains':'E2E planning meeting'},
            {'action':'nativeSearch','value':'planning','expectContains':'E2E planning meeting'},
            {'action':'showScreen','value':'meeting','expectContains':'screen=meeting'},
            {'action':'ask','value':'What did we discuss?','expectContains':'[meeting:'},
            {'action':'rejectedModel','value':'gpt-4o','expectError':True,'expectContains':'allowlist'},
            {'action':'rejectedEndpoint','value':'http://example.com','expectError':True,'expectContains':'Endpoint rejected'},
            {'action':'summarize','expectContains':'Alice'},
            {'action':'nativeSummary','expectContains':'Alice'},
            {'action':'nativeSyncPrivacy','expectContains':'excluded from outbound sync'},
            {'action':'backup','path':str(backup),'phrase':phrase},
            {'action':'viewNotes','expectContains':'Alice'},
            {'action':'nativePresentation','expectContains':'Muesli'},
            {'action':'snapshot','expectContains':'Private scratch note.','expectCount':1},
        ])
        restarted = launch('restart', [{'action':'snapshot','expectCount':1,'expectContains':'Private scratch note.'}])
        if json.loads(first[-1]['detail']) != json.loads(restarted[-1]['detail']):
            raise RuntimeError('Restart changed meeting IDs, segments, notes or embeddings')
        hardware = launch('capture-hardware', [
            {'action':'captureAuthorization'},
            {'action':'snapshot'},
        ])
        hardware_detail = hardware[0]['detail']
        missing_input = 'No microphone input device is available' in hardware_detail
        if 'defaultInputDevice=unavailable' in hardware_detail and not missing_input:
            raise RuntimeError('Cannot determine actual microphone availability: ' + hardware_detail)
        if missing_input:
            unavailable = launch('missing-microphone', [
                {'action':'recordUnavailableInput','expectError':True,'expectContains':'No microphone input device is available'},
                {'action':'pendingQueue','expectContains':'pending=0'},
                {'action':'snapshot','expectCount':1},
            ])
            if json.loads(hardware[-1]['detail']) != json.loads(unavailable[-1]['detail']):
                raise RuntimeError('Missing microphone changed persisted meetings, notes or transcript')
        encrypted_files = [p for p in vault.rglob('*') if p.is_file()] + [backup]
        for p in encrypted_files:
            contents = p.read_bytes()
            if b'Private scratch note.' in contents or b'E2E planning meeting' in contents:
                raise RuntimeError(f'Plaintext data persisted in {p}')
        pristine = backup.read_bytes()
        damaged = bytearray(pristine); damaged[len(damaged)//2] ^= 1
        corrupt = evidence / 'corrupt.backup'; corrupt.write_bytes(damaged)
        restored = launch('backup-integrity', [
            {'action':'restore','path':str(backup),'phrase':'b'*64,'expectError':True,'expectContains':'incorrect','expectCount':1},
            {'action':'restore','path':str(corrupt),'phrase':phrase,'expectError':True,'expectContains':'damaged','expectCount':1},
            {'action':'snapshot','expectContains':'Private scratch note.','expectCount':1},
            {'action':'delete','expectCount':0},
            {'action':'restore','path':str(backup),'phrase':phrase,'expectCount':1},
            {'action':'snapshot','expectContains':'Private scratch note.','expectCount':1},
        ])
        restore_restarted = launch('restore-restart', [{'action':'snapshot','expectCount':1,'expectContains':'Private scratch note.'}])
        baseline = json.loads(first[-1]['detail'])
        if baseline != json.loads(restored[2]['detail']) or baseline != json.loads(restored[-1]['detail']) or baseline != json.loads(restore_restarted[-1]['detail']):
            raise RuntimeError('Backup integrity/restore changed consumer data')
        launch('concurrency', [
            {'action':'concurrentSummaryEdit','value':'Edited during summary. Private scratch note.','expectError':True,'expectContains':'changed during summarization'},
            {'action':'snapshot','expectContains':'Edited during summary.'},
            {'action':'concurrentRestore','path':str(backup),'phrase':phrase,'value':str(fixture),'expectError':True,'expectContains':'wait for queued transcription'},
            {'action':'pendingQueue','expectContains':'pending=0'},
        ])
        def inject(failures):
            request = urllib.request.Request(url + '/mock/control', data=json.dumps({'fail':failures}).encode(), headers={'Content-Type':'application/json'}, method='POST')
            with urllib.request.urlopen(request, timeout=3) as response:
                if response.status != 200: raise RuntimeError('Failure control rejected')
        inject(['transcription'])
        launch('offline-queue', [
            {'action':'importAudio','path':str(fixture),'value':'Offline meeting','expectError':True,'expectContains':'HTTP 503'},
            {'action':'notes','value':'Notes while offline.'},
            {'action':'pendingQueue','expectContains':'pending=1'},
            {'action':'backup','path':str(evidence / 'offline.backup'),'phrase':phrase},
            {'action':'delete'},
            {'action':'pendingQueue','expectContains':'pending=0'},
            {'action':'restore','path':str(evidence / 'offline.backup'),'phrase':phrase},
            {'action':'pendingQueue','expectContains':'pending=1'},
        ])
        inject([])
        recovered = launch('offline-restart', [
            {'action':'retryQueue','expectContains':'retried'},
            {'action':'retryQueue','expectContains':'retried'},
            {'action':'pendingQueue','expectContains':'pending=0'},
            {'action':'snapshot','expectContains':'Notes while offline.'},
        ])
        offline = next(m for m in json.loads(recovered[-1]['detail']) if m['title'] == 'Offline meeting')
        if len(offline['segments']) != 1 or offline['scratchNotes'] != 'Notes while offline.':
            raise RuntimeError('Queued retry lost notes or duplicated transcript')
        chunks = launch('audio-boundaries', [
            {'action':'importAudio','path':str(silent_fixture),'expectError':True,'expectContains':'no audible audio'},
            {'action':'importAudio','path':str(long_fixture),'value':'Long meeting','expectContains':'Alice'},
            {'action':'pendingQueue','expectContains':'pending=0'},
            {'action':'snapshot','expectContains':'Long meeting'},
        ])
        long_meeting = next(m for m in json.loads(chunks[-1]['detail']) if m['title'] == 'Long meeting')
        if [(s['start'], s['end']) for s in long_meeting['segments']] != [(0,30),(30,60),(60,65)]:
            raise RuntimeError('Long audio chunk boundaries lost or reordered audio')
        launch('demo-entrypoint', [{'action':'verify','expectContains':'mock'},{'action':'snapshot','expectContains':'Long meeting'}], demo=True)
        keychain_saved = launch('keychain-storage', [
            {'action':'importAudio','path':str(fixture),'value':'Keychain meeting','expectContains':'Alice'},
            {'action':'notes','value':'Normal Keychain storage survives restart.'},
            {'action':'snapshot','expectContains':'Normal Keychain storage survives restart.','expectCount':1},
        ], keychain=True)
        keychain_loaded = launch('keychain-restart', [{'action':'snapshot','expectContains':'Normal Keychain storage survives restart.','expectCount':1}], keychain=True)
        if json.loads(keychain_saved[-1]['detail']) != json.loads(keychain_loaded[-1]['detail']):
            raise RuntimeError('Normal Keychain vault changed across restart')
        if (evidence / 'keychain-vault/test-vault-key.bin').exists():
            raise RuntimeError('Normal Keychain vault used a test file key')
        recovered_store = launch('keychain-standalone-store', [
            {'action':'snapshot','expectContains':'Normal Keychain storage survives restart.','expectCount':1},
            {'action':'nativePresentation','expectContains':'Muesli'},
        ], keychain=True, unregistered_store=True)
        if json.loads(keychain_saved[-1]['detail']) != json.loads(recovered_store[0]['detail']):
            raise RuntimeError('Standalone encrypted-store lookup changed original-Keychain meeting data')
        shortcuts = launch('native-shortcuts', [
            {'action':'showScreen','value':'home'},
            {'action':'nativeShortcut','value':'sidebar'},
            {'action':'nativeShortcut','value':'sidebar'},
            {'action':'nativeShortcut','value':'search'},
            {'action':'showScreen','value':'home'},
            {'action':'nativePresentation','expectContains':'Muesli'},
        ])
        collapsed, expanded, focused = [json.loads(row['detail']) for row in shortcuts[1:4]]
        if not collapsed['sidebarCollapsed'] or expanded['sidebarCollapsed'] or not focused['searchFocused']:
            raise RuntimeError('Native shortcuts failed the collapse/expand/search-focus transitions')
        for screen, appearance in [('home', 'Light'), ('chat', 'Dark'), ('meeting', 'Dark')]:
            ui_rows = launch(f'muesli-{screen}-{appearance.lower()}', [
                {'action':'showScreen','value':screen,'expectContains':f'screen={screen}'},
                {'action':'nativePresentation','expectContains':'Muesli'},
            ], appearance=appearance)
            presentation = json.loads(ui_rows[-1]['detail'])
            if presentation.get('screen') != screen:
                raise RuntimeError(f'Native navigation did not reach the requested {screen} page')
            expected_appearance = 'NSAppearanceNameDarkAqua' if appearance == 'Dark' else 'NSAppearanceNameAqua'
            luminance = presentation.get('renderedBackgroundLuminance')
            if (presentation.get('appearancePreference') != appearance
                    or presentation.get('colorScheme') != appearance
                    or presentation.get('effectiveAppearance') != expected_appearance
                    or not isinstance(luminance, (int, float))
                    or not (luminance < 0.25 if appearance == 'Dark' else luminance > 0.6)):
                raise RuntimeError(f'Native {appearance} preference did not change the actual rendered dashboard: {presentation}')
        capture_checks = []
        if args.capture:
            capture_root = evidence / 'capture-vault'
            authorization = launch('capture-authorization', [
                {'action':'captureAuthorization'},
            ], vault_root=capture_root)
            (evidence / 'capture-authorization.json').write_text(json.dumps(authorization, indent=2))
            def union_coverage(segments, channel):
                coverage = 0.0
                previous_end = 0.0
                for segment in segments:  # Valid chronological windows; do not bridge gaps.
                    if segment['channel'] != channel: continue
                    coverage += max(0.0, segment['end'] - max(segment['start'], previous_end))
                    previous_end = max(previous_end, segment['end'])
                return coverage


            def validate_capture(meetings, meeting_id, diagnostic=None, minimum_tail=4,
                                 minimum_microphone=4.5, minimum_system=4, maximum_pcm=8):
                meeting = next((m for m in meetings if m['id'].lower() == meeting_id.lower()), None)
                if meeting is None: raise RuntimeError('Real capture meeting did not survive persistence')
                segments = meeting['segments']
                microphone_source = 'SYNTHETIC E2E PCM' if args.synthetic_microphone else 'AVAudioEngine'
                microphone_segments = [
                    {'channel':s['channel'], 'chunkID':s['chunkID'], 'start':s['start'], 'end':s['end'],
                     'source':microphone_source} for s in segments if s['channel'] == 'me'
                ]
                if any(not math.isfinite(s['start']) or not math.isfinite(s['end']) or
                       s['start'] < 0 or s['end'] <= s['start'] or not s['text'].strip() for s in segments):
                    raise RuntimeError('Real capture persisted invalid transcript timestamps/content')
                if [s['start'] for s in segments] != sorted(s['start'] for s in segments):
                    raise RuntimeError('Real capture channels were not persisted chronologically')
                if len({s['chunkID'] for s in segments}) != len(segments):
                    raise RuntimeError('Real capture retry duplicated a chunk transcript')
                system_windows = [
                    {'channel':s['channel'], 'chunkID':s['chunkID'], 'start':s['start'], 'end':s['end'],
                     'source':'Core Audio process tap'} for s in segments if s['channel'] == 'them'
                ]
                microphone_coverage = union_coverage(segments, 'me')
                system_coverage = union_coverage(segments, 'them')
                required_microphone_coverage = minimum_tail if args.synthetic_microphone else 0
                coverage_evidence = {
                    'microphoneSource':microphone_source, 'syntheticMicrophone':args.synthetic_microphone,
                    'microphoneSegments':microphone_segments, 'systemTranscriptWindows':system_windows,
                    'microphoneTranscriptCoverageSeconds':microphone_coverage,
                    'systemTranscriptCoverageSeconds':system_coverage,
                    'requiredMicrophoneTranscriptCoverageSeconds':required_microphone_coverage,
                    'requiredSystemTranscriptCoverageSeconds':minimum_tail,
                    'microphoneTranscriptDeficitSeconds':max(0, required_microphone_coverage - microphone_coverage),
                    'systemTranscriptDeficitSeconds':max(0, minimum_tail - system_coverage),
                    'microphonePCMSeconds':diagnostic.get('microphonePCMSeconds') if diagnostic else None,
                    'systemPCMSeconds':diagnostic.get('systemPCMSeconds') if diagnostic else None,
                    'systemCaptureFormat':diagnostic.get('systemCaptureFormat') if diagnostic else None,
                }
                if system_coverage < minimum_tail:
                    raise RuntimeError('Known playback retained insufficient system transcript union coverage: ' +
                                       json.dumps(coverage_evidence, sort_keys=True))
                if microphone_coverage < required_microphone_coverage:
                    raise RuntimeError('Synthetic microphone retained insufficient transcript union coverage: ' +
                                       json.dumps(coverage_evidence, sort_keys=True))
                both = {s['channel'] for s in segments} == {'me', 'them'}
                check = {'meetingID':meeting_id, 'bothChannelOrderingProven':both,
                         'bothRealChannelOrderingProven':both and not args.synthetic_microphone,
                         'microphoneSource':microphone_source, 'syntheticMicrophone':args.synthetic_microphone,
                         'microphoneSegments':microphone_segments,
                         'channelEvidence':('synthetic E2E microphone and real system channel, chronological' if args.synthetic_microphone else
                         'both audible real channels, chronological') if both else
                         'no audible AVAudioEngine microphone transcript; environmental silence prevents both-channel proof',
                         'externalServices':'EXPLICIT LOCAL MOCKS'}
                check.update(coverage_evidence)
                if diagnostic is not None:
                    if diagnostic['syntheticMicrophone'] != args.synthetic_microphone or diagnostic['microphoneSource'] != microphone_source:
                        raise RuntimeError('Capture evidence does not match the explicitly requested microphone source')
                    if not minimum_microphone <= diagnostic['microphonePCMSeconds'] <= maximum_pcm:
                        raise RuntimeError('Capture lacked its required substantial microphone-source PCM')
                    if not minimum_system <= diagnostic['systemPCMSeconds'] <= maximum_pcm or diagnostic['pending'] != 0:
                        raise RuntimeError('Capture lacked required real system PCM or did not drain its queue')
                    check.update(diagnostic)
                capture_checks.append(check)

            def capture_and_restart(name, action, extra_commands=None):
                rows = launch(name, [
                    {'action':'captureAuthorization'},
                    *(extra_commands or []),
                    {'action':action, 'path':str(fixture)},
                    {'action':'pendingQueue','expectContains':'pending=0'},
                    {'action':'snapshot'},
                ], vault_root=capture_root)
                diagnostic = json.loads(next(r['detail'] for r in rows if r['action'] == action))
                saved = json.loads(rows[-1]['detail'])
                validate_capture(saved, diagnostic['meetingID'], diagnostic)
                restart = launch(name + '-restart', [
                    {'action':'pendingQueue','expectContains':'pending=0'},
                    {'action':'snapshot'},
                ], vault_root=capture_root)
                if saved != json.loads(restart[-1]['detail']):
                    raise RuntimeError(f'{name}: restart changed captured IDs, transcript, timestamps or notes')
                return rows

            capture_and_restart('real-capture', 'record')
            capture_and_restart('capture-busy-stop', 'recordBusy')
            capture_and_restart('capture-start-recovery', 'record', [
                {'action':'recordStartFailure','expectContains':'original permissions restored'},
            ])
            discarded = launch('native-discard-other-selection', [
                {'action':'captureAuthorization'},
                {'action':'nativeDiscard','path':str(fixture)},
                {'action':'pendingQueue','expectContains':'pending=0'},
                {'action':'snapshot'},
            ], vault_root=capture_root)
            capture_checks.append(json.loads(discarded[1]['detail']))
            for action in ['recordDeviceFailure', 'recordCleanupFailure']:
                fault = launch(action, [
                    {'action':'captureAuthorization'},
                    {'action':action,'path':str(fixture)},
                    {'action':'pendingQueue','expectContains':'pending=0'},
                    {'action':'snapshot'},
                    {'action':'record','path':str(fixture)},
                    {'action':'pendingQueue','expectContains':'pending=0'},
                    {'action':'snapshot'},
                ], vault_root=capture_root)
                detail = json.loads(fault[1]['detail'])
                before_recovery = json.loads(fault[3]['detail'])
                recovery_detail = json.loads(fault[4]['detail'])
                persisted = json.loads(fault[-1]['detail'])
                validate_capture(persisted, detail['capture']['meetingID'], detail['capture'])
                validate_capture(persisted, recovery_detail['meetingID'], recovery_detail)
                if detail['capture']['processID'] != recovery_detail['processID']:
                    raise RuntimeError(f'{action}: recovery changed the actual app process')
                if detail['capture']['meetingID'] == recovery_detail['meetingID']:
                    raise RuntimeError(f'{action}: recovery reused the faulted meeting identity')
                if before_recovery != [m for m in persisted if m['id'].lower() != recovery_detail['meetingID'].lower()]:
                    raise RuntimeError(f'{action}: same-instance recovery mutated earlier captured meetings')
                restart = launch(action + '-restart', [
                    {'action':'snapshot'},
                ], vault_root=capture_root)
                if persisted != json.loads(restart[-1]['detail']):
                    raise RuntimeError(f'{action}: captured tail changed on restart')
            overlapping = launch('capture-overlapping-stop', [
                {'action':'captureAuthorization'},
                {'action':'recordOverlappingStop','path':str(fixture)},
                {'action':'pendingQueue','expectContains':'pending=0'},
                {'action':'snapshot'},
            ], vault_root=capture_root)
            overlap_detail = json.loads(overlapping[1]['detail'])
            persisted = json.loads(overlapping[-1]['detail'])
            first_capture = overlap_detail['firstCapture']
            recovery_capture = overlap_detail['recoveryCapture']
            if overlap_detail['overlappingCallerCount'] != 2 or sorted(overlap_detail['completionOrder']) != [1, 2]:
                raise RuntimeError('Live overlapping stop did not complete both real callers')
            if not overlap_detail['restartedAfterFirstCompletion']:
                raise RuntimeError('Overlapping stop delayed recovery until all callers completed')
            if first_capture['meetingID'] == recovery_capture['meetingID'] or not (
                first_capture['processID'] == recovery_capture['processID'] == overlap_detail['processID']
            ):
                raise RuntimeError('Overlapping stop did not recover a distinct recording in the same app instance')
            validate_capture(persisted, first_capture['meetingID'], first_capture, minimum_tail=2,
                             minimum_microphone=2, minimum_system=2, maximum_pcm=5)
            validate_capture(persisted, recovery_capture['meetingID'], recovery_capture)
            restarted = launch('capture-overlapping-stop-restart', [
                {'action':'pendingQueue','expectContains':'pending=0'},
                {'action':'snapshot'},
            ], vault_root=capture_root)
            if persisted != json.loads(restarted[-1]['detail']):
                raise RuntimeError('Overlapping stop/recovery changed real captured transcripts across restart')

            # Force unavailable external inference, not mocked capture: quit must save
            # the actual live recorder tail before AppDelegate authorizes termination.
            for action in ['recordQuit', 'recordQuitWriteFailure']:
                inject(['transcription'])
                quitting = launch('capture-live-' + action, [
                    {'action':'captureAuthorization'},
                    {'action':action,'path':str(fixture)},
                ], vault_root=capture_root)
                quit_detail = json.loads(quitting[-1]['detail'])
                expected_source = 'SYNTHETIC E2E PCM' if args.synthetic_microphone else 'AVAudioEngine'
                if quit_detail['syntheticMicrophone'] != args.synthetic_microphone or quit_detail['microphoneSource'] != expected_source:
                    raise RuntimeError('Quit evidence does not match the explicitly requested microphone source')
                if not quit_detail['liveBufferedAtQuitRequest'] or quit_detail['themChunksBeforeQuit'] != 0:
                    raise RuntimeError('Quit scenario did not begin with genuinely buffered new them audio')
                if not quit_detail['shutdownCompleted'] or not quit_detail['playbackReaped']:
                    raise RuntimeError('Quit scenario did not observe actual application termination and owned playback reap')
                elapsed = quit_detail['elapsedAtQuitRequestSeconds']
                if not math.isfinite(elapsed) or not 2 <= elapsed < 5:
                    raise RuntimeError('Quit request lacks bounded measured monotonic capture elapsed time')
                if quit_detail['microphonePCMSeconds'] < 2 or quit_detail['systemPCMSeconds'] < 2:
                    raise RuntimeError('Quit did not drain substantial real PCM from both recorder channels')
                if action == 'recordQuitWriteFailure' and (
                    not quit_detail['quitRefusedOnWriteDenial'] or not quit_detail['memoryTailRecoveredToEncryptedQueue']
                ):
                    raise RuntimeError('Actual delegate refusal and failed memory-tail retry to encrypted storage were not both proven')
                pending = launch(action + '-persisted-tail', [
                    {'action':'pendingQueue'},
                ], vault_root=capture_root)
                pending_count = int(pending[0]['detail'].removeprefix('pending='))
                if pending_count < 1:
                    raise RuntimeError('Real application quit did not preserve new live tail audio for offline retry')
                inject([])
                retry = launch(action + '-retry', [
                    {'action':'retryQueue'},
                    {'action':'pendingQueue','expectContains':'pending=0'},
                    {'action':'snapshot'},
                ], vault_root=capture_root)
                saved = json.loads(retry[-1]['detail'])
                validate_capture(saved, quit_detail['meetingID'], minimum_tail=quit_detail['minimumTailSeconds'])
                capture_checks[-1].update(quit_detail)
                second_restart = launch(action + '-exact-restart', [
                    {'action':'retryQueue'},
                    {'action':'pendingQueue','expectContains':'pending=0'},
                    {'action':'snapshot'},
                ], vault_root=capture_root)
                if saved != json.loads(second_restart[-1]['detail']):
                    raise RuntimeError('Quit/retry/restart changed the newly drained live tail or duplicated segments')
            if args.synthetic_microphone:
                paused = launch('native-recording-pause', [
                    {'action':'recordPause','path':str(fixture)},
                    {'action':'pendingQueue','expectContains':'pending=0'},
                    {'action':'snapshot','expectCount':1},
                ], vault_root=evidence / 'pause-vault')
                capture_checks.append(json.loads(paused[0]['detail']))
            (evidence / 'capture-invariants.json').write_text(json.dumps(capture_checks, indent=2))
        summary = {'passed':True,'binary':str(binary),'externalServices':'EXPLICIT LOCAL MOCKS',
                   'binarySHA256':binary_hash,
                   'uiFoundation':'Muesli',
                   'captureExercised':args.capture, 'realMicrophoneExercised':args.capture and not args.synthetic_microphone,
                   'realSystemCaptureExercised':args.capture, 'syntheticMicrophone':args.synthetic_microphone,
                   'realCaptureExercised':args.capture and not args.synthetic_microphone,
                   'playbackLifecycleExercised':args.playback,'defaultMicrophoneAvailable':not missing_input,
                   'compatibilityChecks':compatibility_checks,
                   'captureChecks':capture_checks,'checks':len(results),'proxySecurityChecks':len(service_checks),'evidence':str(evidence)}
        (evidence / 'summary.json').write_text(json.dumps(summary, indent=2))
        print(json.dumps(summary, indent=2))
    finally:
        server.terminate()
        try: server.wait(timeout=5)
        except subprocess.TimeoutExpired: server.kill(); server.wait()

if __name__ == '__main__':
    try: main()
    except Exception as error:
        print('E2E FAILED: ' + str(error), file=sys.stderr)
        sys.exit(1)
