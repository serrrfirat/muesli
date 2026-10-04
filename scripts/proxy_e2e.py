"""End-to-end HTTP security scenarios against the running proxy, not unit tests."""
import json
import urllib.error
import urllib.request


def exercise(base_url, sentinel):
    checks = []
    def request(path, payload=None, headers=None, expected=200, reason=None):
        fields = {'Content-Type': 'application/json'}
        fields.update(headers or {})
        body = None if payload is None else json.dumps(payload).encode()
        req = urllib.request.Request(base_url + path, data=body, headers=fields)
        try:
            with urllib.request.urlopen(req, timeout=5) as response:
                status, data = response.status, response.read()
        except urllib.error.HTTPError as error:
            status, data = error.code, error.read()
        result = json.loads(data)
        if status != expected or (reason and reason not in result.get('error', {}).get('message', '')):
            raise RuntimeError(f'Proxy E2E {path}: expected {expected}/{reason}, got {status}')
        checks.append({'route':path, 'status':status, 'passed':True, 'reason':reason})
        return result
    request('/quota', expected=401, reason='Session required')
    request('/health', headers={'Authorization':'Bearer '+sentinel}, expected=403, reason='credential isolation')
    challenge = request('/auth/challenge', {'account_id':'bob.testnet'})
    auth = {'challenge_id':challenge['challenge_id'], 'account_id':'bob.testnet', 'signature':'MOCK'}
    token = request('/auth/verify', auth)['token']
    request('/auth/verify', auth, expected=401, reason='challenge')
    challenge = request('/auth/challenge', {'account_id':'bob.testnet'})
    request('/auth/verify', {'challenge_id':challenge['challenge_id'], 'account_id':'bob.testnet'}, expected=401, reason='MOCK signature')
    request('/stake', {'amount':'0'}, headers={'Authorization':'Bearer '+token}, expected=400, reason='positive yocto')
    report = request('/attestation')
    encrypted_headers = {'X-Signing-Algo':'ed25519', 'X-Client-Pub-Key':'00' + ' '*62,
                         'X-Model-Pub-Key':report['signing_public_key'], 'X-Encryption-Version':'2', 'x-no-aliasing':'true'}
    # Malformed header must be rejected before any native conversion/decryption.
    request('/v1/chat/completions', {'model':'z-ai/glm-5.3-flash','messages':[{'role':'user','content':'00'*72}],'stream':False},
            headers=encrypted_headers, expected=400, reason='Invalid client public key')
    request('/health')
    return checks
