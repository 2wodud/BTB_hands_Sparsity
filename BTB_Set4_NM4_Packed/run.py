"""Verify N:4 packed execution and original Set 4 with Vivado Simulator."""
import argparse
import csv
import shutil
import subprocess
import sys
from pathlib import Path
from time import perf_counter

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT / 'tb'))
from generate import make_case, suite

EXTRA = {
    'banks_k1': dict(m=19, n=9, k=1, stalls=2, output_stalls=2),
    'banks_zero': dict(m=19, n=9, k=7, pattern='zeros', stalls=2, output_stalls=2),
    'banks_tail': dict(m=27, n=11, k=9, sparsity=.7, stalls=2, output_stalls=2, runs=2),
    'banks_groups': dict(m=21, n=125, k=129, sparsity=.5, output_stalls=2),
    'html_20x12x8': dict(m=20, n=12, k=8, pattern='html_2of4'),
    'html_8x8x4': dict(m=8, n=8, k=4, pattern='html_2of4'),
    'html_19x11x7': dict(m=19, n=11, k=7, pattern='html_2of4'),
    'html_64x128x128': dict(m=64, n=128, k=128, pattern='html_2of4'),
    'packed_one_round': dict(m=19, n=9, k=4, pattern='html_1of4', output_stalls=2),
    'packed_modes': dict(m=19, n=11, k=20, pattern='nm_modes', stalls=2, output_stalls=2),
}


def expected_packets(m, n, k, b, packed):
    row_tiles = (m + 3) // 4
    if not packed:
        return row_tiles * ((n + 3) // 4) * k
    rounds = 0
    for col in range(0, n, 4):
        for base in range(0, k, 4):
            end = min(base + 4, k)
            nnz = max(sum(b[q*n+c] != 0 for q in range(base, end))
                      for c in range(col, min(col + 4, n)))
            count = end - base if nnz >= 3 else nnz
            rounds += max(1, count) if base == 0 or end == k else count
    return row_tiles * rounds


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--vivado-bin', type=Path, required=True)
    parser.add_argument('--build', type=Path, required=True, help='Writable build directory with an ASCII path')
    parser.add_argument('--extended', action='store_true')
    parser.add_argument('--cases', nargs='+', help='Run only the named cases')
    parser.add_argument('--baseline-rtl', type=Path, help='Original Set 4 rtl directory')
    args = parser.parse_args()
    build = args.build.resolve()
    build.mkdir(parents=True, exist_ok=True)
    summary = build / 'summary.csv'
    summary.unlink(missing_ok=True)
    vectors = build / 'vectors'
    cases = suite(vectors, args.extended)
    for name, options in EXTRA.items():
        make_case(vectors / name, **options)
        cases.append(name)
    if args.cases:
        if set(args.cases) - set(cases):
            parser.error('Unknown case. Available cases: ' + ', '.join(cases))
        cases = args.cases

    def run(tool, *options, log):
        exe = args.vivado_bin / (tool + ('.bat' if sys.platform == 'win32' else ''))
        log_path = build / log
        attempts = 3 if tool == 'xsim' else 1
        for attempt in range(attempts):
            output = log_path if attempt == 0 else log_path.with_suffix(f'.retry{attempt}.log')
            with output.open('wb') as stream:
                result = subprocess.run(
                    [str(exe), *options], cwd=build, stdout=stream,
                    stderr=subprocess.STDOUT, timeout=600,
                )
            text = output.read_text(encoding='utf-8', errors='replace')
            if not result.returncode:
                return text
            if (tool == 'xelab' and 'Built simulation snapshot set4_sim' in text
                    and 'Could not remove the obj directory:' in text and 'ERROR:' not in text
                    and (build / 'xsim.dir/set4_sim/xsimk.exe').is_file()):
                return text
            if (tool != 'xsim' or result.returncode not in (0xC0000005, -1073741819)
                    or 'Fatal:' in text):
                break
        raise RuntimeError(f'{tool} failed. See {output}\n{text[-3000:]}')

    sources = sorted((args.baseline_rtl or ROOT / 'rtl').glob('*.v'))
    if not any(path.name == 'gemm_top.v' for path in sources):
        parser.error('The RTL directory must contain gemm_top.v')
    testbenches = sorted((ROOT / 'tb').glob('*.sv'))
    for path in [*sources, *testbenches]:
        shutil.copyfile(path, build / path.name)
    run('xvlog', *(path.name for path in sources), log='compile.log')
    defines = [] if args.baseline_rtl else ['-d', 'NM4_PACKED']
    run('xvlog', '-sv', *defines, *(path.name for path in testbenches), log='tb_compile.log')
    run('xelab', 'tb_gemm', '-s', 'set4_sim', '-debug', 'typical', log='elaborate.log')
    records = []
    for case in cases:
        for name in ('a.hex', 'b.hex', 'c.hex', 'config.hex'):
            shutil.copyfile(vectors / case / name, build / name)
        flags = ['-testplusarg', 'RESET_TEST'] if case == 'restart' else []
        started = perf_counter()
        text = run(
            'xsim', 'set4_sim', '-runall', '-onerror', 'quit', '-onfinish', 'quit',
            '-testplusarg', 'HOST_TEST', '-testplusarg', 'OPTIMIZED', *flags, log=case + '.log',
        )
        wall = perf_counter() - started
        if 'GEMM REGRESSION PASS' not in text or 'Fatal:' in text:
            raise RuntimeError(f'{case} failed. See {build / (case + ".log")}\n{text[-3000:]}')
        config = [int(value, 16) for value in (build / 'config.hex').read_text().splitlines()]
        m, n, k = config[:3]
        expected_mac = m * n * k - config[8]
        b = [int(value, 16) for value in (build / 'b.hex').read_text().splitlines()]
        packets = expected_packets(m, n, k, b, not args.baseline_rtl)
        with (build / 'metrics.csv').open() as stream:
            rows = list(csv.DictReader(stream))
        if len(rows) != config[6] + (3 if case == 'restart' else 0):
            raise RuntimeError(f'{case}: unexpected number of measured runs')
        for row in rows:
            if int(row['mac_slots']) != expected_mac or int(row['nonzero_mac_slots']) != expected_mac:
                raise RuntimeError(f'{case}: unexpected executed MAC count')
            if int(row['compute_packets']) != packets:
                raise RuntimeError(f"{case}: expected {packets} packets, got {row['compute_packets']}")
            records.append({'case': case, **row, 'xsim_wall_s': f'{wall:.3f}'})
        print(f'PASS {case} ({len(rows)} runs)', flush=True)

    with summary.open('w', newline='', encoding='utf-8') as stream:
        writer = csv.DictWriter(stream, fieldnames=list(records[0]))
        writer.writeheader()
        writer.writerows(records)
    print(f'PASS {len(cases)} cases, {len(records)} runs. {summary}', flush=True)


if __name__ == '__main__':
    main()
