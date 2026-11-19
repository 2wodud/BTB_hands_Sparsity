"""Exhaust all 65,536 B position combinations plus short groups/partial rows."""
import argparse
import json
from pathlib import Path
import shutil
import time
from run import ROOT, execute

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--vivado-bin',type=Path,default=Path('C:/Xilinx/Vivado/2022.2/bin'))
    p.add_argument('--build',type=Path,required=True)
    args=p.parse_args()
    work=args.build.resolve()
    if not str(work).isascii(): p.error('--build must be ASCII-only')
    work.mkdir(parents=True,exist_ok=True)
    for source in (ROOT/'rtl/sparsity_frontend.v',ROOT/'tb/rv_monitor.sv',ROOT/'tb/tb_frontend.sv'):
        shutil.copyfile(source,work/source.name)
    execute(args.vivado_bin,'xvlog',['sparsity_frontend.v'],work,'compile.log')
    execute(args.vivado_bin,'xvlog',['-sv','rv_monitor.sv','tb_frontend.sv'],work,'tb_compile.log')
    execute(args.vivado_bin,'xelab',['tb_frontend','-s','frontend_sim','-debug','typical'],work,'elaborate.log')
    started=time.perf_counter()
    data=execute(args.vivado_bin,'xsim',['frontend_sim','-runall','-onerror','quit','-onfinish','quit'],work,'simulation.log')
    elapsed=time.perf_counter()-started
    if 'FRONTEND EXHAUSTIVE PASS groups=65728' not in data:
        raise RuntimeError('Frontend sweep did not pass; see '+str(work/'simulation.log'))
    (work/'verification.json').write_text(json.dumps(dict(groups=65728,
        full_length_column_bitmap_combinations=65536,tail_and_partial_row_groups=192,
        xsim_process_wall_s=elapsed),indent=2)+'\n')
    print(f'PASS frontend: 65,728 groups, {elapsed:.2f}s',flush=True)

if __name__=='__main__': main()
