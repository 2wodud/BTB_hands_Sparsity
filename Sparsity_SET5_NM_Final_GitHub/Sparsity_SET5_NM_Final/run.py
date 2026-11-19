"""Verify SET5 plans independently, preserving their supplied memory schedules."""
import argparse
import csv
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT / 'tb'))
from generate import make_case, suite

EXTRA = {
    'bank_zero': dict(m=19,n=11,k=20,pattern='bank_zero',stalls=2,output_stalls=2,runs=2),
    'walkthrough': dict(m=4,n=4,k=4,pattern='walkthrough'),
    'inspection': dict(m=20,n=12,k=6,pattern='inspection',latency=3,stalls=2,output_stalls=2),
    'banks_k1': dict(m=19,n=9,k=1,stalls=2,output_stalls=2),
    'banks_zero': dict(m=19,n=9,k=7,pattern='zeros',stalls=2,output_stalls=2),
    'banks_tail': dict(m=27,n=11,k=9,sparsity=.7,stalls=2,output_stalls=2,runs=2),
    'zero_groups': dict(m=35,n=11,k=20,pattern='zero_groups',stalls=2,output_stalls=2),
    'special_values': dict(m=35,n=11,k=19,pattern='special_values',stalls=2,output_stalls=2),
    'multirow_k1024': dict(m=19,n=17,k=1024,latency=3,stalls=2,output_stalls=2),
    'html_20x12x8': dict(m=20,n=12,k=8,pattern='html_2of4'),
    'html_8x8x4': dict(m=8,n=8,k=4,pattern='html_2of4'),
    'html_19x11x7': dict(m=19,n=11,k=7,pattern='html_2of4'),
    'html_64x128x128': dict(m=64,n=128,k=128,pattern='html_2of4'),
    'html_mixed': dict(m=19,n=11,k=20,pattern='html_mixed'),
    'nm_modes': dict(m=19,n=11,k=20,pattern='nm_modes',stalls=2,output_stalls=2),
}
for _mode in range(5):
    EXTRA[f'mode_{_mode}of4'] = dict(m=19,n=9,k=12,pattern=f'html_{_mode}of4',output_stalls=2)
for _tail in (1,2,3):
    EXTRA[f'tail_{_tail}'] = dict(m=19,n=9,k=4+_tail,pattern='html_2of4',stalls=2,output_stalls=2)


def expected_packets(m, n, k, b, packed=True):
    if not packed:
        return ((m+3)//4)*((n+3)//4)*k
    rounds = 0
    for col in range(0,n,4):
        for base in range(0,k,4):
            end = min(base+4,k)
            max_nnz = max(sum(b[q*n+c]!=0 for q in range(base,end))
                          for c in range(col,min(col+4,n)))
            count = end-base if max_nnz>=3 else max_nnz
            rounds += max(1,count) if base==0 or end==k else count
    return ((m+3)//4)*rounds


def execute(vivado, tool, args, work, log):
    exe = vivado / (tool + ('.bat' if os.name=='nt' else ''))
    env = os.environ.copy()
    env['TEMP'] = env['TMP'] = str(work)
    for attempt in range(3 if tool=='xsim' else 1):
        target = work / (log if attempt==0 else f'{log}.retry{attempt}')
        with target.open('wb') as output:
            result = subprocess.run([str(exe),*args],cwd=work,env=env,stdout=output,
                                    stderr=subprocess.STDOUT,timeout=1800)
        data = target.read_text(encoding='utf-8',errors='replace')
        if result.returncode==0 and 'ERROR:' not in data and 'Fatal:' not in data:
            return data
        # Vivado 2022.2 can fail to remove a temporary obj directory after a
        # successful native snapshot build on Windows; require the actual binary.
        if (tool=='xelab' and 'Built simulation snapshot' in data and
            'Could not remove the obj directory:' in data and 'ERROR:' not in data and
            any((work/'xsim.dir').glob('*/xsimk.exe'))):
            return data
        if tool!='xsim' or result.returncode not in (0xC0000005,-1073741819) or 'Fatal:' in data:
            break
    raise RuntimeError(f'{tool} failed; see {target}\n{data[-3500:]}')


def table(path):
    with path.open(newline='') as stream:
        return list(csv.DictReader(stream))


def finish_config(directory, reset=False):
    """Add the bench-only reset flag and keep fixture checksums accurate."""
    path=directory/'config.hex'
    words=path.read_text().splitlines()[:9]
    path.write_text('\n'.join(words)+('\n00000001\n' if reset else '\n00000000\n'),encoding='ascii')
    metadata=directory/'case.json'
    if metadata.exists():
        data=json.loads(metadata.read_text(encoding='utf-8'))
        data['sha256']['config.hex']=hashlib.sha256(path.read_bytes()).hexdigest()
        metadata.write_text(json.dumps(data,indent=2)+'\n',encoding='utf-8')


def simulate(args, variant, cases, vectors, baseline=False, small=False):
    name = f'plan{variant}_' + ('original' if baseline else 'nm')
    if small: name += '_small_buffers'
    work = args.build / name
    work.mkdir(parents=True,exist_ok=True)
    sources = ROOT/'reference/memory_baseline' if baseline else ROOT/'rtl'
    for source in sources.glob('*.v'):
        shutil.copyfile(source,work/source.name)
    if baseline and variant!=2:
        shutil.copyfile(ROOT/f'reference/plan{variant}_gemm_top.v',work/'gemm_top.v')
    for source in (ROOT/'tb').glob('*.sv'):
        shutil.copyfile(source,work/source.name)
    rtl = [p.name for p in sources.glob('*.v')]
    execute(args.vivado_bin,'xvlog',rtl,work,'compile.log')
    defines = f'`define PLAN {variant}\n'
    if baseline: defines += '`define BASELINE\n'
    if small: defines += '`define ADEPT 8\n`define BDEPT 8\n'
    (work/'tb_gemm.sv').write_text(defines+(ROOT/'tb/tb_gemm.sv').read_text(encoding='utf-8'),encoding='utf-8')
    execute(args.vivado_bin,'xvlog',['-sv','rv_monitor.sv','tb_gemm.sv'],work,'tb_compile.log')
    execute(args.vivado_bin,'xelab',['tb_gemm','-s','gemm_sim','-debug','typical'],work,'elaborate.log')
    # The SV bench resets the DUT and reloads files between fixtures. Keeping
    # one process avoids Vivado 2022.2's intermittent native restart crashes.
    manifest=[]
    for case in cases:
        target = work/'cases'/case
        target.mkdir(parents=True,exist_ok=True)
        for f in ('a.hex','b.hex','c.hex','config.hex'):
            shutil.copyfile(vectors/case/f,target/f)
        manifest.append(target.as_posix())
    (work/'batch.txt').write_text('\n'.join(manifest)+'\n',encoding='ascii')
    started = time.perf_counter()
    data = execute(args.vivado_bin,'xsim',['gemm_sim','-runall',
                   '-onerror','quit','-onfinish','quit','-testplusarg','HOST_TEST',
                   '-testplusarg','OPTIMIZED','-testplusarg','BATCH'],work,'simulation.log')
    elapsed = time.perf_counter()-started
    if data.count('GEMM REGRESSION PASS')!=len(cases) or 'Fatal:' in data:
        raise RuntimeError(f'{name}: not every fixture passed; see {work}/simulation.log')
    result=[]
    for case in cases:
        config = [int(v,16) for v in (vectors/case/'config.hex').read_text().split()]
        m,n,k = config[:3]
        b = [int(v,16) for v in (vectors/case/'b.hex').read_text().split()]
        packet_count = expected_packets(m,n,k,b,not baseline)
        rows = table(work/'cases'/case/'metrics.csv')
        if len(rows)!=config[6]+(3 if config[9] else 0):
            raise AssertionError(f'{name}/{case}: wrong number of runs')
        for row in rows:
            effective = m*n*k-config[8]
            if int(row['compute_packets'])!=packet_count:
                raise AssertionError(f'{name}/{case}: packet count {row["compute_packets"]} != {packet_count}')
            if int(row['nonzero_mac_slots'])!=effective or int(row['mac_slots'])!=(m*n*k if baseline else effective):
                raise AssertionError(f'{name}/{case}: incorrect MAC event count')
            result.append(dict(variant=name,case=case,**row,
                               simulated_ns=int(row['cycles'])*10))
    (work/'session.json').write_text(json.dumps(dict(cases=len(cases),runs=len(result),
                        xsim_process_wall_s=elapsed),indent=2)+'\n')
    print(f'PASS {name}: {len(cases)} cases, {len(result)} runs, {elapsed:.2f}s',flush=True)
    return result


def compare_reads(build, plan, case, small=False):
    suffix='_small_buffers' if small else ''
    a=table(build/f'plan{plan}_original{suffix}/cases'/case/'reads.csv')
    b=table(build/f'plan{plan}_nm{suffix}/cases'/case/'reads.csv')
    def sequence(rows): return [(r['run'],r['is_b'],r['address']) for r in rows]
    if sequence(a)!=sequence(b):
        raise AssertionError(f'Plan {plan}/{case}: external read order changed')
    return len(a)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--vivado-bin',type=Path,default=Path('C:/Xilinx/Vivado/2022.2/bin'))
    parser.add_argument('--build',type=Path,required=True,help='Writable ASCII-only build path')
    parser.add_argument('--plans',type=int,nargs='+',choices=(1,2,3),default=[1,2,3])
    parser.add_argument('--cases',nargs='+')
    parser.add_argument('--extended',action='store_true')
    parser.add_argument('--max-dimensions',action='store_true')
    parser.add_argument('--compare',action='store_true',help='Also run unchanged memory-team baseline')
    parser.add_argument('--small-buffers',action='store_true')
    args=parser.parse_args()
    args.build=args.build.resolve()
    if not str(args.build).isascii(): parser.error('--build must use an ASCII-only path for Vivado')
    args.build.mkdir(parents=True,exist_ok=True)
    vectors=args.build/'vectors'
    cases=suite(vectors,args.extended)
    if 'max_dimensions' in cases and not args.max_dimensions: cases.remove('max_dimensions')
    for case,options in EXTRA.items():
        make_case(vectors/case,**options)
        cases.append(case)
    if args.cases:
        missing=set(args.cases)-set(cases)
        if missing: parser.error('Unknown cases: '+str(missing))
        cases=args.cases
    for case in cases:
        finish_config(vectors/case,case=='restart')
    records=[]
    checks=[]
    for plan in args.plans:
        records += simulate(args,plan,cases,vectors)
        if args.compare:
            records += simulate(args,plan,cases,vectors,baseline=True)
            for case in cases:
                checks.append(dict(plan=plan,case=case,reads=compare_reads(args.build,plan,case)))
        if args.small_buffers:
            make_case(vectors/'small_buffers',m=35,n=19,k=7,latency=4,seed=51,stalls=2,output_stalls=2)
            finish_config(vectors/'small_buffers')
            records+=simulate(args,plan,['small_buffers'],vectors,small=True)
            if args.compare:
                records+=simulate(args,plan,['small_buffers'],vectors,baseline=True,small=True)
                checks.append(dict(plan=plan,case='small_buffers',reads=compare_reads(args.build,plan,'small_buffers',True)))
    summary=args.build/'summary.csv'
    with summary.open('w',newline='',encoding='utf-8') as stream:
        writer=csv.DictWriter(stream,fieldnames=list(records[0]))
        writer.writeheader();writer.writerows(records)
    (args.build/'verification.json').write_text(json.dumps(dict(
        result_rows=len(records),exact_read_order_comparisons=checks,
        rtl_sha256={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in (ROOT/'rtl').glob('*.v')}
    ),indent=2)+'\n')
    print(f'PASS {len(records)} measured runs. {summary}',flush=True)


if __name__=='__main__': main()
