import os
import subprocess
import tempfile

PROJECT_ROOT = os.path.abspath(os.path.dirname(__file__))
SCRIPTS_DIR = os.path.join(PROJECT_ROOT, 'scripts')
LIB_DIR = os.path.join(SCRIPTS_DIR, 'lib')

rules = '''allow id 1111:2222 serial "123"
# ttl_epoch: 1000
allow id 3333:4444 serial "456"
# ttl_epoch: 2000
'''

fd, rules_path = tempfile.mkstemp()
with os.fdopen(fd, 'w') as f:
    f.write(rules)

script = f'''
set -x
source "{LIB_DIR}/logger.sh"
source "{LIB_DIR}/config-reader.sh"
source "{LIB_DIR}/lock.sh"
source "{LIB_DIR}/time-guards.sh"
source "{SCRIPTS_DIR}/cleanup-expired.sh"
echo "Before _awk_ttl_filter"
_awk_ttl_filter 3000 "{rules_path}"
echo "After _awk_ttl_filter"
'''

print(f"Running snippet with rules_path {rules_path}...")
try:
    res = subprocess.run(['bash', '-c', script], capture_output=True, text=True, timeout=10)
    print(f"Return code: {res.returncode}")
    print(f"Stdout: {res.stdout}")
    print(f"Stderr: {res.stderr}")
except subprocess.TimeoutExpired as e:
    print(f"Timeout! Stdout: {e.stdout}")
    print(f"Stderr: {e.stderr}")
os.remove(rules_path)
