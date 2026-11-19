"""Check pinned team RTL is unchanged and the MAC patch is exactly one character."""
import hashlib
import json
from pathlib import Path

ROOT=Path(__file__).resolve().parent

def git_blob(data):
    return hashlib.sha1(b'blob '+str(len(data)).encode()+b'\0'+data).hexdigest()

def main():
    meta=json.loads((ROOT/'reference/provenance.json').read_text(encoding='utf-8'))
    for entry in meta['files']:
        assert git_blob((ROOT/entry['local']).read_bytes())==entry['git_blob_sha'],entry['local']
    original=(ROOT/'reference/mac_array_compute_nm.v').read_bytes()
    patched=(ROOT/'rtl/mac_array_compute_nm.v').read_bytes()
    assert original.count(b'column_k_position;')==1
    assert patched==original.replace(b'column_k_position;',b'column_k_position')
    teammate=(ROOT/'reference/teammate_sparsity_frontend.v').read_bytes()
    assert (ROOT/'rtl/sparsity_frontend.v').read_bytes()==teammate
    assert hashlib.sha256(teammate).hexdigest()=='dbdb0d679d18671a129ace19fa541dda7a5c1264fbd6306d62f38720dee716fb'
    revision=json.loads((ROOT/'reference/revision.json').read_text(encoding='utf-8'))
    for name,expected in revision['unchanged_rtl_sha256'].items():
        assert hashlib.sha256((ROOT/'rtl'/name).read_bytes()).hexdigest()==expected,name
    # SET5 plans 1/2/3 use exactly the same operand_loader core. Plans 2/3
    # append the supplied b_prefetch_bridge; gemm_top bypasses it in plan 1.
    assert git_blob((ROOT/'rtl/operand_loader.v').read_bytes()[:10815])=='2b762ab58c1b1c0465acde70b58ea7a6fddee1ea'
    print(f'PASS {len(meta["files"])} pinned source files; teammate frontend: byte-identical; existing MAC patch unchanged')

if __name__=='__main__': main()
